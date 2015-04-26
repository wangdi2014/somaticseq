#!/bin/bash

set -e

export PATH=/home/ltfang/shared_delta/data/published/SomaticSeq/somaticseq:/net/kodiak/volumes/lake/shared/opt/python3/bin:$PATH

hg_ref='/home/ltfang/references/human_g1k_v37_decoy.fasta'
cosmic='/home/ltfang/references/cosmic.b37.vcf'
dbsnp='/home/ltfang/references/dbsnp_138.b37.vcf'
gatk='/home/ltfang/apps/GenomeAnalysisTK-2014.4-2-g9ad6aa8/GenomeAnalysisTK.jar'
snpeff_dir='/home/ltfang/apps/SnpEff_20140522'

while getopts "o:M:V:J:S:D:g:c:d:s:G:T:N:C:R:" opt
do
    case $opt in
        o)
            out_dir=$OPTARG;;
	M)
	    mutect_vcf=$OPTARG;;
	V)
	    varscan_vcf=$OPTARG;;
	J)
	    jsm_vcf=$OPTARG;;
	S)
	    sniper_vcf=$OPTARG;;
	D)
	    vardict_vcf=$OPTARG;;
	g)
	    hg_ref=$OPTARG;;
	c)
	    cosmic=$OPTARG;;
	d)
	    dbsnp=$OPTARG;;
	s)
	    snpeff_dir=$OPTARG;;
	G)
	    gatk=$OPTARG;;
	T)
	    tbam=$OPTARG;;
	N)
	    nbam=$OPTARG;;
	C)
	    classifier=$OPTARG;;
	R)
	    predictor=$OPTARG;;
    esac
done


if ! [[ -d ${out_dir} ]];
then
    echo "Missing ${out_dir}."
    exit 1
fi


merged_dir=${out_dir}/Merge_MVJSD

if ! [[ -d ${merged_dir} ]];
then
    mkdir ${merged_dir}
fi


# Make sure those directories are there.
if ! [[ -e ${mutect_vcf} || -e ${varscan_vcf} || -e ${jsm_vcf} || -e ${sniper_vcf} || -e ${vardict_vcf} ]]
then
    echo "Missing some VCFs."
    exit 2
fi


#--- LOCATION OF PROGRAMS ------
snpEff_b37="    java -jar ${snpeff_dir}/snpEff.jar  GRCh37.75"
snpSift_dbsnp=" java -jar ${snpeff_dir}/SnpSift.jar annotate ${dbsnp}"
snpSift_cosmic="java -jar ${snpeff_dir}/SnpSift.jar annotate ${cosmic}"

#####     #####     #####     #####     #####     #####     #####     #####
# Merge the chromosome-by-chromosome vcf's into one vcf for each tool, and modify them as needed.

# 1) MuTect merge script is different from everything else because MuTect output "randomly" orders normal and tumor sample columns, I need to grab the "SM" in a bam file, and then figure out which one is normal and which one is tumor in the mutect vcf file.
modify_MuTect.py -type snp -nbam ${nbam} -tbam ${tbam} -infile ${mutect_vcf} -outfile ${merged_dir}/mutect.snp.vcf

# 2) Somatic Sniper:
modify_VJSD.py -method SomaticSniper -infile ${sniper_vcf}  -outfile ${merged_dir}/somaticsniper.vcf

# 3) JointSNVMix2:
modify_VJSD.py -method JointSNVMix2  -infile ${jsm_vcf}     -outfile ${merged_dir}/jsm.vcf

# 4) VarScan2:
modify_VJSD.py -method VarScan2      -infile ${varscan_vcf} -outfile ${merged_dir}/varscan2.snp.vcf

# 5) VarDict:
# VarDict puts SNP, INDEL, and other stuff in the same file. Here I'm going to separate them out. "snp." and "indel." will be added to the specified file name from the command line
modify_VJScustomD.py -method VarDict -infile ${vardict_vcf} -outfile ${merged_dir}/vardict.vcf -filter somatic


echo "java -jar ${gatk} -T CombineVariants -R ${hg_ref} -nt 12 --setKey null --variant ${merged_dir}/snp.vardict.vcf --variant ${merged_dir}/varscan2.snp.vcf --variant ${merged_dir}/somaticsniper.vcf --variant ${merged_dir}/mutect.snp.vcf --variant ${merged_dir}/jsm.vcf --out ${merged_dir}/CombineVariants_MVJSD.snp.vcf" > cmds

#####     #####     #####     #####     #####     #####     #####     #####
# Merge with GATK CombineVariants, and then annotate with dbsnp, cosmic, and functional
java -jar ${gatk} -T CombineVariants -R ${hg_ref} -nt 12 --setKey null --genotypemergeoption UNSORTED \
--variant ${merged_dir}/snp.vardict.vcf \
--variant ${merged_dir}/varscan2.snp.vcf \
--variant ${merged_dir}/somaticsniper.vcf \
--variant ${merged_dir}/mutect.snp.vcf \
--variant ${merged_dir}/jsm.vcf \
--out ${merged_dir}/CombineVariants_MVJSD.snp.vcf


