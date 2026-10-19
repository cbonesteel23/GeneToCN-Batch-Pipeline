#!/usr/bin/env bash
#SBATCH --account=omergokc
#SBATCH --partition=general-compute
#SBATCH --qos=nih
#SBATCH --time=05:00:00
#SBATCH --nodes=1
#SBATCH --mem=1G
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --job-name=gene2CN_parent
#SBATCH --output=logs/%x_%j.out
#SBATCH --error=logs/%x_%j.err
#SBATCH --mail-user=
#SBATCH --mail-type=BEGIN,END,FAIL

set -euo pipefail
trap 'rc=$?; ts=$(date "+%F %T"); echo "[$ts] ERROR line $LINENO: $BASH_COMMAND (rc=$rc)" >&2' ERR

mkdir -p logs
: "${SLURM_SUBMIT_DIR:=$PWD}"

log() { echo "[$(date +'%F %T')] $*"; }
die() { echo "[$(date +'%F %T')] ERROR: $*" >&2; exit 1; }
trim() { awk '{$1=$1;print}' <<<"${1//$'\n'/}"; }
safe_name() { sed 's/[^A-Za-z0-9._-]/_/g' <<<"$1"; }

PIPELINE_CONFIG="${1:?Usage: sbatch gene2CN_parent.slurm /path/to/gene2cn.env}"
[[ -s "$PIPELINE_CONFIG" ]] || die "Config file not found or empty: $PIPELINE_CONFIG"
# shellcheck disable=SC1090
source "$PIPELINE_CONFIG"

: "${META_IN:?Config must define META_IN=...}"
[[ -s "$META_IN" ]] || die "Metadata file not found or empty: $META_IN"

# ---- Ensure Globus CLI is available (validation only; parent itself does not throttle on Globus) ----
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

# ---- Settings ----
: "${PARENT_POLL_SECS:=1}"
: "${CAP_XFER:=4}"

SCRIPT_DIR="${SLURM_SUBMIT_DIR:-$PWD}"
CHILD_TRANSFER_SCRIPT="${SCRIPT_DIR}/transfer_gene2cn.slurm"
[[ -s "$CHILD_TRANSFER_SCRIPT" ]] || die "Missing transfer script: $CHILD_TRANSFER_SCRIPT"

# Run ID used for Slurm job naming / run scoping
RUN_ID="${RUN_ID:-gene2cn_${SLURM_JOB_ID}_$(date +%Y%m%d_%H%M%S)}"
export RUN_ID
export PIPELINE_CONFIG

log "Config: META_IN=$META_IN"
log "Config: CAP_XFER=$CAP_XFER PARENT_POLL_SECS=$PARENT_POLL_SECS"
log "RUN_ID=$RUN_ID"

# Child job SLURM placement (optional)
: "${CHILD_PARTITION:=}"
: "${CHILD_QOS:=}"
CHILD_SBATCH_OPTS=()
[[ -n "$CHILD_PARTITION" ]] && CHILD_SBATCH_OPTS+=(--partition="$CHILD_PARTITION")
[[ -n "$CHILD_QOS" ]] && CHILD_SBATCH_OPTS+=(--qos="$CHILD_QOS")

# ---- Slurm xfer counter (RUN-SCOPED) ----
slurm_xfer_notdone_count() {
  local rid="xfer_${RUN_ID}_"
  squeue -u "$USER" -h -o "%T %j" 2>/dev/null \
    | awk -v rid="$rid" '$2 ~ ("^" rid) && ($1=="PENDING" || $1=="CONFIGURING" || $1=="RUNNING") {n++} END{print n+0}'
}

# ---- Throttle logging: write '.' while waiting, but only once every 10s ----
DOT_EVERY_SECS=10
_last_dot_ts=0
maybe_dot() {
  local now
  now=$(date +%s)
  if (( now - _last_dot_ts >= DOT_EVERY_SECS )); then
    printf "."
    _last_dot_ts=$now
  fi
}

wait_for_xfer_slot() {
  local n
  while :; do
    n="$(slurm_xfer_notdone_count)"
    if (( n < CAP_XFER )); then
      return 0
    fi
    maybe_dot
    sleep "$PARENT_POLL_SECS"
  done
}

# ---- Normalize metadata -> canonical TSV ----
META_TSV="$(
python - "$META_IN" <<'PY'
import os, sys, re, csv

meta_in = sys.argv[1]
if not os.path.exists(meta_in) or os.path.getsize(meta_in) == 0:
    print(f"ERROR: Metadata not found or empty: {meta_in}", file=sys.stderr)
    sys.exit(1)

