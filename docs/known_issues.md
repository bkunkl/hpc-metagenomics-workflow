# Issues found in the original scripts

Everything below was found by reading the two original `.sbatch` files. Each
entry says what the original did, why it is wrong, and what this repository does
about it. Nothing was changed silently.

Three categories:

- **Fixed** — unambiguous defect, corrected here, marked in the code.
- **Changed by design** — behaviour intentionally differs, because the task
  brief asked for it (configurable naming, computed array size).
- **Flagged, not fixed** — needs a decision or a value only you have; left as a
  clearly marked knob.

---

## Fixed

### F1 — `GTDBTk_classify_wf` used an undefined `$bins_path`

**Original** (`metagenomics_wgs_pipeline.sbatch`):

```bash
GTDBTk_classify_wf(){
    if [ "$(find ${bins_dir} -maxdepth 1 -name "*.fa" | wc -l)" -gt 0 ]; then
        s_name=$(cut -d '/' -f3 <<< $bins_path)
        contig_size=$(cut -d '/' -f4 <<< $bins_path | cut -d '-' -f2)
        bp=${bins_path#*/}
        s_path=${w_dir}/${bp}
        ...
        --prefix ${s}_${contig_size}_gtdbtk
```

`$bins_path` is never assigned anywhere in the script.

**Why it matters.** Under the original (no `set -u`) this does not error — it
expands to the empty string. So:

- `s_name`, `bp`, `s_path` are computed from nothing. They are also never used
  again, so on their own they are harmless dead code.
- `contig_size` is the damaging one. It is **not** declared `local` in
  `Binning_and_check`, so it is a global that `Binning_and_check` correctly set
  to `2500`. `GTDBTk_classify_wf` then overwrites it with the empty string
  before building `--prefix`. Every GTDB-Tk output is therefore named
  `<sample>__gtdbtk` — double underscore, missing the contig-size tag that
  distinguishes binning parameterisations. If you ever ran two contig sizes into
  the same tree, their GTDB-Tk outputs collide.

**Fix applied.** `gtdbtk_classify_wf` now takes `bins_dir` and `contig_size` as
explicit positional arguments, and the four `bins_path`-derived lines are gone.

**Recommended follow-up:** if you have existing GTDB-Tk output directories named
`*__gtdbtk*`, they were produced by the buggy path — the classifications are
still valid, only the naming lost the contig-size tag.

---

### F2 — GTDB-Tk was never told where its reference data is

**Original:**

```bash
CONTAINER_CALL="singularity exec -B /project/PROJECT_CODE,${bins_dir}:/data,${GTDBTk_path}:/refdata ${GTDBTk_CONTAINER}"
${CONTAINER_CALL} gtdbtk classify_wf --genome_dir $bins_dir ...
```

`gtdbtk` locates its reference data through the `GTDBTK_DATA_PATH` environment
variable. The script never sets it — not in the shell, not via
`SINGULARITYENV_*`, not via `--env`. The `:/refdata` bind makes the data
*visible* inside the container but does not make `gtdbtk` *look* there.

Two further problems in the same line:

- `${bins_dir}:/data` is bound but never referenced — `--genome_dir` is passed
  the host path, not `/data`.
- The bind list drops `/scratch`, which the rest of the pipeline uses.

**Why it matters.** Depending on the image, this either aborts at startup with
"GTDBTK_DATA_PATH is not set" or silently uses whatever reference release was
baked into `gtdbtk_latest.sif` — which may not be the R220 data the config
points at, producing taxonomy against the wrong GTDB release.

**Fix applied.** `SINGULARITYENV_GTDBTK_DATA_PATH="$GTDBTK_PATH"` is exported
for the call, the unused `/data` bind is dropped, and the reference directory is
bound at its own host path so `--mash_db` resolves.

**Verify after your next run:** `gtdbtk classify_wf` prints the reference
release it loaded near the top of its log. Confirm it says R220.

---

### F3 — bowtie2 index files were never deleted

**Original** (`Make_bams`):

```bash
rm -f "${assembler_out}/*.bt2"
```

The glob is inside double quotes, so the shell never expands it. `rm -f` gets
the literal string `…/*.bt2`, finds no such file, and — because of `-f` —
exits 0. The cleanup silently never happened.

