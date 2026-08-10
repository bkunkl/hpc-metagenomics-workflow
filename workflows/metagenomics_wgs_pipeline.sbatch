#!/usr/bin/env bash
# =============================================================================
# Shotgun metagenomics pipeline for wastewater samples (SLURM job array)
#
#   read trimming (bbduk) -> host/vector decontamination (bowtie2)
#     -> taxonomic profiling (Kraken2 + Bracken)
#     -> assembly (MEGAHIT and IDBA-UD, in parallel branches)
#     -> contig renaming (anvi'o) -> read mapping (bowtie2/samtools)
#     -> binning (MetaBAT2) -> bin QC (CheckM, CheckM2)
#     -> MAG taxonomy (GTDB-Tk)
#
# One array task == one sample. DO NOT run `sbatch` on this file directly: the
# --array bound below is a placeholder. Launch with:
#
#   bin/submit_pipeline.sh config/wgs_pipeline.config.sh \
#                          workflows/metagenomics_wgs_pipeline.sbatch
#
# The launcher computes --array from the sample manifest and overrides the
# resource directives below from the config file.
# =============================================================================

#SBATCH --job-name=wgs_metagenomics
#SBATCH --partition=cpu
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=60
#SBATCH --mem=120G
#SBATCH --time=24:00:00
#SBATCH --mail-type=ALL
#SBATCH --mail-user=your.email@example.com
#SBATCH --qos=normal
#SBATCH --output=slurm-%A_%a_wgs_metagen.out
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

# Avoid locale-dependent sorting/collation inside the tools.
export LC_ALL=C

# Threads available to this array task.
THREADS="${SLURM_CPUS_PER_TASK:-1}"

module load "${SINGULARITY_MODULE:-singularity}"

# ---------------------------------------------------------------------------
# 2. Resolve this task's sample from the manifest
# ---------------------------------------------------------------------------
# The manifest was written once, by the launcher, before submission. Reading a
# fixed file beats re-globbing the input directory in every task: the array
# bound and the sample list are guaranteed to match, and a file appearing or
# disappearing mid-run cannot shift every sample onto a different index.

manifest_line=$((SLURM_ARRAY_TASK_ID + 1))
IFS=$'\t' read -r SAMPLE R1 R2 < <(sed -n "${manifest_line}p" "$SAMPLE_MANIFEST")

if [[ -z "${SAMPLE:-}" ]]; then
	echo "ERROR: no manifest entry at line ${manifest_line} of ${SAMPLE_MANIFEST}" >&2
	exit 1
fi

# Short identifier used to prefix renamed contigs and to name BAM/bin files.
# Configurable because the original hardcoded `cut -d '_' -f2`, which only makes
# sense for one particular naming scheme.
if [[ -n "${SAMPLE_ID_FIELD:-}" ]]; then
	SID="$(cut -d "${SAMPLE_DELIM:-_}" -f"${SAMPLE_ID_FIELD}" <<< "$SAMPLE")"
else
	SID="$SAMPLE"
fi
[[ -n "$SID" ]] || { echo "ERROR: SAMPLE_ID_FIELD=${SAMPLE_ID_FIELD} yielded an empty id for '${SAMPLE}'" >&2; exit 1; }

echo "=== task ${SLURM_ARRAY_TASK_ID}: sample '${SAMPLE}' (id '${SID}') ==="
echo "    R1: ${R1}"
echo "    R2: ${R2}"

# Per-sample scratch for intermediates. The original wrote trimmed and
# decontaminated FASTQs straight back into the input directory, which is what
# made `ls *.fastq` pick up its own outputs on a re-run.
WORK="${RUN_OUTPUT_DIR}/work/${SAMPLE}"
mkdir -p "$WORK"
cd "$WORK"

# ---------------------------------------------------------------------------
# 3. Container invocations
# ---------------------------------------------------------------------------
# Every container gets the same bind list, plus the run directory, so that a
# tool cannot silently fail to see an input because one recipe was missing a
# bind. (In the original, the anvi'o / MetaBAT2 / CheckM / Bracken calls bound
# only /project while the working directory lived on /scratch.)

BINDS="${SINGULARITY_BINDS:-/project,/scratch}"
SEXEC=(singularity exec -B "${BINDS}" -B "${RUN_OUTPUT_DIR}:${RUN_OUTPUT_DIR}")

BB=(     "${SEXEC[@]}" "$BBTOOLS_CONTAINER" )
GENOMICS=("${SEXEC[@]}" "$GENOMICS_CONTAINER" )
K2=(     "${SEXEC[@]}" "$KRAKEN2_CONTAINER" )
BRACKEN=("${SEXEC[@]}" "$BRACKEN_CONTAINER" )
IDBA=(   "${SEXEC[@]}" "$IDBA_CONTAINER" )
ANVIO=(  "${SEXEC[@]}" "$ANVIO_CONTAINER" )
METABAT=("${SEXEC[@]}" "$METABAT2_CONTAINER" )
CHECKM=( "${SEXEC[@]}" "$CHECKM_CONTAINER" )
CHECKM2=("${SEXEC[@]}" "$CHECKM2_CONTAINER" )

