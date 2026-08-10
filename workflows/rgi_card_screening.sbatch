#!/usr/bin/env bash
# =============================================================================
# Antibiotic-resistance-gene screening of wastewater metagenomes (SLURM array)
#
#   adapter/quality trimming (skewer) -> duplicate removal (BBTools dedupe)
#     -> repair into paired FASTQs (BBTools reformat)
#     -> `rgi load` of the CARD + WILDCARD reference data
#     -> `rgi bwt` read-level ARG quantification against CARD, and against
#        CARD + WILDCARD
#
# Read-based, reference-driven: it quantifies resistance determinants directly
# from reads, so it does not depend on a sample assembling well. It is a
# complement to metagenomics_wgs_pipeline.sbatch, not a subset of it.
#
# One array task == one sample. DO NOT run `sbatch` on this file directly.
# Launch with:
#
#   bin/submit_pipeline.sh config/rgi_pipeline.config.sh \
#                          workflows/rgi_card_screening.sbatch
# =============================================================================

#SBATCH --job-name=rgi_card_screening
#SBATCH --partition=cpu
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=20
#SBATCH --mem-per-cpu=2000
#SBATCH --time=01:30:00
#SBATCH --mail-type=ALL
#SBATCH --mail-user=your.email@example.com
#SBATCH --qos=normal
#SBATCH --output=slurm-%A_%a_rgi.out
#SBATCH --array=0-0          # placeholder -- always overridden by the launcher

set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Configuration
# ---------------------------------------------------------------------------

: "${PIPELINE_CONFIG:?PIPELINE_CONFIG not set -- launch via bin/submit_pipeline.sh}"
: "${SAMPLE_MANIFEST:?SAMPLE_MANIFEST not set -- launch via bin/submit_pipeline.sh}"
: "${RUN_OUTPUT_DIR:?RUN_OUTPUT_DIR not set -- launch via bin/submit_pipeline.sh}"
: "${SLURM_ARRAY_TASK_ID:?not running as a SLURM job array}"

# shellcheck disable=SC1090
source "$PIPELINE_CONFIG"

export LC_ALL=C
THREADS="${SLURM_CPUS_PER_TASK:-1}"

module load "${SINGULARITY_MODULE:-singularity}"

# ---------------------------------------------------------------------------
# 2. Resolve this task's sample from the manifest
# ---------------------------------------------------------------------------

manifest_line=$((SLURM_ARRAY_TASK_ID + 1))
IFS=$'\t' read -r SAMPLE R1 R2 < <(sed -n "${manifest_line}p" "$SAMPLE_MANIFEST")

if [[ -z "${SAMPLE:-}" ]]; then
	echo "ERROR: no manifest entry at line ${manifest_line} of ${SAMPLE_MANIFEST}" >&2
	exit 1
fi

echo "=== task ${SLURM_ARRAY_TASK_ID}: sample '${SAMPLE}' ==="
echo "    R1: ${R1}"
echo "    R2: ${R2}"

WORK="${RUN_OUTPUT_DIR}/work/${SAMPLE}"
mkdir -p "$WORK" "$OUT_RGI"
cd "$WORK"

log() { printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }

# ---------------------------------------------------------------------------
# 3. Per-sample writable CARD database
# ---------------------------------------------------------------------------
# `rgi load` writes into RGI's own installation prefix, which is read-only in
# the image and, worse, is a single shared location: concurrent array tasks
# would race on it. Each task therefore gets its own _db/_data on scratch,
# bind-mounted over the in-container path.

CARD_TASK_TMP="${CARD_TEMP}/${SLURM_ARRAY_JOB_ID:-manual}_${SAMPLE}"
mkdir -p "${CARD_TASK_TMP}/_db" "${CARD_TASK_TMP}/_data"
# 0700, not the original 0777: only this job's user ever needs to write here,
# and CARD_TEMP is shared scratch.
chmod -R 0700 "$CARD_TASK_TMP"