**Why it matters.** A bowtie2 index of a metagenomic assembly is comparable in
size to the assembly. Two assemblers × every sample × every run, retained
indefinitely, is a quiet quota leak.

**Fix applied.** Unquoted glob against the actual index prefix, and `.bt2l`
(large-index) files are covered too:

```bash
rm -f "${idx}"*.bt2 "${idx}"*.bt2l
```

---

### F4 — the sample list was built from a glob that matched the pipeline's own output

**Original:**

```bash
mapfile -t OWTS_samples < <(ls --color=never *.fastq | cut -d '_' -f-2 | uniq)
```

The working directory is also where the pipeline writes `${s}_R1_bbduk.fastq`,
`${s}_R2_bbduk.fastq`, `${s}_decontam.1.fastq` and `${s}_decontam.2.fastq`.

**Why it matters.** On a clean directory this is fine. On a **re-run**, or on a
run where a previous array task got as far as trimming, the glob picks up those
intermediates, `cut -f-2` maps them onto sample-name-like strings, and the array
index → sample mapping shifts. Tasks then process the wrong sample, or a
non-existent one, with no error. This is the kind of bug that produces a
plausible-looking but wrong result table.

The RGI script has the same shape (`ls *.fastq.gz` alongside
`*_skewer-trimmed-*.fastq.gz` and `*_deduped_*.fastq.gz`) and the same exposure.

**Fix applied, three layers:**

1. `FASTQ_GLOB` defaults to the R1 suffix (`*_R1_merged.fastq`,
   `*_R1.fastq.gz`), so only real inputs match.
2. Intermediates are written to a per-sample directory under the run directory,
   never back into `INPUT_DIR`.
3. The sample list is materialised **once** into a manifest by the launcher, and
   array tasks read a line from it instead of re-globbing. See
   [`bin/build_sample_manifest.sh`](../bin/build_sample_manifest.sh).

---

### F5 — `xargs rm` fails the job when no bins are low quality

**Original:**

```bash
awk -F '\t' -v bd=$bins_dir 'NR>1 && $2 < 70 {print bd "/" $1 ".fa"}' $qt_path | \
tee -a ${log_path} | xargs rm
```

If every bin passes the 70% completeness threshold, `awk` emits nothing and
`xargs` still runs `rm` with no arguments: `rm: missing operand`, exit 1.

The original had no `set -e`, so this printed an error and carried on. Adding
`set -euo pipefail` (see F8) would have turned a *good* sample — one where all
bins passed QC — into a failed job.

**Fix applied.** `xargs -r rm -f` (`-r` = do nothing if input is empty).

---

### F6 — the completeness threshold assumed a fixed column number

**Original:** `$2 < 70` against CheckM2's `quality_report.tsv`.

Column 2 *is* `Completeness` in CheckM2 1.0.2. But nothing in the script checks
that, so a CheckM2 upgrade that inserts or reorders a column would start
thresholding on the wrong number — and, since the action is `rm`, would delete
the wrong bins.

**Fix applied.** The `awk` now reads the header row, finds the column named
`Completeness`, and aborts if it is not present. The threshold itself is
`MIN_BIN_COMPLETENESS` in the config.

**Note on the behaviour itself:** deleting bins is destructive and irreversible.
The paths are appended to `lowqual_bins_removed.log` first, but the sequences
are gone. Consider moving them to a `low_quality/` subdirectory instead — the
change is one line in `drop_low_quality_bins`.

---

### F7 — `w_dir` was derived by counting path components

**Original:**

```bash
w_dir=$(cut -d '/' -f-4 <<< "$assembler_out")
log_path="${w_dir}/lowqual_bins_removed.log"
```

This takes the first four `/`-separated components of the output path. It
happens to give `/project/PROJECT_CODE/OWTS` for the original layout, and something
useless for any other. Same pattern as the `cut -d '/' -f3` lines in F1.

**Fix applied.** The log goes to the run directory, which is passed in
explicitly as `RUN_OUTPUT_DIR`.

---

### F8 — no error handling at all

Neither script set `-e`, `-u` or `-o pipefail`, and neither checked whether any
step produced output.

**Why it matters.** In a linear pipeline where each stage consumes the previous
stage's files, an early failure does not stop the run — it cascades. If bbduk
runs out of heap, bowtie2 is handed a missing file, writes an empty decontam
FASTQ, MEGAHIT assembles nothing, and the job still exits 0. The failure only
surfaces when someone notices an empty results table.

