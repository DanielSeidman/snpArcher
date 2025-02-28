localrules: create_db_mapfile

rule bam2gvcf:
    """
    TODO
    """
    input:
        bam = "results/{ref_name}/bams/{sample}_final.bam",
        bai = "results/{ref_name}/bams/{sample}_final.bam.bai",
        ref = "config/{ref_name}.fasta",
        indexes = expand("config/{{ref_name}}.fasta.{ext}",ext=["sa", "pac", "bwt", "ann", "amb", "fai"]),
        dictf="config/{ref_name}.dict",
    output:
        gvcf = "results/{ref_name}/gvcfs/{sample}.g.vcf.gz",
        tbi = "results/{ref_name}/gvcfs/{sample}.g.vcf.gz.tbi"
    resources:
        #!The -Xmx value the tool is run with should be less than the total amount of physical memory available by at least a few GB
        # subtract that memory here
        mem_mb = lambda wildcards, attempt: attempt * resources['bam2gvcf']['threads'] * 4000,   # this is the overall memory requested
        reduced = lambda wildcards, attempt: attempt * (resources['bam2gvcf']['threads'] * 4000 - 3000)  # this is the maximum amount given to java
    log:
        "logs/{ref_name}/gatk_hc/{sample}.txt"
    benchmark:
        "benchmarks/{ref_name}/gatk_hc/{sample}.txt"
    params:
        minPrun=config['minP'],
        minDang=config['minD'],
        ploidy=config['ploidy'],

    conda:
        "../envs/bam2vcf.yml"
    shell:
        "gatk HaplotypeCaller "
        "--java-options \"-Xmx{resources.reduced}m\" " 
        "-R {input.ref} "
        "-I {input.bam} "
        "-O {output.gvcf} "
        "-ploidy {params.ploidy} "
        "--emit-ref-confidence GVCF --min-pruning {params.minPrun} --min-dangling-branch-length {params.minDang} &> {log}"

rule create_db_mapfile:
    """
    TODO
    """
    input:
        get_input_for_mapfile
    output:
        db_mapfile = "results/{ref_name}/genomics_db_import/DB_mapfile.txt"
    run:
        with open(output.db_mapfile, "w") as f:
            for file_path in input:
                sample_name = os.path.basename(file_path).replace(".g.vcf.gz", "")
                print(sample_name, file_path, sep="\t", file=f)

rule prepare_db_intervals:
    """GenomicsDBImport needs list of intervals to operate on so this rule writes that file"""
    input:
        fai = "config/{ref_name}.fasta.fai",
    output:
        intervals = "results/{ref_name}/genomics_db_import/db_intervals.list"
    run:
        with open(output.intervals, "w") as out:
            with open(input.fai, "r") as f:
                for line in f:
                    line = line.strip().split()
                    chrom, end = line[0], line[1]
                    print(f"{chrom}:1-{end}", file=out)

rule gvcf2DB:
    """
    todo
    """
    input:
        unpack(get_gvcfs_db),
        db_mapfile = "results/{ref_name}/genomics_db_import/DB_mapfile.txt",
        intervals = "results/{ref_name}/genomics_db_import/db_intervals.list"
    output:
        db = temp(directory("results/{ref_name}/genomics_db_import/DB")),
        tar = temp("results/{ref_name}/genomics_db_import/DB.tar"),
    resources:
        mem_mb = lambda wildcards, attempt: attempt * resources['gvcf2DB']['threads'] * 4000,   # this is the overall memory requested
        reduced = lambda wildcards, attempt: int(attempt * resources['gvcf2DB']['threads'] * 4000 * 0.80) # this is the maximum amount given to java
    log:
        "logs/{ref_name}/gatk_db_import.txt"
    benchmark:
        "benchmarks/{ref_name}/gatk_db_import.txt"
    conda:
        "../envs/bam2vcf.yml"
    shell:
        # NOTE: reader-threads > 1 useless if you specify multiple intervals
        # a forum suggested TILEDB_DISABLE_FILE_LOCKING=1 to remedy sluggish performance
        """
        export TILEDB_DISABLE_FILE_LOCKING=1
        gatk GenomicsDBImport \
            --java-options '-Xmx{resources.reduced}m -Xms{resources.reduced}m' \
            --genomicsdb-shared-posixfs-optimizations true \
            --batch-size 25 \
            --genomicsdb-workspace-path {output.db} \
            -L {input.intervals} \
            --merge-input-intervals \
            --tmp-dir {resources.tmpdir} \
            --sample-name-map {input.db_mapfile} &> {log}
        
        tar -cf {output.tar} {output.db}
        """

