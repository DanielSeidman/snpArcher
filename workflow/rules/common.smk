import sys
import os
import tempfile
import random
import string
import statistics
import json
from pathlib import Path
from collections import defaultdict

import pandas as pd
import snparcher_utils
from yaml import safe_load
from pkg_resources import parse_version

# Can't be less than 7 cuz of min version in snakefile
SNAKEMAKE_VERSION = 8 if parse_version(snakemake.__version__) >= parse_version("8.0.0") else 7
logger.warning(f"snpArcher: Using Snakemake {snakemake.__version__}")
if SNAKEMAKE_VERSION >= 8:
    DEFAULT_STORAGE_PREFIX = StorageSettings.default_storage_prefix if StorageSettings.default_storage_prefix is not None else ""
else:
    DEFAULT_STORAGE_PREFIX = workflow.default_remote_prefix

samples = pd.read_table(config["samples"],sep=",",dtype=str).replace(' ','_',regex=True)
ref = config['ref_name']
with open(config["resource_config"],"r") as f:
    resources = safe_load(f)


def get_output():
    if config["final_prefix"] == "":
        raise (WorkflowError("'final_prefix' is not set in config."))
    out = []
    sample_names = samples['BioSample'].unique().tolist()

    #for ref in genomes:
    out.extend(expand("results/{ref_name}/gvcfs/{sample}.g.vcf.gz",ref_name=ref,sample=sample_names))
    #out.extend(expand("results/{ref_name}/summary_stats/{prefix}_bam_sumstats.txt", prefix=config['final_prefix']))
    #out.extend(expand("results/{ref_name}/{prefix}_callable_sites.bed", ref_name=ref, prefix=config['final_prefix']))#Do not want this in current version for anything

    #out.append(rules.qc_all.input)


    if config["generate_trackhub"]:
        if not config["trackhub_email"]:
            raise (
                WorkflowError(
                    "If generating trackhub, you must provide an email in the config file."
                )
            )
        out.append(rules.trackhub_all.input)
    return out


def merge_bams_input(wc):
    return expand(
        "results/{{ref_name}}/bams/preMerge/{{sample}}/{run}.bam",
        run=samples.loc[samples["BioSample"] == wc.sample]["Run"].tolist(),
    )

def setup_curlrc():
    curlrc_path = Path("~/.curlrc").expanduser()
    marker = "# Added by snpArcher"
    entry = f"-L {marker}\n"
    if curlrc_path.exists():
        with curlrc_path.open("r+") as f:
            if "-L" not in f.read():
                f.write(f"\n{entry}\n")
                logger.info(f"Added -L to {curlrc_path} for pyd4")
            
    else:
        with curlrc_path.open("a+") as f:
            f.write(f"{entry}\n")

def cleanup_curlrc():
    curlrc_path = Path("~/.curlrc").expanduser()
    marker = "# Added by snpArcher"
    entry = f"-L {marker}\n"
    logger.info(f"Removing -L we added from {curlrc_path}...")
    if curlrc_path.exists():
        with curlrc_path.open("r") as f:
            lines = f.readlines()
            # remove entry if its there
            new_lines = [line for line in lines if line.strip() != entry.strip()]
            if len(new_lines) == 0:
                # our entry was only thing there, we can delete .curlrc
                curlrc_path.unlink()
            else:
            # write back any options that were there.
                with curlrc_path.open("w") as f:
                    f.writelines(new_lines)

def get_ref(wildcards):
    
    if "ref_name" in samples.columns:
        _refs = (
            samples.loc[(samples["ref_name"] == wildcards.ref_name)]["ref_name"]
            .dropna()
            .unique()
            .tolist()
        )             
        if _refs:
            return _refs
    # if not user-specified ref_name, force MissingInputError in copy_ref with dummyfile, which allows download_ref to run b/c of ruleorder.
    logger.warning(f"snpArcher: ref_name specified in sample sheet header, but no path provided for ref_name '{wildcards.ref_name}'\n" + 
                    f"Will try to download '{wildcards.ref_name}' from NCBI. If this is a genome accession, you can ignore this warning.")
    return []

