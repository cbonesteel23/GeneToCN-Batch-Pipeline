#!/usr/bin/env bash
#SBATCH --account=omergokc
#SBATCH --partition=general-compute
#SBATCH --qos=nih
#SBATCH --time=03:00:00
#SBATCH --nodes=1
#SBATCH --mem=300G
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16

set -euo pipefail
mkdir -p logs
: "${SLURM_SUBMIT_DIR:=$PWD}"

log() { echo "[$(date +'%F %T')] $*"; }
die() { echo "[$(date +'%F %T')] ERROR: $*" >&2; exit 1; }

: "${PIPELINE_CONFIG:?Missing PIPELINE_CONFIG (path to gene2cn.env)}"
[[ -s "$PIPELINE_CONFIG" ]] || die "Config file not found or empty: $PIPELINE_CONFIG"
# shellcheck disable=SC1090
source "$PIPELINE_CONFIG"

: "${SAMPLE:?}"
: "${POPCODE:?}"

# --- Environment/tools ---
: "${CONDA_HOOK:?}"
: "${COMPUTE_CONDA_ENV:?}"
eval "$(${CONDA_HOOK} shell.bash hook)"
conda activate "${COMPUTE_CONDA_ENV}"

: "${database_location:?}"
: "${gm:?}"
: "${regions_txt:?}"
: "${KMER_SCRIPT:?}"
: "${db_file:?}"

: "${path_genomes:?}"
: "${vscratch_dir:?}"

# --- Inputs transferred by Globus (must match transfer script destination) ---
fastq_dir="${vscratch_dir%/}/${POPCODE}/${SAMPLE}"

# --- Results under submission directory ---
results_base="${SLURM_SUBMIT_DIR}/results"
mkdir -p "${results_base}"
cd "${results_base}"
mkdir -p "${POPCODE}"

done_marker="${results_base}/${POPCODE}/${SAMPLE}.done"

cleanup_inputs() {
  local sample_dir="${vscratch_dir%/}/${POPCODE}/${SAMPLE}"
  local pop_dir="${vscratch_dir%/}/${POPCODE}"

  # Safety check: only operate inside /vscratch
  if [[ "$sample_dir" == /vscratch/* && -d "$sample_dir" ]]; then
    log "Removing entire sample directory: ${sample_dir}"
    rm -rf "$sample_dir"

    # If population directory is now empty, remove it too
    if [[ -d "$pop_dir" ]] && [[ -z "$(ls -A "$pop_dir")" ]]; then
      log "Population directory empty — removing: ${pop_dir}"
      rmdir "$pop_dir"
    fi
  else
    log "Skip cleanup: '${sample_dir}' not under /vscratch or does not exist."
  fi
}

cleanup_on_exit() {
  local exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    log "Job finished successfully for ${POPCODE}/${SAMPLE}"
  else
    log "Job failed for ${POPCODE}/${SAMPLE} (exit code: $exit_code)"
  fi
  cleanup_inputs
}

trap cleanup_on_exit EXIT

if [[ -s "$done_marker" ]]; then
  log "Marker exists ($done_marker) — g2CN already computed for ${POPCODE}/${SAMPLE}."
  exit 0
fi

[[ -d "$fastq_dir" ]] || die "FASTQ directory not found: $fastq_dir"

mapfile -t fastq_arr < <(
  find "$fastq_dir" -type f \( -name '*.fastq.gz' -o -name '*.fq.gz' -o -name '*.fastq' -o -name '*.fq' \) \
    -exec realpath {} \;
)
(( ${#fastq_arr[@]} > 0 )) || die "No FASTQs found in $fastq_dir"

log "Running gene2CN for ${POPCODE}/${SAMPLE}…"
log "FASTQ dir: $fastq_dir"
log "FASTQ count: ${#fastq_arr[@]}"

python3 "$KMER_SCRIPT" \
  -db "$db_file" \
  -kp "$database_location" \
  -s "${fastq_arr[@]}" \
  -d "${POPCODE}" \
  -o "${SAMPLE}" \
  -gm "$gm" \
  -r "$regions_txt"

date > "$done_marker"
log "Done ${POPCODE}/${SAMPLE}"