Specifically, `cd /scratch/PROJECT_CODE/OWTS/working_fastqs` at the top of the original
was unchecked: if that path were unavailable, every subsequent relative-path
command would run in the submit directory.

**Fix applied.** Both scripts now use `set -euo pipefail`, plus explicit
existence/non-empty checks after decontamination, after skewer, and before
contig renaming. The manifest builder checks that both read files exist before
the job is even submitted.

---

### F9 — inconsistent bind mounts between containers

**Original:** the anvi'o, MetaBAT2, CheckM, CheckM2 and Bracken calls bound only
`/project`, while the working directory (and the decontaminated FASTQs) lived on
`/scratch`. The bbtools, genomics, Kraken2 and IDBA calls bound both.

It worked because Singularity binds the current working directory by default,
so `/scratch/...` was reachable anyway — but only by accident, and only as long
as the CWD stayed put. Any refactor that changed the working directory would
have broken half the containers.

**Fix applied.** A single `SINGULARITY_BINDS` list, plus the run directory,
applied to every container call.

---

### F10 — inconsistent renamed-contig filenames between the two assemblers

**Original** (`rename_contigs`): IDBA output was named `${sn}_contig.fa`
(singular) and MEGAHIT output `${sn}_contigs.fa` (plural). Harmless, but the two
branches then differ for no reason, and any downstream script globbing
`*_contigs.fa` silently skips the IDBA assemblies.

**Fix applied.** Both branches produce `<id>_contigs.fa`, in their own assembler
output directory, so there is no collision.

---

### F11 — MEGAHIT refuses to start if its output directory exists

MEGAHIT aborts with `ERROR: output directory ... already exists` rather than
overwriting. The original never cleared it, so any re-run of a sample failed at
the assembly step — and, per F8, kept going anyway.

**Fix applied.** `rm -rf "${assembler_out:?}/${SAMPLE}"` before invoking MEGAHIT.
(The `:?` guard is deliberate: it makes the `rm -rf` refuse to run if the
variable is ever empty.)

---

### F12 — `chmod -R 0777` on shared scratch

**Original** (`run_rgi_metagen_slurm_array.sbatch`):

```bash
CARD_temp=/scratch/PROJECT_CODE/wastewater/CARD_temp
...
chmod -R 0777 "$CARD_temp"
```

The comment says "This saved the day from rgi load errors", which is the right
diagnosis of the wrong problem: `rgi load` fails because it needs to write
inside its own read-only site-packages directory, not because of host
permissions. The bind-mount trick immediately below it is the actual fix.

`0777` recursively on a shared scratch directory means any user on the cluster
can modify this job's CARD database mid-run.

**Fix applied.** Per-task directory named with the array job ID, `chmod 0700`,
removed on exit via a `trap`.

---

### F13 — RGI errors were discarded

**Original:** `rgi bwt ... --clean > /dev/null 2>&1`

`rgi bwt` is verbose, so redirecting stdout is reasonable. Redirecting stderr to
`/dev/null` as well means a failed run is indistinguishable from a successful
one in the job log.

**Fix applied.** Output goes to a per-sample log file under the run directory.

---

## Changed by design

### D1 — sample naming is configurable

`cut -d '_' -f-2` (WGS) and `cut -d '_' -f -4` (RGI) hardcoded two different
dataset-specific conventions. Both are now driven by
`SAMPLE_NAME_MODE` / `R1_SUFFIX` / `SAMPLE_NAME_FIELDS` in the config, and
`cut_fields` mode reproduces the original behaviour exactly. See the README.

The `sn=$(cut -d '_' -f2 <<< "$s")` inside `rename_contigs` — the "sample
number" used as the contig prefix — is a third hardcoded convention, now
`SAMPLE_ID_FIELD` (default: use the whole sample name).

### D2 — the array size is computed at submission time

`#SBATCH --array=0-4` and `--array=0-5` were hand-edited per run. `#SBATCH`
directives are parsed before the script body executes, so the script cannot size
its own array. The launcher counts the manifest and passes `--array` on the
sbatch command line, where it overrides the directive. See the README.

### D3 — intermediates moved out of the input directory

See F4. Consequence: `INPUT_DIR` is now treated as read-only.

---

## Flagged, not fixed — decisions for you