def get_bams(wc):
    out = {"bam": None, "bai": None}
    if config["mark_duplicates"]:
        out["bam"] = "results/{ref_name}/bams/{sample}_final.bam"
        out["bai"] = "results/{ref_name}/bams/{sample}_final.bam.bai"
        return out
    else:
        return dedup_input(wc)

def sentieon_combine_gvcf_cmd_line(wc):
    gvcfs = sentieon_combine_gvcf_input(wc)["gvcfs"]
    return " ".join(["-v " + gvcf for gvcf in gvcfs])


def get_interval_gvcfs(wc):
    checkpoint_output = checkpoints.create_gvcf_intervals.get(**wc).output[0]
    with checkpoint_output.open() as f:
        lines = [l.strip() for l in f.readlines()]
    list_files = [os.path.basename(x) for x in lines]
    list_numbers = [f.replace("-scattered.interval_list", "") for f in list_files]
    gvcfs = expand(
        "results/{{ref_name}}/interval_gvcfs/{{sample}}/{l}.raw.g.vcf.gz",
        l=list_numbers,
    )

    return gvcfs


def get_interval_gvcfs_idx(wc):
    tbis = [f + ".tbi" for f in get_interval_gvcfs(wc)]
    return tbis


def get_db_interval_count(wc):
    _samples = (
        samples.loc[(samples["ref_name"] == wc.ref_name)]["BioSample"]
        .unique()
        .tolist()
    )
    out = max(
        int((config["db_scatter_factor"]) * len(_samples) * config["num_gvcf_intervals"]),1)
    return out


def get_interval_vcfs(wc):
    checkpoint_output = checkpoints.create_db_intervals.get(**wc).output[0]
    with checkpoint_output.open() as f:
        lines = [l.strip() for l in f.readlines()]
    list_files = [os.path.basename(x) for x in lines]

    list_numbers = [f.replace("-scattered.interval_list", "") for f in list_files]
    vcfs = expand("results/{{ref_name}}/vcfs/intervals/filtered_L{l}.vcf.gz", l=list_numbers)

    return vcfs


def get_interval_vcfs_idx(wc):
    tbis = [f + ".tbi" for f in get_interval_vcfs(wc)]
    return tbis


def get_gvcfs_db(wc):
    _samples = samples.loc[(samples["ref_name"] == wc.ref_name)]["BioSample"].unique().tolist()
    gvcfs = expand("results/{{ref_name}}/gvcfs/{sample}.g.vcf.gz", sample=_samples)
    tbis = expand("results/{{ref_name}}/gvcfs/{sample}.g.vcf.gz.tbi", sample=_samples)
    return {"gvcfs": gvcfs, "tbis": tbis}


def dedup_input(wc):
    runs = samples.loc[samples["BioSample"] == wc.sample]["Run"].tolist()

    if len(runs) == 1:
        bam = expand("results/{{ref_name}}/bams/preMerge/{{sample}}/{run}.bam", run=runs)
        bai = expand("results/{{ref_name}}/bams/preMerge/{{sample}}/{run}.bam.bai", run=runs)
    else:
        bam = "results/{ref_name}/bams/postMerge/{sample}.bam"
        bai = "results/{ref_name}/bams/postMerge/{sample}.bam.bai"
    return {"bam": bam, "bai": bai}


def sentieon_combine_gvcf_input(wc):
    _samples = samples["BioSample"].unique().tolist()
    gvcfs = expand("results/{{ref_name}}/gvcfs/{sample}.g.vcf.gz", sample=_samples)
    tbis = expand("results/{{ref_name}}/gvcfs/{sample}.g.vcf.gz.tbi", sample=_samples)
    return {"gvcfs": gvcfs, "tbis": tbis}


