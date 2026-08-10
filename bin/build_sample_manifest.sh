#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# build_sample_manifest.sh -- turn a directory of FASTQ files into an explicit,
# ordered sample manifest.
#
#   Usage: build_sample_manifest.sh <config.sh> [output.tsv]
#
# Writes a 3-column TSV (no header) to stdout, or to <output.tsv> if given:
#
#   <sample_name>\t<absolute R1 path>\t<absolute R2 path>
#
# Line N of this file is consumed by array task N-1. Materialising the sample
# list once, instead of re-globbing inside every array task, means:
#   * the array bound and the array tasks can never disagree,
#   * a file appearing in / disappearing from INPUT_DIR mid-run cannot silently
#     shift every sample onto the wrong index,
#   * the manifest is a record of exactly what a given job ID processed.
# -----------------------------------------------------------------------------

set -euo pipefail

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[[ $# -ge 1 ]] || usage
config="$1"
output="${2:-}"

[[ -r "$config" ]] || { echo "ERROR: cannot read config: $config" >&2; exit 1; }
# shellcheck disable=SC1090
source "$config"

: "${INPUT_DIR:?INPUT_DIR not set in $config}"
: "${FASTQ_GLOB:?FASTQ_GLOB not set in $config}"
: "${R1_SUFFIX:?R1_SUFFIX not set in $config}"
: "${R2_SUFFIX:?R2_SUFFIX not set in $config}"
: "${SAMPLE_NAME_MODE:=strip_suffix}"

[[ -d "$INPUT_DIR" ]] || { echo "ERROR: INPUT_DIR does not exist: $INPUT_DIR" >&2; exit 1; }

# Derive a sample name from a bare filename, honouring SAMPLE_NAME_MODE.
sample_name_from_filename() {
	local fname="$1"
	case "$SAMPLE_NAME_MODE" in
		strip_suffix)
			printf '%s' "${fname%"$R1_SUFFIX"}"
			;;
		cut_fields)
			: "${SAMPLE_DELIM:?SAMPLE_DELIM not set (required for cut_fields)}"
			: "${SAMPLE_NAME_FIELDS:?SAMPLE_NAME_FIELDS not set (required for cut_fields)}"
			printf '%s' "$(cut -d "$SAMPLE_DELIM" -f"-${SAMPLE_NAME_FIELDS}" <<< "$fname")"
			;;
		*)
			echo "ERROR: unknown SAMPLE_NAME_MODE '$SAMPLE_NAME_MODE'" \
			     "(expected strip_suffix or cut_fields)" >&2
			exit 1
			;;
	esac
}

shopt -s nullglob
matches=("$INPUT_DIR"/$FASTQ_GLOB)
shopt -u nullglob

if [[ ${#matches[@]} -eq 0 ]]; then
	echo "ERROR: no files match '${FASTQ_GLOB}' in ${INPUT_DIR}" >&2
	exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

declare -A seen=()
for path in "${matches[@]}"; do
	fname="$(basename "$path")"
	sample="$(sample_name_from_filename "$fname")"

	if [[ -z "$sample" ]]; then
		echo "ERROR: derived an empty sample name from '${fname}'" >&2
		exit 1
	fi
	# cut_fields collapses several files onto one sample name by design; keep
	# the first occurrence, exactly as the original `| uniq` did.
	[[ -n "${seen[$sample]:-}" ]] && continue
	seen["$sample"]=1

	r1="${INPUT_DIR}/${sample}${R1_SUFFIX}"
	r2="${INPUT_DIR}/${sample}${R2_SUFFIX}"

	for f in "$r1" "$r2"; do
		if [[ ! -s "$f" ]]; then
			echo "ERROR: sample '${sample}': expected read file missing or empty: ${f}" >&2
			echo "       Check R1_SUFFIX/R2_SUFFIX and SAMPLE_NAME_MODE in ${config}." >&2
			exit 1
		fi
	done

	printf '%s\t%s\t%s\n' "$sample" "$r1" "$r2" >> "$tmp"
done

# Sort by sample name so the index -> sample mapping is deterministic regardless
# of directory order or locale.
LC_ALL=C sort -k1,1 "$tmp" -o "$tmp"

if [[ -n "$output" ]]; then
	mkdir -p "$(dirname "$output")"
	cp "$tmp" "$output"
else
	cat "$tmp"
fi
