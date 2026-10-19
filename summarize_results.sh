#!/usr/bin/env bash
set -euo pipefail

ROOT="./results_all_876_ancients_testing"
OUTFILE="$ROOT/combined_copy_numbers.tsv"

shopt -s nullglob

# Get all unique gene names directly into an array
mapfile -t GENES < <(
    for popdir in "$ROOT"/*/; do
        [[ -d "$popdir" ]] || continue
        for file in "$popdir"/*_cn.txt; do
            [[ -f "$file" ]] || continue
            awk '!/^#/ && $1!="Gene" && NF>=2 {print $1}' "$file"
        done
    done | sort -u
)

# sanity check
if [[ ${#GENES[@]} -eq 0 ]]; then
    echo "ERROR: No genes found in $ROOT/*/*_cn.txt" >&2
    exit 1
fi

# header
{
    printf "sample_id\tpop"
    for g in "${GENES[@]}"; do
        printf "\t%s" "$g"
    done
    printf "\n"
} > "$OUTFILE"

# rows
for popdir in "$ROOT"/*/; do
    [[ -d "$popdir" ]] || continue
    pop=$(basename "$popdir")

    for file in "$popdir"/*_cn.txt; do
        [[ -f "$file" ]] || continue
        sample=$(basename "$file" _cn.txt)

        declare -A sample_cn=()

        while read -r gene cn median nkmers; do
            [[ -n "${gene:-}" ]] || continue
            sample_cn["$gene"]="$cn"
        done < <(
            awk '!/^#/ && $1!="Gene" && NF>=2 {print $1, $2, $3, $4}' "$file"
        )

        printf "%s\t%s" "$sample" "$pop" >> "$OUTFILE"
        for g in "${GENES[@]}"; do
            printf "\t%s" "${sample_cn["$g"]:-NA}" >> "$OUTFILE"
        done
        printf "\n" >> "$OUTFILE"

        unset sample_cn
    done
done

{
head -n 1 "$OUTFILE"
tail -n +2 "$OUTFILE" | sort -k2,2 -k1,1
} > "$OUTFILE.tmp"

mv "$OUTFILE.tmp" "$OUTFILE"

echo "Combined CN table written to:"
echo "$OUTFILE"