# ---------------------------------------------------------------------------
# 4. Helpers
# ---------------------------------------------------------------------------

log() { printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }

# Path conventions, so no function has to guess what another produced.
raw_contigs_path() {   # $1 = assembler (megahit|idba), $2 = assembler out dir
	case "$1" in
		megahit) printf '%s/%s/%s.contigs.fa' "$2" "$SAMPLE" "$SAMPLE" ;;
		idba)    printf '%s/%s/contig.fa'     "$2" "$SAMPLE" ;;
	esac
}
renamed_contigs_path() { printf '%s/%s_contigs.fa' "$1" "$SID"; }   # $1 = assembler out dir
bam_path()             { printf '%s/%s.bam'        "$1" "$SID"; }

# ---------------------------------------------------------------------------
# 5. Pipeline steps
# ---------------------------------------------------------------------------

# --- 5.1 Adapter/quality trimming -------------------------------------------
trim_reads() {
	log "bbduk: trimming ${SAMPLE}"
	"${BB[@]}" bbduk.sh \
		in="$R1" \
		in2="$R2" \
		out="${WORK}/${SAMPLE}_R1_bbduk.fastq" \
		out2="${WORK}/${SAMPLE}_R2_bbduk.fastq" \
		ref="$ILLUMINA_ADAPTORS" \
		k=23 mink=11 hdist=1 hdist2=0 ktrim=r qtrim=rl \
		minlength=35 trimq=20 tpe tbo \
		-Xmx"${BBTOOLS_XMX:-95g}"
}

# --- 5.2 Host / vector / phage decontamination ------------------------------
# bowtie2 --un-conc writes ${prefix%.fastq}.1.fastq and .2.fastq
decontaminate_reads() {
	log "bowtie2: decontaminating ${SAMPLE} against ${INDEX_PATH}"
	"${GENOMICS[@]}" bowtie2 \
		--quiet \
		-1 "${WORK}/${SAMPLE}_R1_bbduk.fastq" \
		-2 "${WORK}/${SAMPLE}_R2_bbduk.fastq" \
		-x "$INDEX_PATH" \
		--very-sensitive-local \
		--dovetail \
		--threads "$THREADS" \
		-S /dev/null \
		--un-conc "${WORK}/${SAMPLE}_decontam.fastq"

	rm -f "${WORK}/${SAMPLE}_R1_bbduk.fastq" "${WORK}/${SAMPLE}_R2_bbduk.fastq"

	DECONTAM_R1="${WORK}/${SAMPLE}_decontam.1.fastq"
	DECONTAM_R2="${WORK}/${SAMPLE}_decontam.2.fastq"
	for f in "$DECONTAM_R1" "$DECONTAM_R2"; do
		[[ -s "$f" ]] || { echo "ERROR: decontamination produced no reads: $f" >&2; exit 1; }
	done
}

# --- 5.3 Taxonomic profiling of reads ---------------------------------------
run_k2_bracken() {
	local conf_value="$1" suffix="$2"

	log "kraken2: ${SAMPLE} at confidence ${conf_value}"
	"${K2[@]}" k2 classify \
		--db "$K2_DB" \
		--threads "$THREADS" \
		--output /dev/null \
		--confidence "$conf_value" \
		--report "${OUT_KRBR}/${SAMPLE}_${suffix}_k2.report" \
		--paired \
		--use-names \
		"$DECONTAM_R1" "$DECONTAM_R2"

	log "bracken: ${SAMPLE} at confidence ${conf_value}"
	"${BRACKEN[@]}" bracken \
		-d "$K2_DB" \
		-i "${OUT_KRBR}/${SAMPLE}_${suffix}_k2.report" \
		-o "${OUT_KRBR}/${SAMPLE}_${suffix}_k2_bracken.report" \
		-w "${OUT_KRBR}/${SAMPLE}_${suffix}_k2_bracken.newreport" \
		-l "${BRACKEN_LEVEL:-S}" \
		-r "${BRACKEN_READ_LEN:-150}"
}

