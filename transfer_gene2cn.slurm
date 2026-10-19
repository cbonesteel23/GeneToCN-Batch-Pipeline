#!/usr/bin/env bash
#SBATCH --account=omergokc
#SBATCH --partition=general-compute
#SBATCH --qos=nih
#SBATCH --time=2:00:00
#SBATCH --nodes=1
#SBATCH --mem=2G
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1

# gene2CN transfer job (run-specific label)
#
# - Activates PARENT_CONDA_ENV to ensure globus CLI is present
# - Uses run-specific label
# - Reuses existing in-flight task by label (ACTIVE/INACTIVE)
# - Always submits/reuses a Globus task (no "skip transfer" short-circuit)
# - Waits for completion then submits compute

set -euo pipefail
mkdir -p logs
: "${SLURM_SUBMIT_DIR:=$PWD}"

log() { echo "[$(date +'%F %T')] $*"; }
die() { echo "[$(date +'%F %T')] ERROR: $*" >&2; exit 1; }

: "${PIPELINE_CONFIG:?Missing PIPELINE_CONFIG}"
[[ -s "$PIPELINE_CONFIG" ]] || die "Config file not found or empty: $PIPELINE_CONFIG"

# shellcheck disable=SC1090
source "$PIPELINE_CONFIG"

# ---- Ensure Globus CLI is available ----
: "${CONDA_HOOK:?Config must define CONDA_HOOK=/path/to/conda}"
: "${PARENT_CONDA_ENV:?Config must define PARENT_CONDA_ENV (e.g., bioinfo)}"

if ! command -v globus >/dev/null 2>&1; then
    log "Globus CLI not found; activating conda env '${PARENT_CONDA_ENV}'..."
    eval "$("${CONDA_HOOK}" shell.bash hook)"
    conda activate "${PARENT_CONDA_ENV}"
fi

command -v globus >/dev/null 2>&1 || die "Globus CLI still not found after activating '${PARENT_CONDA_ENV}'."
log "Using globus: $(command -v globus)"
globus version || true

# ---- Child job SLURM placement (optional; leave empty to use cluster defaults) ----
: "${CHILD_PARTITION:=}"
: "${CHILD_QOS:=}"
CHILD_SBATCH_OPTS=()
[[ -n "$CHILD_PARTITION" ]] && CHILD_SBATCH_OPTS+=(--partition="$CHILD_PARTITION")
[[ -n "$CHILD_QOS" ]] && CHILD_SBATCH_OPTS+=(--qos="$CHILD_QOS")

# ---- Required per-job exports ----
: "${SAMPLE:?Missing SAMPLE}"
: "${POPCODE:?Missing POPCODE}"
: "${PATH_FILE:?Missing PATH_FILE}"
[[ -s "$PATH_FILE" ]] || die "PATH_FILE not found or empty: $PATH_FILE"

# ---- Required config values ----
: "${ENA:?Missing ENA}"
: "${UB_SCRATCH:?Missing UB_SCRATCH}"
: "${path_genomes:?Missing path_genomes}"
: "${vscratch_dir:?Missing vscratch_dir}"
: "${RUN_ID:?Missing RUN_ID}"

# ---- Optional config values ----
: "${GLOBUS_POLL_SECS:=10}"
: "${GLOBUS_POLL_JITTER_SECS:=5}"
: "${GLOBUS_LIST_LIMIT:=1000}"

# Run-specific label (prevents cross-run reuse/collisions)
LABEL="${RUN_ID}_${POPCODE}_${SAMPLE}"

# ---- Local destination (filesystem) ----
LOCAL_DIR="${vscratch_dir%/}/${POPCODE}/${SAMPLE}"
mkdir -p "$LOCAL_DIR"
log "Local destination: $LOCAL_DIR"

# ---- Globus destination (relative to UB_SCRATCH root = /vscratch) ----
DEST_REL="/${path_genomes%/}/${POPCODE}/${SAMPLE}"
log "Globus destination: $DEST_REL"
log "Globus label: $LABEL"
log "PATH_FILE: $PATH_FILE"

find_inflight_task_by_label() {
    # Search all tasks for this label, then filter locally for ACTIVE/INACTIVE.
    # This avoids CLI-version-dependent behavior around repeated --filter-status.
    if command -v jq >/dev/null 2>&1; then
        globus task list \
            --filter-label "$LABEL" \
            --limit "$GLOBUS_LIST_LIMIT" \
            --format json |
            jq -r '.DATA[]? | select(.status=="ACTIVE" or .status=="INACTIVE") | .task_id' |
            head -n1
    else
        globus task list \
            --filter-label "$LABEL" \
            --limit "$GLOBUS_LIST_LIMIT" \
            --format UNIX |
            awk '
                NR == 1 { next }
                ($2 == "ACTIVE" || $2 == "INACTIVE") { print $1; exit }
            '
    fi
}

