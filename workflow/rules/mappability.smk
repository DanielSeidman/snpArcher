rule genmap:
    input:
        ref = "config/{ref_name}.fasta",
    output:
        bg = temp("results/{ref_name}/genmap/{ref_name}.genmap.bedgraph"),
        sorted_bg = "results/{ref_name}/genmap/sorted_mappability.bg"
    params:
        indir = os.path.join(workflow.default_remote_prefix, "results/{ref_name}/genmap_index"),
        outdir = os.path.join(workflow.default_remote_prefix, "results/{ref_name}/genmap"),
        kmer = config['mappability_k']
    log:
        "logs/{ref_name}/genmap/log.txt"
    benchmark:
        "benchmarks/{ref_name}/genmap/benchmark.txt"
    conda:
        "../envs/mappability.yml"
    resources:
        mem_mb = lambda wildcards, attempt: attempt * resources['genmap']['threads'] * 4000
    threads:
        resources['genmap']['threads'] 
    shell:
        # snakemake creates the output directory before the shell command, but genmap doesnt like this. so we remove the directory first.
        """
        rm -rf {params.indir} && genmap index -F {input.ref} -I {params.indir} &> {log}
        genmap map -K {params.kmer} -E 0 -I {params.indir} -O {params.outdir} -bg -T {threads} -v &> {log}
        sort -k1,1 -k2,2n {output.bg} > {output.sorted_bg} 2>> {log}
        """

rule mappability_bed:
    input:
        map = "results/{ref_name}/genmap/sorted_mappability.bg"
    output:
        callable_sites = "results/{ref_name}/callable_sites/{prefix}_callable_sites_map.bed" if config['cov_filter'] else "results/{ref_name}/{prefix}_callable_sites.bed",
        tmp_map = temp("results/{ref_name}/callable_sites/{prefix}_temp_map.bed")
    conda:
        "../envs/mappability.yml"
    benchmark:
        "benchmarks/{ref_name}/mapbed/{prefix}_benchmark.txt"
    resources:
        mem_mb = lambda wildcards, attempt: attempt * resources['callable_bed']['threads'] * 4000
    params:
        merge = config['mappability_merge'],
        mappability = config['mappability_min']
    shell:
        """
        awk 'BEGIN{{OFS="\\t";FS="\\t"}} {{ if($4>={params.mappability}) print $1,$2,$3 }}' {input.map} > {output.tmp_map}
        bedtools sort -i {output.tmp_map} | bedtools merge -d {params.merge} -i - > {output.callable_sites}
        """