# --- 5.4 Contig renaming ----------------------------------------------------
# anvi'o rewrites the assembler's contig names to short, unique, prefixed ones
# and applies the minimum-length filter.
rename_contigs() {
	local assembler="$1" assembler_out="$2"
	local fa_in fa_out
	fa_in="$(raw_contigs_path "$assembler" "$assembler_out")"
	fa_out="$(renamed_contigs_path "$assembler_out")"

	[[ -s "$fa_in" ]] || { echo "ERROR: assembler produced no contigs: ${fa_in}" >&2; return 1; }

	log "anvi-script-reformat-fasta: ${fa_in} -> ${fa_out}"
	"${ANVIO[@]}" anvi-script-reformat-fasta "$fa_in" \
		-o "$fa_out" \
		--simplify-names \
		--prefix "$SID" \
		--min-len "${MIN_CONTIG_LEN:-1000}" \
		--report-file "${assembler_out}/${SID}_contig-rename-report.txt"
}

# --- 5.5 Map reads back onto the contigs ------------------------------------
make_bams() {
	local assembler_out="$1"
	local fa_out bam idx
	fa_out="$(renamed_contigs_path "$assembler_out")"
	bam="$(bam_path "$assembler_out")"
	idx="${fa_out%.*}"

	log "bowtie2-build: indexing ${fa_out}"
	"${GENOMICS[@]}" bowtie2-build --threads "$THREADS" "$fa_out" "$idx"

	log "bowtie2: mapping ${SAMPLE} onto its own contigs"
	"${GENOMICS[@]}" bowtie2 --threads "$THREADS" \
		-x "$idx" \
		-1 "$DECONTAM_R1" \
		-2 "$DECONTAM_R2" \
		--no-unal \
		--very-sensitive-local \
		-S "${assembler_out}/${SID}.sam"

	log "samtools: sorting and indexing ${bam}"
	"${GENOMICS[@]}" samtools view -F 4 -bS -@ "$THREADS" "${assembler_out}/${SID}.sam" \
		| "${GENOMICS[@]}" samtools sort -@ "$THREADS" -o "$bam"
	"${GENOMICS[@]}" samtools index -@ "$THREADS" "$bam"

	rm -f "${assembler_out}/${SID}.sam"
	# Unquoted glob: the original quoted it, so the shell passed the literal
	# string "…/*.bt2" to rm and the indices were never removed.
	rm -f "${idx}"*.bt2 "${idx}"*.bt2l
}

# --- 5.6 MAG taxonomy -------------------------------------------------------
gtdbtk_classify_wf() {
	local bins_dir="$1" contig_size="$2"

	if [[ "$(find "$bins_dir" -maxdepth 1 -name '*.fa' | wc -l)" -eq 0 ]]; then
		log "GTDB-Tk: no bins left in ${bins_dir}, skipping"
		return 0
	fi

	local out_dir="${bins_dir}/gtdbtk_output"
	mkdir -p "$out_dir"

	log "GTDB-Tk classify_wf: ${bins_dir}"
	# GTDBTK_DATA_PATH is how gtdbtk finds its reference data; the original
	# never set it, so the run used whatever the image happened to default to.
	SINGULARITYENV_GTDBTK_DATA_PATH="$GTDBTK_PATH" \
	"${SEXEC[@]}" -B "${GTDBTK_PATH}:${GTDBTK_PATH}" "$GTDBTK_CONTAINER" \
		gtdbtk classify_wf \
			--genome_dir "$bins_dir" \
			--out_dir "$out_dir" \
			--mash_db "${MASH_DB}/gtdb_mash_db" \
			--extension fa \
			--prefix "${SAMPLE}_${contig_size}_gtdbtk" \
			--cpus "$THREADS"
}

# --- 5.7 Binning and bin QC -------------------------------------------------
binning_and_check() {
	local assembler_out="$1" contig_size="$2"
	local fa_out bam s_dir bins_dir
	fa_out="$(renamed_contigs_path "$assembler_out")"
	bam="$(bam_path "$assembler_out")"
	s_dir="${assembler_out}/${SAMPLE}"
	bins_dir="${s_dir}/metabat2-bins${contig_size}"
	mkdir -p "$bins_dir"

	log "jgi_summarize_bam_contig_depths: ${bam}"
	"${METABAT[@]}" jgi_summarize_bam_contig_depths \
		--outputDepth "${fa_out}.depth.txt" "$bam"

	log "metabat2: binning ${SAMPLE} (minContig ${contig_size})"
	"${METABAT[@]}" metabat2 \
		-t "$THREADS" \
		--inFile "$fa_out" \
		--outFile "${bins_dir}/bin" \
		--abdFile "${fa_out}.depth.txt" \
		--minContig "$contig_size"

	log "checkm lineage_wf: ${bins_dir}"
	mkdir -p "${s_dir}/checkm_output_${contig_size}"
	"${CHECKM[@]}" checkm lineage_wf \
		--extension fa "$bins_dir" "${s_dir}/checkm_output_${contig_size}" \
		--tab_table \
		--file "${s_dir}/checkm_output_${contig_size}/MAGs_checkm.tab" \
		--threads "$THREADS" \
		--pplacer_threads "$THREADS"

	log "checkm2 predict: ${bins_dir}"
	"${CHECKM2[@]}" checkm2 predict \
		--input "$bins_dir" \
		--output-directory "${s_dir}/checkm2_result_${contig_size}" \
		--database_path "$DMNDDB_PATH" \
		--extension fa \
		--threads "$THREADS"

	drop_low_quality_bins "${s_dir}/checkm2_result_${contig_size}" "$bins_dir"

	gtdbtk_classify_wf "$bins_dir" "$contig_size"
}

