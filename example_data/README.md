# Example input layouts

The FASTQ files here are **empty placeholders**. The underlying wastewater
sequencing data is from unpublished research and cannot be redistributed yet; these
files exist only to document the expected naming conventions and to give
`bin/build_sample_manifest.sh` something to run against.

They are zero bytes, so `build_sample_manifest.sh` will correctly refuse to
build a manifest from them (it rejects empty read files). To see the sample-name
derivation working, put a byte in each:

```bash
for f in example_data/wgs_input/*.fastq; do echo > "$f"; done
bin/build_sample_manifest.sh /tmp/demo.config.sh
```

## `wgs_input/` — shotgun pipeline convention

```
wgs_input/
├── OWTS_01_R1_merged.fastq
├── OWTS_01_R2_merged.fastq
├── OWTS_02_R1_merged.fastq
├── OWTS_02_R2_merged.fastq
├── OWTS_03_R1_merged.fastq
└── OWTS_03_R2_merged.fastq
```

Derived samples: `OWTS_01`, `OWTS_02`, `OWTS_03`.

Matching config:

```bash
FASTQ_GLOB="*_R1_merged.fastq"
SAMPLE_NAME_MODE="strip_suffix"
R1_SUFFIX="_R1_merged.fastq"
R2_SUFFIX="_R2_merged.fastq"
```

The original script instead used `ls *.fastq | cut -d '_' -f-2 | uniq`, which
gives the same three names for *this* layout only. The equivalent legacy config:

```bash
SAMPLE_NAME_MODE="cut_fields"
SAMPLE_DELIM="_"
SAMPLE_NAME_FIELDS=2
```

## `rgi_input/` — resistance-gene pipeline convention

Four underscore-delimited fields before the read tag, and gzip-compressed:

```
rgi_input/
├── WW_inflow_rep1_L001_R1.fastq.gz
├── WW_inflow_rep1_L001_R2.fastq.gz
├── WW_inflow_rep2_L001_R1.fastq.gz
├── WW_inflow_rep2_L001_R2.fastq.gz
├── WW_outflow_rep1_L001_R1.fastq.gz
├── WW_outflow_rep1_L001_R2.fastq.gz
├── WW_outflow_rep2_L001_R1.fastq.gz
└── WW_outflow_rep2_L001_R2.fastq.gz
```

Derived samples: `WW_inflow_rep1_L001`, `WW_inflow_rep2_L001`,
`WW_outflow_rep1_L001`, `WW_outflow_rep2_L001`.

Matching config:

```bash
FASTQ_GLOB="*_R1.fastq.gz"
SAMPLE_NAME_MODE="strip_suffix"
R1_SUFFIX="_R1.fastq.gz"
R2_SUFFIX="_R2.fastq.gz"
```

Legacy equivalent of the original `cut -d '_' -f -4`:

```bash
SAMPLE_NAME_MODE="cut_fields"
SAMPLE_DELIM="_"
SAMPLE_NAME_FIELDS=4
```

## A convention neither mode assumes

`strip_suffix` handles naming schemes that field counting cannot, because it
never has to know how many underscores a sample name contains:

```
Site-A_2024-03-11_run7_S12_L002_R1_001.fastq.gz
→ sample "Site-A_2024-03-11_run7_S12_L002", with R1_SUFFIX="_R1_001.fastq.gz"
```

This is why it is the default.