#NOTE: This currently creates a trim_galore directory due to trim_galore's inability to produce it. This is bad coding
def get_reads(wc):
    """Returns local read files if present. Defaults to SRR if no local reads in sample sheet."""
    row = samples.loc[samples['Run'] == wc.run]
    print("test b"+wc.run)
    print("test b"+wc.sample)
    if 'fq1' in samples.columns and 'fq2' in samples.columns:
        if os.path.exists(row.fq1.item()) and os.path.exists(row.fq2.item()):
            r1dir = "results/"+config['ref_name']+"/data/fastq/"+wc.sample+"/"
            r1=r1dir+wc.run+"_1.fastq.gz"
            #f"results/{config['ref_name']}/data/fastq/{wc.sample}/"{wc.run}_1.fastq.gz"
            r2dir = "results/"+config['ref_name']+"/data/fastq/"+wc.sample+"/"
            r2=r2dir+wc.run+"_2.fastq.gz"
            if not os.path.exists(r1):
                if not os.path.isdir(os.path.dirname(r1dir)):
                    os.makedirs(os.path.dirname(r1dir))
                os.symlink(row.fq1.item(),r1)
            if not os.path.exists(r2):
                if not os.path.isdir(os.path.dirname(r2dir)):
                    os.makedirs(os.path.dirname(r2dir))
                os.symlink(row.fq2.item(),r2)
            #Makes trimgalore outer directory. Bad coding. TODO: move this if can figure out how
            if not os.path.exists("results/"+config['ref_name']+"/trimgalore_fastqs/"):
                if not os.path.isdir(os.path.dirname("results/"+config['ref_name']+"/trimgalore_fastqs/")):
                    os.makedirs(os.path.dirname("results/"+config['ref_name']+"/trimgalore_fastqs/"))

            return {"r1": r1, "r2": r2}
        else:
            print(row.fq1.item(),os.path.exists(row.fq1.item()))
            print(row.fq2.item(),os.path.exists(row.fq2.item()))
            raise WorkflowError(f"fq1 and fq2 specified for {wc.sample}, but files were not found.")
    else:
        raise WorkflowError(f"fq1 and fq2 required for {wc.sample}, but input.")

def get_remote_reads(wildcards):
    """Use this for reads on a different remote bucket than the default. For backwards compatibility."""
    # print(wildcards)
    row = samples.loc[samples["Run"] == wildcards.run]
    r1 = GS.remote(os.path.join(GS_READS_PREFIX, row.fq1.item()))
    r2 = GS.remote(os.path.join(GS_READS_PREFIX, row.fq2.item()))
    return {"r1": r1, "r2": r2}

def collect_fastp_stats_input(wc):
    return expand(
        "results/{{ref_name}}/summary_stats/{{sample}}/{run}.fastp.out",
        run=samples.loc[samples["BioSample"] == wc.sample]["Run"].tolist(),
    )


def get_read_group(wc):
    """Denote sample name and library_id in read group."""
    tokens=wc.run.split("_")
    ##libname = samples.loc[samples['Run'] == wc.run]["LibraryName"].tolist()[0]
    return r"'@RG\tID:{id_string}\tSM:{sm_string}\tLB:{lb_string}\tPL:ILLUMINA'".format(
        id_string="tokens[2]}_{tokens[3]",
        sm_string="tokens[0]",
        lb_string="tokens[1]"
    )

def get_input_sumstats(wildcards):
    _samples = samples.loc[(samples["ref_name"] == wildcards.ref_name)]["BioSample"].unique().tolist()
    aln = expand("results/{{ref_name}}/summary_stats/{sample}_AlnSumMets.txt", sample=_samples)
    cov = expand("results/{{ref_name}}/summary_stats/{sample}_coverage.txt", sample=_samples)
    fastp = expand("results/{{ref_name}}/summary_stats/{sample}_fastp.out", sample=_samples)
    insert = expand("results/{{ref_name}}/summary_stats/{sample}_insert_metrics.txt",sample=_samples)
    qd = expand("results/{{ref_name}}/summary_stats/{sample}_qd_metrics.txt", sample=_samples)
    mq = expand("results/{{ref_name}}/summary_stats/{sample}_mq_metrics.txt", sample=_samples)
    gc = expand("results/{{ref_name}}/summary_stats/{sample}_gc_metrics.txt", sample=_samples)
    gc_summary = expand("results/{{ref_name}}/summary_stats/{sample}_gc_summary.txt", sample=_samples)
    if config["sentieon"]:
        out = {
            "alnSumMetsFiles": aln,
            "fastpFiles": fastp,
            "coverageFiles": cov,
            "insert_files": insert,
            "qc_files": qd,
            "mq_files": mq,
            "gc_files": gc,
            "gc_summary": gc_summary,
        }
        return out
    else:
        out = {
            "alnSumMetsFiles": aln,
            "fastpFiles": fastp,
            "coverageFiles": cov,
        }
        return out