rule DB2vcf:
    """
    This rule uses the genomic databases from the previous step (gvcf2DB) to create VCF files, one per list file. Thus, lists
    are still scattered.
    """
    input:
        db = "results/{ref_name}/genomics_db_import/DB.tar",
        ref = "config/{ref_name}.fasta"
    output:
        vcf = temp("results/{ref_name}/vcfs/raw.vcf.gz"),
        vcfidx = temp("results/{ref_name}/vcfs/raw.vcf.gz.tbi"),
    params:
        het = config['het_prior'],
        db = lambda wc, input: input.db[:-4],
    resources:
        mem_mb = lambda wildcards, attempt: attempt * resources['DB2vcf']['threads'] * 4000,   # this is the overall memory requested
        reduced = lambda wildcards, attempt: attempt * (resources['DB2vcf']['threads'] * 4000 - 3000)  # this is the maximum amount given to java
    log:
        "logs/{ref_name}/gatk_genotype_gvcfs.txt"
    benchmark:
        "benchmarks/{ref_name}/gatk_genotype_gvcfs.txt"
    conda:
        "../envs/bam2vcf.yml"
    shell:
        """
        tar -xf {input.db}
        gatk GenotypeGVCFs \
            --java-options '-Xmx{resources.reduced}m -Xms{resources.reduced}m' \
            -R {input.ref} \
            --heterozygosity {params.het} \
            --genomicsdb-shared-posixfs-optimizations true \
            -V gendb://{params.db} \
            -O {output.vcf} \
            --tmp-dir {resources.tmpdir} &> {log}
        """

rule filterVcfs:
    """
    This rule filters all of the VCFs
    """
    input:
        vcf = "results/{ref_name}/vcfs/raw.vcf.gz",
        vcfidx = "results/{ref_name}/vcfs/raw.vcf.gz.tbi",
        ref = "config/{ref_name}.fasta"
    output:
        vcf = temp("results/{ref_name}/vcfs/filtered.vcf.gz"),
        vcfidx = temp("results/{ref_name}/vcfs/filtered.vcf.gz.tbi")
    conda:
        "../envs/bam2vcf.yml"
    resources:
        mem_mb = lambda wildcards, attempt: attempt * resources['filterVcfs']['threads'] * 4000   # this is the overall memory requested
    log:
        "logs/{ref_name}/gatk_filter.txt"
    benchmark:
        "benchmarks/{ref_name}/gatk_filter.txt"
    shell:
        "gatk VariantFiltration "
        "-R {input.ref} "
        "-V {input.vcf} "
        "--output {output.vcf} "
        "--filter-name \"RPRS_filter\" "
        "--filter-expression \"(vc.isSNP() && (vc.hasAttribute('ReadPosRankSum') && ReadPosRankSum < -8.0)) || ((vc.isIndel() || vc.isMixed()) && (vc.hasAttribute('ReadPosRankSum') && ReadPosRankSum < -20.0)) || (vc.hasAttribute('QD') && QD < 2.0)\" "
        "--filter-name \"FS_SOR_filter\" "
        "--filter-expression \"(vc.isSNP() && ((vc.hasAttribute('FS') && FS > 60.0) || (vc.hasAttribute('SOR') &&  SOR > 3.0))) || ((vc.isIndel() || vc.isMixed()) && ((vc.hasAttribute('FS') && FS > 200.0) || (vc.hasAttribute('SOR') &&  SOR > 10.0)))\" "
        "--filter-name \"MQ_filter\" "
        "--filter-expression \"vc.isSNP() && ((vc.hasAttribute('MQ') && MQ < 40.0) || (vc.hasAttribute('MQRankSum') && MQRankSum < -12.5))\" "
        "--filter-name \"QUAL_filter\" "
        "--filter-expression \"QUAL < 30.0\" "
        "--create-output-variant-index  "
        "--invalidate-previous-filters true &> {log}"

rule sort_gatherVcfs:
    input:
        vcf = "results/{ref_name}/vcfs/filtered.vcf.gz",
        vcfidx = "results/{ref_name}/vcfs/filtered.vcf.gz.tbi"
    output:
        vcfFinal = "results/{ref_name}/{prefix}_raw.vcf.gz",
        vcfFinalidx = "results/{ref_name}/{prefix}_raw.vcf.gz.tbi"
    conda:
        "../envs/bcftools.yml"
    log:
        "logs/{ref_name}/sort_gather_vcfs/{prefix}_log.txt"
    benchmark:
        "benchmarks/{ref_name}/sort_gather_vcfs/{prefix}_benchmark.txt"
    resources:
        mem_mb = lambda wildcards, attempt: attempt * resources['gatherVcfs']['threads'] * 4000,   # this is the overall memory requested
        reduced = lambda wildcards, attempt: attempt * (resources['gatherVcfs']['threads'] * 4000 - 2000)  # this is the maximum amount given to java
    shell:
        """
        bcftools sort -Oz -o {output.vcfFinal} {input.vcf} 2>> {log}
        tabix -p vcf {output.vcfFinal} 2>> {log}
        """