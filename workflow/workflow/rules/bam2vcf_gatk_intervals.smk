localrules: create_db_mapfile

rule bam2gvcf:
    """
    TODO
    """
    input:
        bam = "results/{ref_name}/bams/{sample}_final.bam",
        bai = "results/{ref_name}/bams/{sample}_final.bam.bai",
        l = "results/{ref_name}/intervals/gvcf_intervals/{l}-scattered.interval_list",
        ref= "config/{ref_name}.fasta",
        indexes=expand("config/{ref_name}.fasta.{ext}",ext=["sa", "pac", "bwt", "ann", "amb", "fai"]),
        dictf="config/{ref_name}.dict",
    output:
        gvcf = "results/{ref_name}/interval_gvcfs/{sample}/{l}.raw.g.vcf.gz",
        gvcf_idx = "results/{ref_name}/interval_gvcfs/{sample}/{l}.raw.g.vcf.gz.tbi"
    resources:
        #!The -Xmx value the tool is run with should be less than the total amount of physical memory available by at least a few GB
        # subtract that memory here
        mem_mb = lambda wildcards, attempt: attempt * resources['bam2gvcf']['threads'] * 4000,   # this is the overall memory requested
        reduced = lambda wildcards, attempt: attempt * (() - 3000)  # this is the maximum amount given to java
    log:
        "logs/{ref_name}/gatk_hc/{sample}/{l}.txt"
    benchmark:
        "benchmarks/{ref_name}/gatk_hc/{sample}_{l}.txt"
    params:

        minPrun = config['minP'],
        minDang = config['minD'],
        ploidy = config['ploidy'],
    conda:
        "../envs/bam2vcf.yml"
    shell:
        "gatk HaplotypeCaller "
        "--java-options \"-Xmx{resources.reduced}m\" "
        "-R {input.ref} "
        "-I {input.bam} "
        "-O {output.gvcf} "
        "-L {input.l} "
        "-ploidy {params.ploidy} "
        "--emit-ref-confidence GVCF --min-pruning {params.minPrun} --min-dangling-branch-length {params.minDang} &> {log}"

rule concat_gvcfs:
    input:
        gvcfs = get_interval_gvcfs,
        tbis = get_interval_gvcfs_idx
    output:
        gvcf = "results/{ref_name}/gvcfs/{sample}.g.vcf.gz",
        tbi = "results/{ref_name}/gvcfs/{sample}.g.vcf.gz.tbi"
    log:
        "logs/{ref_name}/concat_gvcfs/{sample}.txt"
    benchmark:
        "benchmarks/{ref_name}/concat_gvcfs/{sample}.txt"
    resources:
        mem_mb = lambda wildcards, attempt: attempt * resources['gatherVcfs']['threads'] * 4000,   # this is the overall memory requested
        tmpdir = get_big_temp
    conda:
        "../envs/bcftools.yml"
    shell:
        """
        bcftools concat -D -a -Ou {input.gvcfs} | bcftools sort -T {resources.tmpdir} -Oz -o {output.gvcf} -
        tabix -p vcf {output.gvcf}
        """

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

rule gvcf2DB:
    """
    todo
    """
    input:
        unpack(get_gvcfs_db),
        l = "results/{ref_name}/intervals/db_intervals/{l}-scattered.interval_list",
        db_mapfile = "results/{ref_name}/genomics_db_import/DB_mapfile.txt"
    output:
        db = temp(directory("results/{ref_name}/genomics_db_import/DB_L{l}")),
        tar = temp("results/{ref_name}/genomics_db_import/DB_L{l}.tar"),
    resources:
        mem_mb = lambda wildcards, attempt: attempt * resources['gvcf2DB']['threads'] * 4000,   # this is the overall memory requested
        reduced = lambda wildcards, attempt: int(attempt * resources['gvcf2DB']['threads'] * 4000 * 0.80) # this is the maximum amount given to java
    log:
        "logs/{ref_name}/gatk_db_import/{l}.txt"
    resources:
        tmpdir = get_big_temp
    benchmark:
        "benchmarks/{ref_name}/gatk_db_import/{l}.txt"
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
            --merge-input-intervals \
            -L {input.l} \
            --tmp-dir {resources.tmpdir} \
            --sample-name-map {input.db_mapfile} &> {log}
        
        tar --overwrite -cf {output.tar} {output.db}
        """

rule DB2vcf:
    """
    This rule uses the genomic databases from the previous step (gvcf2DB) to create VCF files, one per list file. Thus, lists
    are still scattered.
    """
    input:
        db = "results/{ref_name}/genomics_db_import/DB_L{l}.tar",
        ref =  "config/{ref_name}.fasta",
        dictf="config/{ref_name}.dict",
        fai="config/{ref_name}.fasta.fai",
    output:
        vcf = temp("results/{ref_name}/vcfs/intervals/L{l}.vcf.gz"),
        vcfidx = temp("results/{ref_name}/vcfs/intervals/L{l}.vcf.gz.tbi"),
    params:
        het = config['het_prior'],
        db = lambda wc, input: input.db[:-4],


    resources:
        mem_mb = lambda wildcards, attempt: attempt * resources['DB2vcf']['threads'] * 4000,   # this is the overall memory requested
        reduced = lambda wildcards, attempt: attempt * ((resources['DB2vcf']['threads'] * 4000) - 3000),  # this is the maximum amount given to java
        tmpdir = get_big_temp
    log:
        "logs/{ref_name}/gatk_genotype_gvcfs/{l}.txt"
    benchmark:
        "benchmarks/{ref_name}/gatk_genotype_gvcfs/{l}.txt"
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
        vcf = "results/{ref_name}/vcfs/intervals/L{l}.vcf.gz",
        vcfidx = "results/{ref_name}/vcfs/intervals/L{l}.vcf.gz.tbi",
        ref = "config/{ref_name}.fasta",
        fai = "config/{ref_name}.fasta.fai",
        dictf = "config/{ref_name}.dict",
    output:
        vcf = temp("results/{ref_name}/vcfs/intervals/filtered_L{l}.vcf.gz"),
        vcfidx = temp("results/{ref_name}/vcfs/intervals/filtered_L{l}.vcf.gz.tbi")
    conda:
        "../envs/bam2vcf.yml"
    resources:
        mem_mb = lambda wildcards, attempt: attempt * resources['filterVcfs']['threads'] * 4000   # this is the overall memory requested
    log:
        "logs/{ref_name}/gatk_filter/{l}.txt"
    benchmark:
        "benchmarks/{ref_name}/gatk_filter/{l}.txt"
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
        vcfs = get_interval_vcfs,
        tbis = get_interval_vcfs_idx
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
        tmpdir = get_big_temp
    shell:
        """
        bcftools concat -D -a -Ou {input.vcfs} 2> {log}| bcftools sort -T {resources.tmpdir} -Oz -o {output.vcfFinal} - 2>> {log}
        tabix -p vcf {output.vcfFinal} 2>> {log}
        """