def get_input_for_mapfile(wildcards):
    sample_names = samples.loc[(samples["ref_name"] == wildcards.ref_name)]["BioSample"].unique().tolist()
    return expand("results/{{ref_name}}/gvcfs_norm/{sample}.g.vcf.gz", sample=sample_names)


def get_input_for_coverage(wildcards):
    # Gets the correct sample given the organism and reference genome for the bedgraph merge step
    _samples = samples.loc[(samples["ref_name"] == wildcards.ref_name)]["BioSample"].unique().tolist()
    
    d4files = expand("results/{{ref_name}}/callable_sites/{sample}.per-base.d4", sample=_samples)
    return {"d4files": d4files}


def get_input_covstats(wildcards):
    # Gets the correct sample given the organism and reference genome for the bedgraph merge step
    _samples = samples.loc[(samples["ref_name"] == wildcards.ref_name)]["BioSample"].unique().tolist()
    
    covstats = expand("results/{{ref_name}}/callable_sites/{sample}.mosdepth.summary.txt",sample=_samples)
    return {"covStatFiles": covstats}


def get_bedgraphs(wildcards):
    """Snakemake seems to struggle with unpack() and default_remote_prefix. So we have to do this one by one."""
    _samples = (
        samples.loc[
            (samples["Organism"] == wildcards.Organism)
            & (samples["ref_name"] == wildcards.ref_name)
        ]["BioSample"]
        .unique()
        .tolist()
    )
    bedgraphFiles = expand(
        config["output"]
        + "{{Organism}}/{{ref_name}}/"
        + config["bamDir"]
        + "preMerge/{sample}"
        + ".sorted.bg",
        sample=_samples,
    )
    return bedgraphFiles


def get_big_temp(wildcards):
    """Sets a temp dir for rules that need more temp space that is typical on some cluster environments. Defaults to system temp dir."""
    if config["bigtmp"]:
        if config["bigtmp"].endswith("/"):
            return (
                config["bigtmp"]
                + "".join(random.choices(string.ascii_uppercase, k=12))
                + "/"
            )
        else:
            return (
                config["bigtmp"]
                + "/"
                + "".join(random.choices(string.ascii_uppercase, k=12))
                + "/"
            )
    else:
        return tempfile.gettempdir()


def collectCovStats(covSumFiles):
    covStats = {}
    sampleCov = {}

    for fn in covSumFiles:
        f = open(fn, "r")
        for line in f:
            if "mean" in line:
                continue

            fields = line.split()
            chrom = fields[0]
            cov = float(fields[3])

            if chrom in sampleCov:
                sampleCov[chrom].append(cov)
            else:
                sampleCov[chrom] = [cov]

    for chr in sampleCov:
        mean_cov = statistics.mean(sampleCov[chr])
        try:
            std_cov = statistics.stdev(sampleCov[chr])
        except:
            std_cov = "NA"
        covStats[chr] = {"mean": mean_cov, "stdev": std_cov}

    return covStats


def collectFastpOutput(fastpFiles):
    FractionReadsPassFilter = defaultdict(float)
    NumReadsPassFilter = defaultdict(int)

    for fn in fastpFiles:
        sample = os.path.basename(fn)
        sample = sample.replace("_fastp.out", "")
        
        
        with open(fn, "r") as f:
            data = json.load(f)
        unfiltered = data["summary"]["before_filtering"]["total_reads"]
        pass_filter = data["summary"]["after_filtering"]["total_reads"]
        FractionReadsPassFilter[sample] = float(pass_filter / unfiltered)
        NumReadsPassFilter[sample] = pass_filter

    return (FractionReadsPassFilter, NumReadsPassFilter)


