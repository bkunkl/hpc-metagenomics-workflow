# Singularity container recipes

The `.sif` images themselves are **not** in this repository — they are several
GB each. This directory holds the recipes needed to rebuild them.

## Building

```bash
# On a machine where you have root or --fakeroot:
sudo singularity build bbtools.sif bbtools.def

# Or, without root, if your site allows it:
singularity build --fakeroot bbtools.sif bbtools.def
```

Then point `CONTAINER_DIR` in your config file at the directory holding the
built images.

## Confidence in each recipe

Every recipe states its provenance in its own header. Summary:

| Recipe | `.sif` it rebuilds | Version confidence |
|---|---|---|
| `checkm2.def` | `checkm2_1.0.2--pyh7cba7a3_0.sif` | **Confirmed** — filename is the exact Bioconda build string |
| `skewer.def` | `skewer_0.2.2.sif` | **Confirmed** — version in filename |
| `card_rgi.def` | `CARD_RGI-6.0.4.sif` | **Confirmed** — version in filename |
| `anvio-8.def` | `anvio-8.sif` | **Confirmed** — version in filename |
| `datascience_genomics.def` | `datascience_genomics.sif` | **Base confirmed** (`jupyter/datascience-notebook:2023-05-30`, from `singularity inspect`); bowtie2 / samtools / megahit versions are best-effort |
| `gtdbtk.def` | `gtdbtk_latest.sif` | **Best-effort, but constrained** — pinned to 2.4.0 because the reference data is GTDB R220 |
| `metabat2.def` | `metabat_latest.sif` | **Best-effort** — original was `:latest` |
| `kraken2_bracken.def` | `kraken2_v2.17.1_bracken_v3.1_vmtouch.sif` | **Best-effort** — Bracken 3.1 is from the filename, but no Kraken2 release is numbered 2.17.1 (see recipe header) |
| `bbtools.def` | `bbtools.sif` | **Best-effort** — no version anywhere in the filename |
| `idba_ud.def` | `IDBA-UD.sif` | **Best-effort** — no version in filename; 1.1.3 is the only modern release |
| `checkm.def` | `mags-practical-2024_v2_mod.sif` | **Approximation** — no inspect output, no original recipe; reconstructed from the one command invoked |

Every guessed pin carries an inline `# best-effort -- verify before rebuilding`
comment next to the value.

## Recovering the real versions

If the original `.sif` files are still on disk, each recipe header lists the
exact commands to extract the versions it guessed. The general form:

```bash
singularity inspect --deffile  original.sif   # original recipe, if it was kept
singularity inspect --labels   original.sif   # build metadata
singularity exec  original.sif <tool> --version
```

`checkm.def` (from `mags-practical-2024_v2_mod.sif`) is the one worth checking
first — it is a full reconstruction rather than a version guess.