cleanup() {
	rm -rf "$CARD_TASK_TMP"
	if [[ "${KEEP_INTERMEDIATE_FASTQ:-false}" != "true" ]]; then
		rm -f "${WORK}/${SAMPLE}_deduped_R1.fastq.gz" "${WORK}/${SAMPLE}_deduped_R2.fastq.gz"
	fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 4. Container invocations
# ---------------------------------------------------------------------------

BINDS="${SINGULARITY_BINDS:-/project,/scratch}"
SEXEC=(singularity exec -B "${BINDS}" -B "${RUN_OUTPUT_DIR}:${RUN_OUTPUT_DIR}")

SKEWER=("${SEXEC[@]}" "$SKEWER_CONTAINER")
BB=(    "${SEXEC[@]}" "$BBTOOLS_CONTAINER")
RGI=(   "${SEXEC[@]}"
        -B "${CARD_TASK_TMP}/_db:${RGI_DB_PREFIX}/_db"
        -B "${CARD_TASK_TMP}/_data:${RGI_DB_PREFIX}/_data"
        "$RGI_CONTAINER")

# ---------------------------------------------------------------------------
# 5. Read preprocessing
# ---------------------------------------------------------------------------

log "skewer: trimming ${SAMPLE}"
"${SKEWER[@]}" skewer \
	-Q "${SKEWER_MEAN_QUALITY:-20}" -q "${SKEWER_END_QUALITY:-20}" -m pe \
	-x "$ADAPTORS_R1" -y "$ADAPTORS_R2" \
	-l "${SKEWER_MIN_LENGTH:-35}" \
	-r "${SKEWER_MAX_ERROR_RATE:-0.05}" \
	-d "${SKEWER_MAX_INDEL_RATE:-0.015}" \
	-o "${WORK}/${SAMPLE}_skewer" -z \
	-t "$THREADS" \
	"$R1" "$R2"

for f in "${WORK}/${SAMPLE}_skewer-trimmed-pair1.fastq.gz" \
         "${WORK}/${SAMPLE}_skewer-trimmed-pair2.fastq.gz"; do
	[[ -s "$f" ]] || { echo "ERROR: skewer produced no output: ${f}" >&2; exit 1; }
done

log "dedupe.sh: removing duplicate reads"
"${BB[@]}" dedupe.sh \
	in="${WORK}/${SAMPLE}_skewer-trimmed-pair1.fastq.gz,${WORK}/${SAMPLE}_skewer-trimmed-pair2.fastq.gz" \
	out="${WORK}/${SAMPLE}_deduped_interleaved.fastq.gz" \
	ziplevel="${BBTOOLS_ZIPLEVEL:-7}" \
	interleaved=t \
	absorbrc=t \
	absorbmatch=t \
	absorbcontainment=t \
	uniqueonly=f \
	threads="$THREADS" \
	-Xmx"${BBTOOLS_XMX:-55g}"

log "reformat.sh: splitting deduplicated reads back into pairs"
"${BB[@]}" reformat.sh \
	in="${WORK}/${SAMPLE}_deduped_interleaved.fastq.gz" int=t zl="${BBTOOLS_ZIPLEVEL:-7}" \
	out1="${WORK}/${SAMPLE}_deduped_R1.fastq.gz" \
	out2="${WORK}/${SAMPLE}_deduped_R2.fastq.gz" \
	-Xmx"${BBTOOLS_XMX:-55g}"

rm -f "${WORK}/${SAMPLE}_deduped_interleaved.fastq.gz" \
      "${WORK}/${SAMPLE}"_skewer-trimmed-pair[1-2].fastq.gz

# ---------------------------------------------------------------------------
# 6. Load the CARD reference data into this task's private RGI database
# ---------------------------------------------------------------------------

log "rgi load: CARD ${CARD_VERSION} / WILDCARD ${WILDCARD_VERSION}"
"${RGI[@]}" rgi load \
	--card_json "${CARD_REFDAT}/card.json" \
	--wildcard_annotation_all_models "${CARD_REFDAT}/wildcard_database_${WILDCARD_VERSION}_all.fasta" \
	--wildcard_annotation "${CARD_REFDAT}/wildcard_database_${WILDCARD_VERSION}.fasta" \
	--wildcard_index "${CARD_REFDAT}/wildcard/index-for-model-sequences.txt" \
	--card_annotation_all_models "${CARD_REFDAT}/card_database_${CARD_VERSION}_all.fasta" \
	--card_annotation "${CARD_REFDAT}/card_database_${CARD_VERSION}.fasta" \
	--amr_kmers "${CARD_REFDAT}/wildcard/all_amr_${KMER_SIZE:-61}mers.txt" \
	--kmer_database "${CARD_REFDAT}/wildcard/${KMER_SIZE:-61}_kmer_db.json" \
	--kmer_size "${KMER_SIZE:-61}"

# ---------------------------------------------------------------------------
# 7. Read-level ARG quantification
# ---------------------------------------------------------------------------
# Two passes: the curated CARD models only (high confidence, publishable
# counts), and CARD + WILDCARD (in silico predicted resistance variants, wider
# net, needs more careful interpretation).

run_bwt() {
	local out_subdir="$1"; shift
	local out_dir="${OUT_RGI}/${out_subdir}"
	mkdir -p "$out_dir"

	log "rgi bwt -> ${out_dir}/${SAMPLE}"
	# Output goes to a per-sample log instead of /dev/null: `rgi bwt` is chatty,
	# but discarding stderr as the original did also discards the reason for a
	# failure.
	"${RGI[@]}" rgi bwt \
		--read_one "${WORK}/${SAMPLE}_deduped_R1.fastq.gz" \
		--read_two "${WORK}/${SAMPLE}_deduped_R2.fastq.gz" \
		--output_file "${out_dir}/${SAMPLE}" \
		--threads "$THREADS" \
		--clean \
		"$@" > "${RUN_OUTPUT_DIR}/${SAMPLE}_rgi_bwt_${out_subdir}.log" 2>&1
}

if [[ "${RUN_BWT_CARD:-true}" == "true" ]]; then
	run_bwt bwt_out_card
fi

if [[ "${RUN_BWT_WILDCARD:-true}" == "true" ]]; then
	run_bwt bwt_out_wild --include_wildcard
fi

log "sample ${SAMPLE} finished"