def collectAlnSumMets(alnSumMetsFiles):
    aln_metrics = defaultdict(dict)
    for fn in alnSumMetsFiles:
        sample = os.path.basename(fn)
        sample = sample.replace("_AlnSumMets.txt", "")
        with open(fn, "r") as f:
            lines = f.readlines()
            total_aligns = int(lines[0].split()[0])
            num_dups = int(lines[4].split()[0])
            num_mapped = int(lines[6].split()[0])
            percent_mapped = lines[7].split()[0].strip("%")
            percent_proper_paired = lines[14].split()[0].strip("%")

            percent_dups = num_dups / total_aligns if total_aligns != 0 else 0
            aln_metrics[sample]["Total alignments"] = total_aligns
            aln_metrics[sample]["Percent Mapped"] = percent_mapped
            aln_metrics[sample]["Num Duplicates"] = num_dups
            aln_metrics[sample]["Percent Properly Paired"] = percent_proper_paired

    return aln_metrics


def collectCoverageMetrics(coverageFiles):
    SeqDepths = defaultdict(float)
    CoveredBases = defaultdict(float)

    for fn in coverageFiles:
        # these files contain coverage data by scaffold; take weighted average
        sample = os.path.basename(fn)
        sample = sample.replace("_coverage.txt", "")
        numSites = []
        covbases = 0
        depths = []  # samtools coverage function prints depth per scaffold
        f = open(fn, "r")
        for line in f:
            if not line.startswith("#rname"):
                line = line.split()
                numSites.append(int(line[2]) - int(line[1]) + 1)
                depths.append(float(line[6]))
                covbases += float(line[4])
        f.close()
        total = sum(numSites)
        depthsMean = 0
        for i in range(len(depths)):
            depthsMean += depths[i] * numSites[i] / (total)
        SeqDepths[sample] = depthsMean
        CoveredBases[sample] = covbases
    return (SeqDepths, CoveredBases)


def collect_inserts(files):
    med_inserts = defaultdict(float)
    med_insert_std = defaultdict(float)

    for file in files:
        sample = os.path.basename(file)
        sample = sample.replace("_insert_metrics.txt", "")
        with open(file, "r") as f:
            for i, line in enumerate(f):
                if i == 2:
                    line = line.strip().split()
                    try:
                        med_inserts[sample] = line[0]
                        med_insert_std[sample] = line[1]
                    except IndexError:
                        continue

    return med_inserts, med_insert_std


def printBamSumStats(
    depths,
    covered_bases,
    aln_metrics,
    FractionReadsPassFilter,
    NumReadsPassFilter,
    out_file,
    med_insert_sizes=None,
    med_abs_insert_std=None,
):
    samples = depths.keys()
    if med_insert_sizes is None:
        with open(out_file, "w") as f:
            print(
                "Sample\tTotal_Reads\tPercent_mapped\tNum_duplicates\tPercent_properly_paired\tFraction_reads_pass_filter\tNumReadsPassingFilters",
                file=f,
            )
            for samp in samples:
                print(
                    samp,
                    "\t",
                    aln_metrics[samp]["Total alignments"],
                    "\t",
                    aln_metrics[samp]["Percent Mapped"],
                    "\t",
                    aln_metrics[samp]["Num Duplicates"],
                    "\t",
                    aln_metrics[samp]["Percent Properly Paired"],
                    "\t",
                    FractionReadsPassFilter[samp],
                    "\t",
                    NumReadsPassFilter[samp],
                    file=f,
                )
    else:
        with open(out_file, "w") as f:
            print(
                "Sample\tTotal_Reads\tPercent_mapped\tNum_duplicates\tPercent_properly_paired\tFraction_reads_pass_filter\tNumReadsPassingFilters\tMedianInsertSize\tMedianAbsDev_InsertSize",
                file=f,
            )
            for samp in samples:
                print(
                    samp,
                    "\t",
                    aln_metrics[samp]["Total alignments"],
                    "\t",
                    aln_metrics[samp]["Percent Mapped"],
                    "\t",
                    aln_metrics[samp]["Num Duplicates"],
                    "\t",
                    aln_metrics[samp]["Percent Properly Paired"],
                    "\t",
                    FractionReadsPassFilter[samp],
                    "\t",
                    NumReadsPassFilter[samp],
                    "\t",
                    med_insert_sizes[samp],
                    "\t",
                    med_abs_insert_std[samp],
                    file=f,
                )