CANON = ["Sample_name", "Population_code", "fastq_ftp"]
ALIASES = {
    "Sample_name": [
        "sample name", "sample_name", "sample", "samplename", "sample_id", "sampleid", "id", "sample_alias", "sample title", "sample_title", "sample_accession"
    ],
    "Population_code": [
        "population code", "population_code", "popcode", "pop_code", "pop", "population", "super_population", "superpopulation", "super pop", "population elastic id", "population_elastic_id", "study", "project", "project_accession", "project accession", "study_id", "study id"
    ],
    "fastq_ftp": [
        "fastq_ftp", "fastq ftp", "fastqpaths", "fastq_paths", "fastq paths", "ftp", "ftp paths", "ftppaths", "paths", "read_ftp", "read ftp"
    ]
}

NA_LIKE = {"", "na", "n/a", "none", "nan"}

def norm(s: str) -> str:
    s = str(s).strip().replace("\ufeff", "")
    s = re.sub(r"\s+", " ", s)
    s = s.lower().replace(" ", "_")
    s = re.sub(r"\.\d+$", "", s)
    return s

def candidates(cols, want):
    want_n = norm(want)
    alias_ns = set(norm(a) for a in ALIASES.get(want, []))
    return [c for c in cols if norm(c) == want_n or norm(c) in alias_ns]

def write_out(rows, out_path):
    with open(out_path, "w", newline="") as f:
        w = csv.writer(f, delimiter="\t")
        w.writerow(CANON)
        for r in rows:
            w.writerow([r.get(h, "") for h in CANON])

ext = os.path.splitext(meta_in)[1].lower()
out_path = os.path.join(
    os.path.dirname(os.path.abspath(meta_in)),
    f".normalized_{os.path.basename(meta_in)}.tsv"
)

rows = []
try:
    import pandas as pd  # type: ignore

    if ext in [".xlsx", ".xls"]:
        df = pd.read_excel(meta_in, dtype=str)
    else:
        try:
            df = pd.read_csv(meta_in, dtype=str, sep=None, engine="python")
        except Exception:
            df = pd.read_csv(meta_in, dtype=str, delim_whitespace=True, engine="python")

    df.columns = [str(c) for c in df.columns]

    def best_col(df, want):
        cols = candidates(df.columns, want)
        if not cols:
            return None
        best = None
        best_score = -1
        for c in cols:
            s = df[c].astype(str).str.strip().str.lower()
            score = (~s.isin(NA_LIKE)).sum()
            if score > best_score:
                best, best_score = c, score
        return best

    c_sample = best_col(df, "Sample_name")
    c_pop = best_col(df, "Population_code")
    c_ftp = best_col(df, "fastq_ftp")

    missing = [k for k, v in [("Sample", c_sample), ("Pop", c_pop), ("FTP paths", c_ftp)] if v is None]
    if missing:
        print("ERROR: Missing required column(s): " + ", ".join(missing), file=sys.stderr)
        print("Detected columns:", file=sys.stderr)
        for c in df.columns:
            print("  -", c, file=sys.stderr)
        sys.exit(1)

    def val(x):
        return "" if pd.isna(x) else str(x).strip()

    for _, r in df.iterrows():
        rows.append({
            "Sample_name": val(r[c_sample]),
            "Population_code": val(r[c_pop]),
            "fastq_ftp": val(r[c_ftp]),
        })

    write_out(rows, out_path)
    print(out_path)
    sys.exit(0)

except Exception:
    pass

with open(meta_in, "r", newline="") as f:
    sample = f.read(8192)
    f.seek(0)
    try:
        dialect = csv.Sniffer().sniff(sample, delimiters=[",", "\t", ";", "|"])
        delim = dialect.delimiter
    except Exception:
        delim = "\t"

    reader = csv.reader(f, delimiter=delim)
    header = next(reader, [])
    if not header:
        print("ERROR: metadata file appears empty", file=sys.stderr)
        sys.exit(1)
    all_rows = list(reader)

def idx_candidates(header, want):
    want_n = norm(want)
    alias_ns = set(norm(a) for a in ALIASES.get(want, []))
    return [i for i, h in enumerate(header) if norm(h) == want_n or norm(h) in alias_ns]

def best_idx(all_rows, idxs):
    if not idxs:
        return None
    best = None
    best_score = -1
    for i in idxs:
        score = 0
        for r in all_rows:
            if i < len(r):
                v = str(r[i]).strip().lower()
                if v not in NA_LIKE:
                    score += 1
        if score > best_score:
            best, best_score = i, score
    return best

