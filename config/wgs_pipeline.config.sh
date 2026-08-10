#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Configuration for workflows/metagenomics_wgs_pipeline.sbatch
#
# This file is sourced by BOTH the launcher (bin/submit_pipeline.sh) and the
# job script itself, so that the sample list used to size the SLURM array is
# guaranteed to be the same list the array tasks index into.
#
# Copy this file, edit the copy, and pass it to the launcher:
#   bin/submit_pipeline.sh config/my_run.config.sh
# -----------------------------------------------------------------------------

# ------------------------------ Input handling -------------------------------

# Directory holding the raw paired-end FASTQ files. Read-only as far as the
# pipeline is concerned -- all intermediates go under RUN_DIR.
INPUT_DIR="/path/to/working_fastqs"

# Glob matching exactly ONE file per sample (normally the R1 file). Restricting
# the glob to the R1 suffix is important: a bare "*.fastq" also matches
# intermediate files written by previous runs (*_bbduk.fastq, *_decontam.1.fastq)
# and silently corrupts the sample list.
FASTQ_GLOB="*_R1_merged.fastq"

# How a sample name is derived from the matched filename.
#   strip_suffix : sample = filename with $R1_SUFFIX removed.  (recommended;
#                  works with any naming scheme, no field counting)
#   cut_fields   : sample = first $SAMPLE_NAME_FIELDS fields of the filename,
#                  split on $SAMPLE_DELIM. Reproduces the original
#                  `ls *.fastq | cut -d '_' -f-2 | uniq` behaviour.
SAMPLE_NAME_MODE="strip_suffix"

# Read-file suffixes appended to the sample name to rebuild the R1/R2 paths.
R1_SUFFIX="_R1_merged.fastq"
R2_SUFFIX="_R2_merged.fastq"

# Only used when SAMPLE_NAME_MODE="cut_fields".
SAMPLE_DELIM="_"
SAMPLE_NAME_FIELDS=2

# Short identifier used to prefix renamed contigs and to name BAM/bin files.
# The original script hardcoded `cut -d '_' -f2` ("sample number"), which assumes
# a naming scheme such as OWTS_03_L001. Options:
#   ""          : use the full sample name (safe default, no assumptions)
#   <integer>   : use field N of the sample name, split on $SAMPLE_DELIM
SAMPLE_ID_FIELD=""

# ------------------------------ Reference data -------------------------------
# See docs/databases.md for how to obtain each of these.

# bowtie2 index prefix for decontamination (human + vector/phage, e.g. GRCh38 + UniVec)
INDEX_PATH="/path/to/databases/decontamination/GRCh38_UniVec.index"

# Kraken2 "pluspf" database directory (also used by Bracken)
K2_DB="/path/to/databases/k2_pluspf_20260626"

# Illumina adapter FASTA for bbduk
ILLUMINA_ADAPTORS="/path/to/databases/Illumina_adaptors.fasta"

# CheckM2 DIAMOND database (uniref100.KO.1.dmnd)
DMNDDB_PATH="/path/to/databases/uniref100.KO.1.dmnd"

# GTDB-Tk reference data release directory, and its Mash sketch DB
GTDBTK_PATH="/path/to/databases/gtdbtk_ref_data/release220"
MASH_DB="${GTDBTK_PATH}/mash_db"

# ------------------------------ Output layout --------------------------------

OUT_MEGAHIT="/path/to/project/assembly_megahit"
OUT_IDBA="/path/to/project/assembly_IDBA"
OUT_KRBR="/path/to/project/kraken-bracken"

# Where the launcher writes the sample manifest and the per-run log directory.
RUN_DIR="/path/to/project/runs"

# ------------------------------ Containers -----------------------------------
# Recipes for all of these live in build_singularity_containers/.

CONTAINER_DIR="/path/to/containers"

BBTOOLS_CONTAINER="${CONTAINER_DIR}/bbtools.sif"
GENOMICS_CONTAINER="${CONTAINER_DIR}/datascience_genomics.sif"
KRAKEN2_CONTAINER="${CONTAINER_DIR}/kraken2_v2.17.1_bracken_v3.1_vmtouch.sif"
BRACKEN_CONTAINER="${KRAKEN2_CONTAINER}"
IDBA_CONTAINER="${CONTAINER_DIR}/IDBA-UD.sif"
ANVIO_CONTAINER="${CONTAINER_DIR}/anvio-8.sif"
METABAT2_CONTAINER="${CONTAINER_DIR}/metabat_latest.sif"
CHECKM_CONTAINER="${CONTAINER_DIR}/mags-practical-2024_v2_mod.sif"
CHECKM2_CONTAINER="${CONTAINER_DIR}/checkm2_1.0.2--pyh7cba7a3_0.sif"
GTDBTK_CONTAINER="${CONTAINER_DIR}/gtdbtk_latest.sif"

# Paths bind-mounted into every container. Add every filesystem that INPUT_DIR,
# the reference databases and the output directories live on.
SINGULARITY_BINDS="/project,/scratch"

# ------------------------------ Analysis knobs -------------------------------

# Minimum contig length kept by the assemblers / by anvi-script-reformat-fasta
MIN_CONTIG_LEN=1000

# MetaBAT2 --minContig (also used to name the bins/CheckM output directories)
BINNING_MIN_CONTIG=2500

# Bins below this CheckM2 completeness (%) are deleted; paths are appended to
# the run directory's lowqual_bins_removed.log first.
MIN_BIN_COMPLETENESS=70

# Bracken read length (-r) and taxonomic level (-l)
BRACKEN_READ_LEN=150
BRACKEN_LEVEL="S"

# Kraken2 confidence levels to sweep: "<value>:<output suffix>"
K2_CONFIDENCE_LEVELS=("0.2:conf02" "0.1:conf01" "0.0:conf0")

# ------------------------------ SLURM defaults -------------------------------
# The launcher passes these to sbatch on the command line, which overrides the
# #SBATCH directives baked into the job script.

SLURM_PARTITION="cpu"
SLURM_CPUS_PER_TASK=60
SLURM_MEM="120G"
# NOTE: 03:00:00 was the original limit. MEGAHIT + IDBA-UD + CheckM + CheckM2 +
# GTDB-Tk for one metagenome will normally exceed that; see docs/known_issues.md.
SLURM_TIME="24:00:00"
SLURM_QOS="normal"
SLURM_ACCOUNT="PROJECT_CODE"
SLURM_MAIL_USER="your.email@example.com"
# Max array tasks running at once (0 = no throttle). Useful because every task
# loads the full Kraken2 database into memory.
SLURM_MAX_CONCURRENT=0

# -Xmx passed to the JVM-based BBTools scripts. Keep below SLURM_MEM.
BBTOOLS_XMX="95g"

# Environment module providing `singularity` (or `apptainer`) on your cluster.
SINGULARITY_MODULE="singularity"
