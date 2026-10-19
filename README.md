Contact: Carsyn Bonesteel carsynbo@buffalo.edu cbonesteel23@gmail.com

Usage: sbatch parent.slurm input_gene2CN.env

Description:
Gene2CN Copy Number Pipeline
High-throughput pipeline for estimating gene copy number from short-read sequencing data using k-mer counting and normalization.
The pipeline is designed for large batch processing on the UB CCR cluster using Slurm scheduling and Globus file transfers.
It automates: FASTQ download, job scheduling, gene2CN computation, results organization, copy number summarization

Pipeline overview: 
The pipeline consists of five components: input → parent → transfer → compute → summarize

Workflow:

joblist.tsv
      │
      ▼
parent.slurm
(submits transfer jobs)
      │
      ▼
transfer.slurm
(downloads FASTQs via Globus)
      │
      ▼
compute.slurm
(runs gene2CN copy number analysis)
(removes FASTQ files)
      │
      ▼
results/
      │
      ▼
summarize_results.sh
(generates combined CN table)

Requirements:
The pipeline expects the following software to be available:

Software	Purpose
Bash		pipeline scripting
Slurm		job scheduling
Globus CLI	FASTQ transfers
gene2CN		copy number estimation
awk			parsing results
seqtk		FASTQ preprocessing
Python		k-mer utilities

This can be accomplished with 1 or 2 condo environments

Directory Structure:
gene2CN_pipeline/

├── paths/
│   └── {pop}_{sample}_paths.tsv
│   ...
│   └── joblist.tsv
│
├── metadata.txt
├── input_gene2cn.env
├── parent.slurm
├── transfer.slurm
├── compute.slurm
├── summarize_results.sh
│
├── results/
│   └── pop1/
│   	└── counter_errors/
│   		└── {sample}_counter_errors.txt
│   	└── counts/
│   		└── {kmer_db}_{sample}_counts.txt
│   	└── plots/
│   		└── Flanking_{sample}_plot.png
│   		└── {gene1}_{sample}_plot.png
│   		└── {gene2}_{sample}_plot.png
│   		...
│   		└── {geneN}_{sample}_plot.png
│   	└── {sample}_cn.txt
│   	└── {sample}.done
│   └── pop2/
│ 	...
│   └── popN/
│   └── combined_copy_numbers.tsv
│
├── logs/
│   └── gene2CN_parent_{slurm_ID}.out
│   └── gene2CN_parent_{slurm_ID}.err
│   └── xfer_gene2cn-{slurm_ID}_{pop}_{sample}.out
│   └── xfer_gene2cn-{slurm_ID}_{pop}_{sample}.err
│	...
│   └── g2cn_compute_{slurm_ID}_{pop}_{sample}.out
│   └── g2cn_compute_{slurm_ID}_{pop}_{sample}.err
│	...
│
└── README.md

Metadata file:
I have provided two sample metadata files
The pipeline should be able to accomidate almost any type of metadata file, but it requires the following columns: 
Sample_name	Pop_code	ftp_files

Parent Script: Main pipeline controller.
Responsibilities:
	reads the sample list
	submits transfer jobs
	enforces submission limits
	tracks job progress
	logs pipeline status
The script runs in two phases:
	Phase 1 — Initial submission burst
		Submits the first set of transfer jobs to populate the queue.
	Phase 2 — Steady-state scheduling
		Submits additional jobs as earlier transfers complete.

Transfer Script:Responsible for data staging.
Steps:
	download FASTQ files using Globus
	stage files in CCR scratch storage
	submit compute job

Compute Script: Runs the gene2CN analysis.
Runs GeneToCN tool on sample
Deletes sample files from scratch

Summarize Resuls Script: Runs independently after the pipeline is complete
Aggregates all _cn.txt files into one output file: results/combined_copy_numbers.tsv
Format:
sample_id    pop    gene1    gene2 ... geneN

Running the pipeline TO DO:
0. make sure to allocate space on vscratch (~1 TB)
1. update values in input file
2. update clusters & times for each script
	- consider running parent on omer node
	- update your email if you want a notification when the pipeline (almost) finishes
	- how long do your samples take to transfer? default = 1 hour
	- how long does your geneToCN script take? default = 3 hours
3. run the parent script
sbatch gene2cn_parent.slurm input_gene2cn.env
4. wait for the pipeline to run
5. run the summary script when pipeline completely finishes
bash summarize_results.sh