idx_sample = best_idx(all_rows, idx_candidates(header, "Sample_name"))
idx_pop = best_idx(all_rows, idx_candidates(header, "Population_code"))
idx_ftp = best_idx(all_rows, idx_candidates(header, "fastq_ftp"))

missing = [k for k, v in [("Sample", idx_sample), ("Pop", idx_pop), ("FTP paths", idx_ftp)] if v is None]
if missing:
    print("ERROR: Missing required column(s): " + ", ".join(missing), file=sys.stderr)
    print("Detected columns:", file=sys.stderr)
    for c in header:
        print("  -", c, file=sys.stderr)
    sys.exit(1)

for r in all_rows:
    rows.append({
        "Sample_name": (r[idx_sample] if idx_sample < len(r) else "").strip(),
        "Population_code": (r[idx_pop] if idx_pop < len(r) else "").strip(),
        "fastq_ftp": (r[idx_ftp] if idx_ftp < len(r) else "").strip(),
    })

write_out(rows, out_path)
print(out_path)
PY
)"
[[ -s "$META_TSV" ]] || die "Normalized metadata TSV not found or empty: $META_TSV"
log "Using normalized metadata TSV: $META_TSV"
log "Normalized TSV rows (excluding header): $(( $(wc -l < "$META_TSV") - 1 ))"

# ---- Build path files + job manifest ----
PATHS_DIR="${SCRIPT_DIR}/paths"
mkdir -p "$PATHS_DIR"

JOBLIST="${PATHS_DIR}/joblist.tsv"
printf "Sample\tPop\tPathFile\n" > "$JOBLIST"

_header="$(head -n1 "$META_TSV" | tr -d '\r')"
IFS=$'\t' read -r -a HEADERS <<< "$_header"
declare -A COL
for idx in "${!HEADERS[@]}"; do
  COL["${HEADERS[$idx]}"]=$((idx+1))
done

for need in "Sample_name" "Population_code" "fastq_ftp"; do
  [[ -n "${COL[$need]:-}" ]] || die "Missing required column in normalized TSV: '$need'"
done

