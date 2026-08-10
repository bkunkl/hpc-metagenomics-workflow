# External reference databases

None of these are bundled with this repository — together they are well over
100 GB, and several are versioned releases that you should download deliberately
rather than inherit from a git clone. Download them once to shared project
storage and point the config files at them.

| Database | Used by | Approx. size | Config variable |
|---|---|---|---|
| Kraken2 `pluspf` | WGS: `k2 classify`, `bracken` | ~70 GB | `K2_DB` |
| Decontamination bowtie2 index (GRCh38 + UniVec) | WGS: `bowtie2` | ~4 GB | `INDEX_PATH` |
| Illumina adapter FASTA | both | KB | `ILLUMINA_ADAPTORS`, `ADAPTORS_R1/R2` |
| CheckM2 DIAMOND DB (`uniref100.KO.1.dmnd`) | WGS: `checkm2 predict` | ~3 GB | `DMNDDB_PATH` |
| CheckM1 reference data | WGS: `checkm lineage_wf` | ~1.4 GB | baked into the container (see `checkm.def`) |
| GTDB-Tk reference data (R220) | WGS: `gtdbtk classify_wf` | ~110 GB | `GTDBTK_PATH` |
| GTDB-Tk Mash sketch DB | WGS: `gtdbtk --mash_db` | ~1 GB | `MASH_DB` |
| CARD + WILDCARD | RGI: `rgi load`, `rgi bwt` | ~2 GB | `CARD_REFDAT` |

---

## Kraken2 / Bracken — `pluspf`

Pre-built indexes are published by the Kraken2 authors at
<https://benlangmead.github.io/aws-indexes/k2>. `pluspf` = RefSeq archaea,
bacteria, viral, plasmid, human, UniVec_Core, **p**rotozoa and **f**ungi — the
right choice for wastewater, where eukaryotic contamination is expected.

```bash
mkdir -p k2_pluspf && cd k2_pluspf
wget https://genome-idx.s3.amazonaws.com/kraken/k2_pluspf_YYYYMMDD.tar.gz
tar xzf k2_pluspf_YYYYMMDD.tar.gz
```

Bracken needs the `databaseNNNmers.kmer_distrib` files, which ship inside the
same tarball. Check that the read length in the file names matches
`BRACKEN_READ_LEN` (150 by default); if not, rebuild with `bracken-build -l 150`.

**Record the date stamp of the release you used** — Kraken2 results are not
comparable across database versions.

## Decontamination index

A bowtie2 index over the human reference plus vector/adapter sequence. Build it
once:

```bash
# GRCh38, no-alt analysis set
wget https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/000/001/405/GCA_000001405.15_GRCh38/seqs_for_alignment_pipelines.ucsc_ids/GCA_000001405.15_GRCh38_no_alt_analysis_set.fna.gz
# UniVec_Core (vector, adapter, linker and primer sequence)
wget https://ftp.ncbi.nlm.nih.gov/pub/UniVec/UniVec_Core

zcat GCA_000001405.15_GRCh38_no_alt_analysis_set.fna.gz > GRCh38_UniVec.fa
cat UniVec_Core >> GRCh38_UniVec.fa

bowtie2-build --threads 32 GRCh38_UniVec.fa GRCh38_UniVec.index
```

`INDEX_PATH` is the index **prefix**, not a file.

## CheckM2 DIAMOND database

```bash
checkm2 database --download --path /path/to/databases
```

This fetches `uniref100.KO.1.dmnd`. Point `DMNDDB_PATH` at the `.dmnd` file
itself.

## CheckM1 reference data

Distributed separately from the CheckM code:

```bash
wget https://data.ace.uq.edu.au/public/CheckM_databases/checkm_data_2015_01_16.tar.gz
mkdir checkm_data && tar xzf checkm_data_2015_01_16.tar.gz -C checkm_data
checkm data setRoot checkm_data
```

`build_singularity_containers/checkm.def` currently bakes this into the image.
If you would rather bind-mount it, delete that block from the recipe and export
`CHECKM_DATA_PATH` in the job script instead. See the recipe header — this is
one of the details that may differ from the original course-derived image.

## GTDB-Tk reference data

The largest single download here. The release **must** match the GTDB-Tk version
in the container (see `gtdbtk.def`):

```bash
wget https://data.gtdb.ecogenomic.org/releases/release220/220.0/auxillary_files/gtdbtk_package/full_package/gtdbtk_r220_data.tar.gz
tar xzf gtdbtk_r220_data.tar.gz     # -> release220/
```

Set `GTDBTK_PATH` to the `release220` directory. The job script exports it as
`GTDBTK_DATA_PATH` into the container — the original never did, which is
[known issue F2](known_issues.md#f2--gtdb-tk-was-never-told-where-its-reference-data-is).

### Mash sketch database

`gtdbtk classify_wf --mash_db` uses Mash for an ANI pre-screen, which cuts the
number of genomes that reach the expensive pplacer step. The sketch is built
once, on first use, if the path does not exist:

```bash
mkdir -p "${GTDBTK_PATH}/mash_db"
# GTDB-Tk writes ${MASH_DB}/gtdb_mash_db.msh on the first run that uses it
```

Build it in a single serial run before launching an array — otherwise every
concurrent task will try to build the same sketch at the same time.

## CARD and WILDCARD

Both come from <https://card.mcmaster.ca/download>. WILDCARD (predicted
resistance variants from public sequence data) is a separate download from the
curated CARD models.

```bash
mkdir -p CARD_refdat && cd CARD_refdat

# Curated CARD
wget https://card.mcmaster.ca/latest/data -O card-data.tar.bz2
tar xjf card-data.tar.bz2                      # -> card.json, ...

# WILDCARD
wget https://card.mcmaster.ca/latest/variants -O wildcard_data.tar.bz2
mkdir -p wildcard && tar xjf wildcard_data.tar.bz2 -C wildcard

# Build the annotation FASTAs that `rgi load` expects
rgi card_annotation      -i card.json > card_annotation.log 2>&1
rgi wildcard_annotation  -i wildcard --card_json card.json \
                         -v <WILDCARD_VERSION> > wildcard_annotation.log 2>&1
```

Those two `rgi *_annotation` commands are what produce
`card_database_v4.0.0.fasta`, `card_database_v4.0.0_all.fasta`,
`wildcard_database_v4.0.2.fasta` and `wildcard_database_v4.0.2_all.fasta` — the
exact filenames `rgi load` is given. Set `CARD_VERSION` and `WILDCARD_VERSION`
in `config/rgi_pipeline.config.sh` to match whatever you downloaded; they are
not the same number, and they change independently.

The k-mer files (`all_amr_61mers.txt`, `61_kmer_db.json`) ship inside the
WILDCARD tarball.

---

## Reproducibility note

For anything you intend to publish, record for each database: the release
identifier or date stamp, the download URL, and the download date. Kraken2
`pluspf`, GTDB, and CARD all revise their content substantially between
releases, and results are not comparable across them.
