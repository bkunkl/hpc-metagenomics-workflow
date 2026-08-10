#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Configuration for workflows/rgi_card_screening.sbatch
#
# Sourced by BOTH bin/submit_pipeline.sh and the job script, so the sample list
# used to size the SLURM array is the same list the array tasks index into.
# -----------------------------------------------------------------------------

# ------------------------------ Input handling -------------------------------

INPUT_DIR="/path/to/wastewater"

# One match per sample. The original script globbed "*.fastq.gz", which also
# matched its own intermediate outputs (*_skewer-trimmed-*, *_deduped_*) on any
# re-run; anchoring on the R1 suffix avoids that.
FASTQ_GLOB="*_R1.fastq.gz"

# strip_suffix (recommended) | cut_fields  -- see config/wgs_pipeline.config.sh
SAMPLE_NAME_MODE="strip_suffix"

R1_SUFFIX="_R1.fastq.gz"
R2_SUFFIX="_R2.fastq.gz"

# Only used when SAMPLE_NAME_MODE="cut_fields". The original script used
# `cut -d '_' -f -4`, i.e. delimiter "_" and 4 fields.
SAMPLE_DELIM="_"
SAMPLE_NAME_FIELDS=4

# ------------------------------ Reference data -------------------------------
# See docs/databases.md.

# Skewer takes separate R1/R2 adapter files
ADAPTORS_R1="/path/to/databases/Illumina_adaptors_R1.fasta"
ADAPTORS_R2="/path/to/databases/Illumina_adaptors_R2.fasta"

# Unpacked CARD + WILDCARD reference data directory
CARD_REFDAT="/path/to/databases/CARD_refdat"

# CARD / WILDCARD version strings, used to build the filenames passed to
# `rgi load`. Bump these when you download a newer CARD release.
CARD_VERSION="v4.0.0"
WILDCARD_VERSION="v4.0.2"
KMER_SIZE=61

# ------------------------------ Output layout --------------------------------

OUT_RGI="/path/to/project/RGI_results"

# Scratch space for the per-sample writable CARD database. RGI writes its loaded
# database inside its own installation prefix, so each array task gets a private
# copy bind-mounted over that path (see RGI_DB_PREFIX below).
CARD_TEMP="/path/to/scratch/CARD_temp"

RUN_DIR="/path/to/project/runs"

# ------------------------------ Containers -----------------------------------

CONTAINER_DIR="/path/to/containers"

SKEWER_CONTAINER="${CONTAINER_DIR}/skewer_0.2.2.sif"
BBTOOLS_CONTAINER="${CONTAINER_DIR}/bbtools.sif"
RGI_CONTAINER="${CONTAINER_DIR}/CARD_RGI-6.0.4.sif"

SINGULARITY_BINDS="/project,/scratch"

# Path INSIDE the RGI container where `rgi load` writes its _db/_data
# directories. This must match the container recipe
# (build_singularity_containers/card_rgi.def) -- if you rebuild RGI against a
# different Python version, update this string.
RGI_DB_PREFIX="/opt/miniforge3/envs/rgi/lib/python3.12/site-packages/app"

# ------------------------------ Analysis knobs -------------------------------

# skewer quality trimming
SKEWER_MEAN_QUALITY=20   # -Q
SKEWER_END_QUALITY=20    # -q
SKEWER_MIN_LENGTH=35     # -l
SKEWER_MAX_ERROR_RATE=0.05   # -r
SKEWER_MAX_INDEL_RATE=0.015  # -d

BBTOOLS_ZIPLEVEL=7
BBTOOLS_XMX="55g"

# Run `rgi bwt` against the curated CARD models, the WILDCARD models, or both.
RUN_BWT_CARD=true
RUN_BWT_WILDCARD=true

# Keep the trimmed/deduplicated FASTQs after RGI finishes (they are deleted by
# default to save scratch quota).
KEEP_INTERMEDIATE_FASTQ=false

# ------------------------------ SLURM defaults -------------------------------

SLURM_PARTITION="cpu"
SLURM_CPUS_PER_TASK=20
SLURM_MEM_PER_CPU="2000"
SLURM_TIME="01:30:00"
SLURM_QOS="normal"
SLURM_ACCOUNT="PROJECT_CODE"
SLURM_MAIL_USER="your.email@example.com"
SLURM_MAX_CONCURRENT=0

# Environment module providing `singularity` (or `apptainer`) on your cluster.
SINGULARITY_MODULE="singularity"