idx0() { echo $(( ${COL[$1]} - 1 )); }
safe_get() {
  local name="$1"
  local -n arr="$2"
  local i
  i=$(idx0 "$name")
  [[ $i -ge 0 && $i -lt ${#arr[@]} ]] && printf '%s' "${arr[$i]-}" || printf ''
}

SEEN=0
SKIP_SP=0
SKIP_FTP=0
SKIP_EMPTY_PATHFILE=0
line_no=1
job_count=0

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  ((++line_no))
  LINE="${LINE%$'\r'}"
  [[ -z "$LINE" ]] && continue

  IFS=$'\t' read -r -a FIELDS <<< "$LINE"

  SAMPLE="$(trim "$(safe_get "Sample_name" FIELDS)")"
  POPCODE="$(trim "$(safe_get "Population_code" FIELDS)")"
  FASTQ_FTP="$(trim "$(safe_get "fastq_ftp" FIELDS)")"
  FTP_UPPER="$(tr '[:lower:]' '[:upper:]' <<<"$FASTQ_FTP")"

  ((++SEEN)) || true

  if [[ -z "$SAMPLE" || -z "$POPCODE" ]]; then
    ((++SKIP_SP)) || true
    (( SKIP_SP <= 5 )) && log "WARN line $line_no: missing SAMPLE/POPCODE"
    continue
  fi

  if [[ -z "$FASTQ_FTP" || "$FTP_UPPER" == "NA" || "$FTP_UPPER" == "N/A" || "$FTP_UPPER" == "NONE" || "$FTP_UPPER" == "NAN" ]]; then
    ((++SKIP_FTP)) || true
    (( SKIP_FTP <= 10 )) && log "WARN line $line_no (${POPCODE}/${SAMPLE}): fastq_ftp empty/NA-like"
    continue
  fi

  SAFE_POP="$(safe_name "$POPCODE")"
  SAFE_SAMPLE="$(safe_name "$SAMPLE")"
  PATH_FILE="${PATHS_DIR}/${SAFE_POP}_${SAFE_SAMPLE}.paths.tsv"
  : > "$PATH_FILE"

  IFS=';' read -r -a ftp_paths <<< "$FASTQ_FTP"
  for ftp_path in "${ftp_paths[@]}"; do
    ftp_path="$(trim "$ftp_path")"
    [[ -z "$ftp_path" ]] && continue

    cleaned="${ftp_path#*ftp.sra.ebi.ac.uk/}"
    dest_file="$(basename "$cleaned")"

    [[ -z "$cleaned" || -z "$dest_file" || "$dest_file" == "." ]] && continue
    printf "%s\t%s\n" "$cleaned" "$dest_file" >> "$PATH_FILE"
  done

  if [[ ! -s "$PATH_FILE" ]]; then
    rm -f "$PATH_FILE"
    ((++SKIP_EMPTY_PATHFILE)) || true
    (( SKIP_EMPTY_PATHFILE <= 10 )) && log "WARN line $line_no (${POPCODE}/${SAMPLE}): no valid FTP entries after parsing"
    continue
  fi

  printf "%s\t%s\t%s\n" "$SAMPLE" "$POPCODE" "$PATH_FILE" >> "$JOBLIST"
  ((++job_count))
done < <(tail -n +2 "$META_TSV")

log "Parse summary: seen=$SEEN kept=$job_count skipped_missing_sample_pop=$SKIP_SP skipped_missing_ftp=$SKIP_FTP skipped_empty_pathfile=$SKIP_EMPTY_PATHFILE"
(( job_count > 0 )) || die "No valid samples found after parsing metadata."
log "Prepared $job_count jobs. Manifest: $JOBLIST"

# ---- PHASE 1: submit initial CAP_XFER immediately ----
submitted=0
while IFS=$'\t' read -r SAMPLE POPCODE PATH_FILE; do
  [[ "$SAMPLE" == "Sample" ]] && continue
  (( submitted >= CAP_XFER )) && break

  out="$(
    sbatch \
      --mail-type=NONE \
      "${CHILD_SBATCH_OPTS[@]}" \
      --job-name="xfer_${RUN_ID}_${POPCODE}_${SAMPLE}" \
      --output="logs/xfer_${RUN_ID}_%j_${POPCODE}_${SAMPLE}.out" \
      --error="logs/xfer_${RUN_ID}_%j_${POPCODE}_${SAMPLE}.err" \
      --export=ALL,PIPELINE_CONFIG="$PIPELINE_CONFIG",RUN_ID="$RUN_ID",SAMPLE="$SAMPLE",POPCODE="$POPCODE",PATH_FILE="$PATH_FILE" \
      "$CHILD_TRANSFER_SCRIPT" 2>&1
  )" || die "sbatch failed for ${POPCODE}/${SAMPLE}: $out"

  jid="$(awk '/Submitted batch job/ {print $4}' <<<"$out" | tail -n1)"
  [[ -n "${jid:-}" ]] || die "Could not parse jobid from: $out"

  ((++submitted))
  log "Submitted initial transfer job $jid for ${POPCODE}/${SAMPLE} (initial ${submitted}/${CAP_XFER})"
done < "$JOBLIST"

# ---- PHASE 2: steady-state (Slurm-only cap) ----
total_jobs="$(awk 'NR>1{n++} END{print n+0}' "$JOBLIST")"
cursor=0
submitted_total="$submitted"

while IFS=$'\t' read -r SAMPLE POPCODE PATH_FILE; do
  [[ "$SAMPLE" == "Sample" ]] && continue
  ((++cursor))

  if (( cursor <= submitted )); then
    continue
  fi

  wait_for_xfer_slot

  out="$(
    sbatch \
      --mail-type=NONE \
      "${CHILD_SBATCH_OPTS[@]}" \
      --job-name="xfer_${RUN_ID}_${POPCODE}_${SAMPLE}" \
      --output="logs/xfer_${RUN_ID}_%j_${POPCODE}_${SAMPLE}.out" \
      --error="logs/xfer_${RUN_ID}_%j_${POPCODE}_${SAMPLE}.err" \
      --export=ALL,PIPELINE_CONFIG="$PIPELINE_CONFIG",RUN_ID="$RUN_ID",SAMPLE="$SAMPLE",POPCODE="$POPCODE",PATH_FILE="$PATH_FILE" \
      "$CHILD_TRANSFER_SCRIPT" 2>&1
  )" || die "sbatch failed for ${POPCODE}/${SAMPLE}: $out"

  jid="$(awk '/Submitted batch job/ {print $4}' <<<"$out" | tail -n1)"
  [[ -n "${jid:-}" ]] || die "Could not parse jobid from: $out"

  ((++submitted_total))
  printf "\n"
  log "Submitted transfer job $jid for ${POPCODE}/${SAMPLE} (submitted ${submitted_total}/${total_jobs}); slurm_xfer_notdone=$(slurm_xfer_notdone_count)"

  sleep 0.2
done < "$JOBLIST"

log "Done submitting all transfer jobs (Slurm-only cap CAP_XFER=${CAP_XFER})."