${snpSift_dbsnp} ${merged_dir}/CombineVariants_MVJSD.snp.vcf > ${merged_dir}/dbsnp.CombineVariants_MVJSD.snp.vcf
${snpSift_cosmic} ${merged_dir}/dbsnp.CombineVariants_MVJSD.snp.vcf > ${merged_dir}/cosmic.dbsnp.CombineVariants_MVJSD.snp.vcf
${snpEff_b37} ${merged_dir}/cosmic.dbsnp.CombineVariants_MVJSD.snp.vcf > ${merged_dir}/EFF.cosmic.dbsnp.CombineVariants_MVJSD.snp.vcf

#####     #####     #####     #####     #####     #####     #####     #####
# Modify the Combined vcf.
# -mincaller 1 will output only calls that are called SOMATIC by at least one tool. If 0, it will also generate a bunch of REJECT, GERMLINE, and LOH calls, etc.
score_Somatic.Variants.py -tools CGA VarScan2 JointSNVMix2 SomaticSniper VarDict -infile ${merged_dir}/EFF.cosmic.dbsnp.CombineVariants_MVJSD.snp.vcf -mincaller 1 -outfile ${merged_dir}/BINA_somatic.snp.vcf


##
## Convert the sSNV file into TSV file, for machine learning data:
mkfifo ${merged_dir}/samN.vcf.fifo ${merged_dir}/samT.vcf.fifo ${merged_dir}/haploN.vcf.fifo ${merged_dir}/haploT.vcf.fifo

# Filter out INDEL
samtools mpileup -B -uf ${hg_ref} ${nbam} -l ${merged_dir}/BINA_somatic.snp.vcf | bcftools view -cg - | egrep -wv 'INDEL' > ${merged_dir}/samN.vcf.fifo &
samtools mpileup -B -uf ${hg_ref} ${tbam} -l ${merged_dir}/BINA_somatic.snp.vcf | bcftools view -cg - | egrep -wv 'INDEL' > ${merged_dir}/samT.vcf.fifo &

# SNV Only
java -Xms8g -Xmx8g -jar ${gatk} -T HaplotypeCaller --reference_sequence ${hg_ref} -L ${merged_dir}/BINA_somatic.snp.vcf --emitRefConfidence BP_RESOLUTION -I ${nbam} --out /dev/stdout \
| awk -F "\t" '$0 ~ /^#/ || ( $4 ~ /^[GCTA]$/ && $5 !~ /[GCTA][GCTA]/ )' > ${merged_dir}/haploN.vcf.fifo &

java -Xms8g -Xmx8g -jar ${gatk} -T HaplotypeCaller --reference_sequence ${hg_ref} -L ${merged_dir}/BINA_somatic.snp.vcf --emitRefConfidence BP_RESOLUTION -I ${tbam} --out /dev/stdout \
| awk -F "\t" '$0 ~ /^#/ || ( $4 ~ /^[GCTA]$/ && $5 !~ /[GCTA][GCTA]/ )' > ${merged_dir}/haploT.vcf.fifo &


SSeq_merged.vcf2tsv.py \
-fai ${hg_ref}.fai \
-myvcf ${merged_dir}/BINA_somatic.snp.vcf \
-varscan ${varscan_vcf} \
-jsm ${jsm_vcf} \
-sniper ${sniper_vcf} \
-vardict ${merged_dir}/snp.vardict.vcf \
-samT ${merged_dir}/samT.vcf.fifo \
-samN ${merged_dir}/samN.vcf.fifo \
-haploT ${merged_dir}/haploT.vcf.fifo \
-haploN ${merged_dir}/haploN.vcf.fifo \
-outfile ${merged_dir}/Ensemble.sSNV.tsv

rm ${merged_dir}/samN.vcf.fifo ${merged_dir}/samT.vcf.fifo ${merged_dir}/haploN.vcf.fifo ${merged_dir}/haploT.vcf.fifo



# If a classifier is used, use it:
if [[ -e ${classifier} ]]
then
    echo "Use $classifier to classify ${merged_dir}/Ensemble.sSNV.tsv into ${merged_dir}/Trained.sSNV.tsv" >> cmds
    R --no-save "--args $classifier ${merged_dir}/Ensemble.sSNV.tsv ${merged_dir}/Trained.sSNV.tsv" < $predictor
    SSeq_tsv2vcf.py -tsv ${merged_dir}/Trained.sSNV.tsv -vcf ${merged_dir}/Trained.sSNV.vcf -pass 0.7 -low 0.1 -all -phred
fi