### N1 — the walltime is almost certainly too short

`#SBATCH --time=03:00:00` for a task that runs MEGAHIT **and** IDBA-UD **and**
two rounds of read mapping **and** MetaBAT2 **and** CheckM1 **and** CheckM2
**and** GTDB-Tk **and** three Kraken2 + Bracken passes, on one wastewater
metagenome.

GTDB-Tk's pplacer step alone routinely runs over an hour; CheckM1's `lineage_wf`
with `--pplacer_threads 60` is memory-hungry rather than fast; IDBA-UD with
`--mink 24 --maxk 124 --step 10` is eleven assembly iterations.

If those 3-hour jobs were completing, it is worth checking *why* — most likely
some stage was failing early and silently (see F8).

The config ships `SLURM_TIME="24:00:00"` as a starting point. Calibrate it from
`sacct -j <jobid> --format=JobID,Elapsed,MaxRSS,State` on a real run.

### N2 — `--pplacer_threads` equal to `--threads` will exhaust memory

CheckM1's own documentation warns that pplacer's memory use scales with thread
count — roughly 40 GB at high thread counts. The original passes
`--pplacer_threads ${SLURM_CPUS_PER_TASK}`, i.e. 60, against a 120 GB
allocation. This is the single most likely cause of an OOM kill in this
pipeline.

**Recommendation:** make it a separate config knob and set it to ~8. Left as-is
here because changing it changes resource behaviour, and you may have empirical
evidence it works on your nodes.

### N3 — the two assemblers write to separate trees but share a run

MEGAHIT and IDBA-UD both run for every sample, sequentially, in one array task.
That doubles the walltime of every task and means a failure in the second
assembler wastes the first one's work.

**Alternative worth considering:** make the assembler a config choice
(`ASSEMBLERS=(megahit idba)`) and submit one array per assembler. Each task then
gets a realistic walltime, and a failure only costs one assembly. Not done here
because it changes the job topology, which is your call.

### N4 — `rgi load` runs once per array task

Each task re-imports the full CARD + WILDCARD reference data into its own
private database. That is correct — it is what makes the tasks independent — but
it is also a few minutes of identical work per sample.

**Alternative:** run `rgi load` once into a shared read-only directory in a
dependency job, then bind that read-only for every task. Worth doing if you
scale past a few dozen samples; not worth the complexity below that.

### N5 — Kraken2 memory versus array concurrency

Every concurrent array task memory-maps the full pluspf database (~70 GB). With
no `%` throttle on the array, enough simultaneous tasks will exhaust node
memory or thrash the shared filesystem.

`SLURM_MAX_CONCURRENT` exists in the config for this (`0` = no throttle, the
original behaviour). The `vmtouch` binary in the Kraken2 container is there for
the same reason — pre-loading the database into page cache before launching the
array.

### N6 — `--memory 0.95` in MEGAHIT is a fraction of *machine* memory

MEGAHIT's `--memory 0.95` is 95% of total system memory, not of the SLURM
allocation. On a shared node with a 120 GB cgroup limit and 1 TB of physical
RAM, MEGAHIT will happily try to use ~950 GB and get OOM-killed by the cgroup.

**Recommendation:** pass an absolute byte count derived from `--mem` instead
(MEGAHIT accepts values > 1 as bytes). Left unchanged because the right value
depends on whether your partition gives whole nodes.

### N7 — the CARD/WILDCARD filenames are version-pinned in the arguments

`rgi load` is passed `card_database_v4.0.0_all.fasta`,
`wildcard_database_v4.0.2.fasta`, etc. These filenames change with every CARD
release, so the script breaks on a database update.

Now driven by `CARD_VERSION` / `WILDCARD_VERSION` in the config, which makes the
coupling visible — but you still have to bump them by hand when you download new
reference data.

### N8 — CheckM1 and CheckM2 both run, on the same bins

Deliberate, as far as one can tell from the script, and defensible: CheckM1
places bins in a reference tree and uses lineage-specific marker sets, CheckM2
uses a machine-learning predictor trained to handle lineages with few reference
genomes. On wastewater — full of poorly represented organisms — they disagree,
and the disagreement is informative.

Only CheckM2's completeness is used for the bin-dropping filter. If that is
intentional, the README should say so; if CheckM1's output is only ever
inspected by eye, note that it roughly doubles the QC walltime.