find_recent_task_by_label_any_status() {
    if command -v jq >/dev/null 2>&1; then
        globus task list \
            --filter-label "$LABEL" \
            --limit "$GLOBUS_LIST_LIMIT" \
            --format json |
            jq -r '.DATA[]? | .task_id' |
            head -n1
    else
        globus task list \
            --filter-label "$LABEL" \
            --limit "$GLOBUS_LIST_LIMIT" \
            --format UNIX |
            awk 'NR > 1 { print $1; exit }'
    fi
}

wait_on_task() {
    local tid="$1"

    if [[ "${GLOBUS_POLL_JITTER_SECS:-0}" -gt 0 ]]; then
        local jitter=$(( RANDOM % GLOBUS_POLL_JITTER_SECS ))
        if (( jitter > 0 )); then
            log "Applying ${jitter}s jitter before waiting on $tid..."
            sleep "$jitter"
        fi
    fi

    log "Waiting on Globus task: $tid (label=$LABEL) polling every ${GLOBUS_POLL_SECS}s..."
    if ! globus task wait "$tid" --polling-interval "$GLOBUS_POLL_SECS" --heartbeat; then
        log "ERROR: globus task wait failed for task $tid"
        globus task show "$tid" || true
        exit 3
    fi

    local status
    status="$(globus task show "$tid" --jmespath status --format json 2>/dev/null | tr -d '"')"
    log "Final status for $tid: $status"
    [[ "$status" == "SUCCEEDED" ]] || { log "ERROR: status=$status"; exit 4; }
}

submit_transfer_json() {
    # Always submit (or reuse) a task and let Globus decide what needs transferring
    globus transfer "$ENA:" "$UB_SCRATCH:${DEST_REL}" \
        --batch "$PATH_FILE" \
        --label "$LABEL" \
        --notify off \
        --sync-level checksum \
        --format json
}

extract_tid_from_json() {
    if command -v jq >/dev/null 2>&1; then
        jq -r '.task_id // empty' <<< "$1"
    else
        sed -n 's/.*"task_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<< "$1"
    fi
}

log "Submitting/reusing Globus transfer for ${POPCODE}/${SAMPLE} (label='$LABEL') — letting Globus handle sync checks."

EXISTING_TID="$(find_inflight_task_by_label || true)"
if [[ -n "${EXISTING_TID:-}" ]]; then
    log "Reusing existing in-flight task for label '$LABEL': $EXISTING_TID"
    wait_on_task "$EXISTING_TID"
else
    log "Submitting new Globus transfer for label '$LABEL'..."
    set +e
    SUBMIT_JSON="$(submit_transfer_json 2>&1)"
    rc_json=$?
    set -e
    (( rc_json == 0 )) || die "globus transfer submit failed (rc=$rc_json): $SUBMIT_JSON"

    NEW_TID="$(extract_tid_from_json "$SUBMIT_JSON" | head -n1)"
    if [[ -z "${NEW_TID:-}" ]]; then
        log "WARN: submit succeeded but no task_id parsed; probing recent tasks..."
        sleep 3
        NEW_TID="$(find_recent_task_by_label_any_status || true)"
    fi
    [[ -n "${NEW_TID:-}" ]] || die "Could not determine Task ID after submission."
    log "New task id: $NEW_TID"
    wait_on_task "$NEW_TID"
fi

log "Submitting compute for ${POPCODE}/${SAMPLE}..."
COMPUTE_SCRIPT="${SLURM_SUBMIT_DIR}/compute_gene2cn.slurm"
[[ -s "$COMPUTE_SCRIPT" ]] || die "compute script not found: $COMPUTE_SCRIPT"

out="$(
    sbatch \
        --mail-type=NONE \
        --job-name="g2cn_compute_${RUN_ID}_${POPCODE}_${SAMPLE}" \
        --output="logs/g2cn_compute_${RUN_ID}_%j_${POPCODE}_${SAMPLE}.out" \
        --error="logs/g2cn_compute_${RUN_ID}_%j_${POPCODE}_${SAMPLE}.err" \
        "${CHILD_SBATCH_OPTS[@]}" \
        --export=ALL,PIPELINE_CONFIG="$PIPELINE_CONFIG",SAMPLE="$SAMPLE",POPCODE="$POPCODE" \
        "$COMPUTE_SCRIPT" 2>&1
)" || die "sbatch compute submission failed: $out"

log "$out"
jobid="$(awk '/Submitted batch job/ {print $4}' <<< "$out" | tail -n1)"
[[ -n "${jobid:-}" ]] || die "Could not parse compute job id from sbatch output."
log "Compute job submitted: ${jobid} for ${POPCODE}/${SAMPLE}"