# Delete bins whose CheckM2 completeness is below MIN_BIN_COMPLETENESS, logging
# what was removed. The completeness column is looked up by header name rather
# than assumed to be column 2, so a CheckM2 output change cannot silently start
# thresholding the wrong column.
drop_low_quality_bins() {
	local checkm2_dir="$1" bins_dir="$2"
	local qt_path="${checkm2_dir}/quality_report.tsv"
	local log_path="${RUN_OUTPUT_DIR}/lowqual_bins_removed.log"

	[[ -s "$qt_path" ]] || { log "no CheckM2 quality report at ${qt_path}, keeping all bins"; return 0; }

	awk -F '\t' -v bd="$bins_dir" -v min="${MIN_BIN_COMPLETENESS:-70}" '
		NR == 1 {
			for (i = 1; i <= NF; i++) if ($i == "Completeness") col = i
			if (!col) { print "ERROR: no Completeness column in quality report" > "/dev/stderr"; exit 1 }
			next
		}
		$col < min { print bd "/" $1 ".fa" }
	' "$qt_path" | tee -a "$log_path" | xargs -r rm -f
	# xargs -r: without it, a run where every bin passes the threshold calls
	# `rm` with no arguments and fails the whole job under `set -e`.
}

# --- 5.8 Assembly branches --------------------------------------------------
assemble_with_megahit() {
	local assembler_out="$1"
	mkdir -p "$assembler_out"

	log "megahit: assembling ${SAMPLE}"
	# MEGAHIT refuses to start if -o already exists.
	rm -rf "${assembler_out:?}/${SAMPLE}"
	"${GENOMICS[@]}" megahit \
		-1 "$DECONTAM_R1" \
		-2 "$DECONTAM_R2" \
		-o "${assembler_out}/${SAMPLE}" \
		--out-prefix "$SAMPLE" \
		--memory 0.95 \
		--mem-flag 2 \
		--min-contig-len "${MIN_CONTIG_LEN:-1000}" \
		--presets meta-sensitive \
		-t "$THREADS"

	rm -rf "${assembler_out}/${SAMPLE}/intermediate_contigs"

	rename_contigs megahit "$assembler_out"
	make_bams "$assembler_out"
	binning_and_check "$assembler_out" "${BINNING_MIN_CONTIG:-2500}"
}

assemble_with_idba() {
	local assembler_out="$1"
	mkdir -p "${assembler_out}/${SAMPLE}"

	log "fq2fa: converting ${SAMPLE} for IDBA-UD"
	"${IDBA[@]}" fq2fa --merge --filter \
		"$DECONTAM_R1" "$DECONTAM_R2" "${assembler_out}/${SAMPLE}.fa"

	log "idba_ud: assembling ${SAMPLE}"
	"${IDBA[@]}" idba_ud \
		-r "${assembler_out}/${SAMPLE}.fa" \
		--mink 24 \
		--maxk 124 \
		--step 10 \
		--min_contig "${MIN_CONTIG_LEN:-1000}" \
		--num_threads "$THREADS" \
		-o "${assembler_out}/${SAMPLE}"

	cleanup_idba "${assembler_out}/${SAMPLE}"

	rename_contigs idba "$assembler_out"
	make_bams "$assembler_out"
	binning_and_check "$assembler_out" "${BINNING_MIN_CONTIG:-2500}"
}

# IDBA-UD leaves one file per k-mer step behind; on a metagenome that is tens of
# GB of intermediates that nothing downstream reads.
cleanup_idba() {
	local base_path="$1"
	rm -f "${base_path}.fa"
	local prefix
	for prefix in contig- graph- local-contig- align- kmer; do
		find "$base_path" -maxdepth 1 -type f -name "${prefix}*" -delete
	done
}

# ---------------------------------------------------------------------------
# 6. Main
# ---------------------------------------------------------------------------

mkdir -p "$OUT_MEGAHIT" "$OUT_IDBA" "$OUT_KRBR"

trim_reads
decontaminate_reads

assemble_with_megahit "$OUT_MEGAHIT"
assemble_with_idba    "$OUT_IDBA"

for level in "${K2_CONFIDENCE_LEVELS[@]}"; do
	run_k2_bracken "${level%%:*}" "${level##*:}"
done

log "sample ${SAMPLE} finished"
