#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# submit_pipeline.sh -- the single supported way to launch either workflow.
#
#   Usage:
#     bin/submit_pipeline.sh <config.sh> <workflow.sbatch> [extra sbatch args...]
#     bin/submit_pipeline.sh --dry-run <config.sh> <workflow.sbatch>
#
#   Examples:
#     bin/submit_pipeline.sh config/wgs_pipeline.config.sh \
#                            workflows/metagenomics_wgs_pipeline.sbatch
#
#     bin/submit_pipeline.sh config/rgi_pipeline.config.sh \
#                            workflows/rgi_card_screening.sbatch --hold
#
# WHY A LAUNCHER EXISTS
# ---------------------
# #SBATCH directives are read by sbatch at submission time, from the top of the
# file, before a single line of the script body executes. A job script therefore
# cannot compute its own `--array` bound: by the time it could count the input
# files, the array has already been sized. The two ways out are (a) rewriting the
# #SBATCH line in place before every submission, or (b) passing --array on the
# sbatch command line, where it overrides the directive in the file. (b) keeps
# the job script immutable and version-controlled, so that is what this does.
#
# It also materialises the sample list into a manifest first, and hands that
# exact file to the job, so the array bound and the array tasks can never
# disagree. See bin/build_sample_manifest.sh.
# -----------------------------------------------------------------------------

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

dry_run=false
if [[ "${1:-}" == "--dry-run" || "${1:-}" == "-n" ]]; then
	dry_run=true
	shift
fi

[[ $# -ge 2 ]] || usage

config="$1"; shift
workflow="$1"; shift
extra_sbatch_args=("$@")

[[ -r "$config"   ]] || { echo "ERROR: cannot read config: $config" >&2; exit 1; }
[[ -r "$workflow" ]] || { echo "ERROR: cannot read workflow: $workflow" >&2; exit 1; }

config="$(readlink -f "$config")"
workflow="$(readlink -f "$workflow")"

# shellcheck disable=SC1090
source "$config"

: "${RUN_DIR:?RUN_DIR not set in $config}"

# ----------------------------- Build the manifest ----------------------------

run_id="$(date +%Y%m%dT%H%M%S)"
run_dir="${RUN_DIR}/$(basename "${workflow%.sbatch}")_${run_id}"
manifest="${run_dir}/samples.tsv"

mkdir -p "$run_dir"
"${repo_root}/bin/build_sample_manifest.sh" "$config" "$manifest"

n_samples="$(wc -l < "$manifest")"
if [[ "$n_samples" -lt 1 ]]; then
	echo "ERROR: manifest is empty: $manifest" >&2
	exit 1
fi

# Snapshot the config next to the manifest so the run is reproducible even if
# the config is edited afterwards.
cp "$config" "${run_dir}/config.snapshot.sh"

echo "Run directory : ${run_dir}"
echo "Manifest      : ${manifest} (${n_samples} sample(s))"
echo "Samples       :"
cut -f1 "$manifest" | sed 's/^/                /'

# ------------------------------ Assemble sbatch ------------------------------

array_spec="0-$((n_samples - 1))"
if [[ "${SLURM_MAX_CONCURRENT:-0}" -gt 0 ]]; then
	array_spec="${array_spec}%${SLURM_MAX_CONCURRENT}"
fi

sbatch_args=(
	"--array=${array_spec}"
	"--chdir=${run_dir}"
	"--output=${run_dir}/slurm-%A_%a.out"
	"--export=ALL,PIPELINE_CONFIG=${config},SAMPLE_MANIFEST=${manifest},RUN_OUTPUT_DIR=${run_dir}"
)

# Resource requests from the config override the #SBATCH defaults in the script.
[[ -n "${SLURM_PARTITION:-}"      ]] && sbatch_args+=("--partition=${SLURM_PARTITION}")
[[ -n "${SLURM_CPUS_PER_TASK:-}"  ]] && sbatch_args+=("--cpus-per-task=${SLURM_CPUS_PER_TASK}")
[[ -n "${SLURM_MEM:-}"            ]] && sbatch_args+=("--mem=${SLURM_MEM}")
[[ -n "${SLURM_MEM_PER_CPU:-}"    ]] && sbatch_args+=("--mem-per-cpu=${SLURM_MEM_PER_CPU}")
[[ -n "${SLURM_TIME:-}"           ]] && sbatch_args+=("--time=${SLURM_TIME}")
[[ -n "${SLURM_QOS:-}"            ]] && sbatch_args+=("--qos=${SLURM_QOS}")
[[ -n "${SLURM_ACCOUNT:-}"        ]] && sbatch_args+=("--account=${SLURM_ACCOUNT}")
[[ -n "${SLURM_MAIL_USER:-}"      ]] && sbatch_args+=("--mail-user=${SLURM_MAIL_USER}")

sbatch_args+=("${extra_sbatch_args[@]+"${extra_sbatch_args[@]}"}")

echo
echo "sbatch ${sbatch_args[*]} ${workflow}"

if $dry_run; then
	echo
	echo "--dry-run: nothing submitted."
	exit 0
fi

command -v sbatch >/dev/null 2>&1 || {
	echo "ERROR: sbatch not found -- are you on a login node?" >&2
	exit 1
}

sbatch "${sbatch_args[@]}" "$workflow"
