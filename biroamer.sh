#!/bin/bash
set -eo pipefail

export LANG=C.UTF-8

# Get the script directory
DIR="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
OMIT_COMMAND="python3 $DIR/omit.py"
FASTALIGN=$DIR/fast_align/build/fast_align
ATOOLS=$DIR/fast_align/build/atools
TMXT="python3 $DIR/tmxt/tmxt.py"
NER="python3 $DIR/biner.py"
BUILDTMX="python3 $DIR/buildtmx.py"

JOBS=$(getconf _NPROCESSORS_ONLN)
BLOCKSIZE=100000
SEED=$RANDOM

TOKL1="python3 $DIR/toktok.py"
TOKL2="python3 $DIR/toktok.py"

get_seeded_random()
{
    seed="$1"
    openssl enc -aes-256-ctr -pass pass:"$seed" -nosalt \
        </dev/zero 2>/dev/null
}

usage () {
    echo "Usage: `basename $0` [options] <lang1> <lang2>"
    echo "Options:"
    echo "    -s SEED           Set random seed for reproducibility"
    echo "    -a ALIGN_CORPUS   Extra corpus to improve alignment"
    echo "                      It won't be included in the output"
    echo "    -j JOBS           Number of jobs to run in parallel"
    echo "    -b BLOCKSIZE      Number of lines for each job to be processed"
    echo "    -g                Keep original order of sentences, i.e. do not shuffle (e.g. when script is in extended modus and should only be run for anonymizing entities)"
    echo "    -m MIX_CORPUS     A corpus to mix with"
    echo "    -o                Enable random omitting of sentences"
    echo "    -p PATH           Set path for temporary directory"
    echo "    -t TOKL1          External tokenizer command for lang1"
    echo "    -T TOKL2          External tokenizer command for lang2"
    echo "    -y                Replace entities by placeholders instead of surrounding them by <hi>...</hi> tags"
    echo "    -h                Shows this message"
}

# Read optional arguments
while getopts ":s:a:j:b:gm:op:t:T:yh" options
do
    case "${options}" in
        s) SEED=$OPTARG;;
        a) ALIGN_CORPUS=$OPTARG;;
        j) JOBS=$OPTARG;;
        b) BLOCKSIZE=$OPTARG;;
        g) NOSHUFFLE=true;;
        m) MIX_CORPUS=$OPTARG;;
        o) OMIT=true;;
        p) SPECTEMPDIR=$OPTARG;;
        t) TOKL1=$OPTARG;;
        T) TOKL2=$OPTARG;;
        y) PLACEHOLDER=true;;
        h) usage
            exit 0;;
        \?) usage 1>&2
            exit 1;;
    esac
done
if [ "$OMIT" == true ]; then
    OMIT_COMMAND="$OMIT_COMMAND -s $SEED"
else
    OMIT_COMMAND=cat
fi

# Read mandatory arguments
L1=${@:$OPTIND:1}
L2=${@:$OPTIND+1:1}
if [ -z "$L1" ] || [ -z "$2" ]
then
    echo "Error: <lang1> and <lang2> are mandatory" 1>&2
    echo "" 1>&2
    usage 1>&2
    exit 1
fi

if [ -z $SPECTEMPDIR ]
then MYTEMPDIR=$(mktemp -d)
else MYTEMPDIR=$SPECTEMPDIR
     mkdir -p $MYTEMPDIR
fi
echo "Using temporary directory $MYTEMPDIR" 1>&2

# Extract from TMX, omit, mix and shuffle
cat /dev/stdin \
    | $TMXT --codelist $L1,$L2 \
    | $OMIT_COMMAND \
    | cat - $MIX_CORPUS \
    | if [ "$NOSHUFFLE" == true ]; then cat; else shuf --random-source=<(get_seeded_random $SEED); fi \
    >$MYTEMPDIR/omitted-mixed

# Append corpus to improve alignment
if [ ! -z $ALIGN_CORPUS ]
then
    CAT="tail -$(cat $MYTEMPDIR/omitted-mixed | wc -l)"
    cat $ALIGN_CORPUS $MYTEMPDIR/omitted-mixed >$MYTEMPDIR/add-corpus
    mv $MYTEMPDIR/add-corpus $MYTEMPDIR/omitted-mixed
else
    CAT=cat
fi

# ANONYMIZE

# Tokenize
cut -f1 $MYTEMPDIR/omitted-mixed \
    | parallel -j$JOBS -k -l $BLOCKSIZE --pipe $TOKL1 \
    >$MYTEMPDIR/f1.tok.origcase
awk '{print tolower($0)}' >$MYTEMPDIR/f1.tok.origcase >$MYTEMPDIR/f1.tok
cut -f2 $MYTEMPDIR/omitted-mixed \
    | parallel -j$JOBS -k -l $BLOCKSIZE --pipe $TOKL2 \
    >$MYTEMPDIR/f2.tok.origcase
awk '{print tolower($0)}' >$MYTEMPDIR/f2.tok.origcase >$MYTEMPDIR/f2.tok

paste $MYTEMPDIR/f1.tok $MYTEMPDIR/f2.tok | sed 's%'$'\t''% ||| %g' >$MYTEMPDIR/fainput

# Word-alignments
export OMP_NUM_THREADS=$JOBS
$FASTALIGN -i $MYTEMPDIR/fainput -I 6 -d -o -v >$MYTEMPDIR/forward.align
$FASTALIGN -i $MYTEMPDIR/fainput -I 6 -d -o -v -r >$MYTEMPDIR/reverse.align
$ATOOLS -i $MYTEMPDIR/forward.align -j $MYTEMPDIR/reverse.align -c grow-diag-final-and >$MYTEMPDIR/symmetric.align

# if user specified temporary directory, we keep everything
if [ -z $SPECTEMPDIR ]
then rm -Rf $MYTEMPDIR/forward.align $MYTEMPDIR/reverse.align $MYTEMPDIR/fainput
fi

# NER and build TMX
paste $MYTEMPDIR/omitted-mixed $MYTEMPDIR/f1.tok.origcase $MYTEMPDIR/f2.tok.origcase $MYTEMPDIR/f1.tok $MYTEMPDIR/f2.tok $MYTEMPDIR/symmetric.align \
    | $CAT \
    | parallel -k -j$JOBS -l $BLOCKSIZE --pipe $NER > $MYTEMPDIR/nerext.out

# nerext.out is extended output, ner.out is final output
awk -F '\t' '{ sub(/^.*\t__srcmap__\t/,""); sub(/\t__trgmap__\t.*$/,""); print $0 }' $MYTEMPDIR/nerext.out > $MYTEMPDIR/srcmapfile
awk -F '\t' '{ sub(/^.*\t__trgmap__\t/,""); print $0 }' $MYTEMPDIR/nerext.out > $MYTEMPDIR/trgmapfile
if [ "$PLACEHOLDER" == true ]
then awk -F '\t' '{ print $5 "\t" $6 }' $MYTEMPDIR/nerext.out > $MYTEMPDIR/ner.out
else awk -F '\t' '{ print $1 "\t" $2 }' $MYTEMPDIR/nerext.out > $MYTEMPDIR/ner.out
fi

cat $MYTEMPDIR/ner.out | $BUILDTMX $L1 $L2

if [ -z $SPECTEMPDIR ]
then echo "Removing temporary directory $MYTEMPDIR" 1>&2
     rm -Rf $MYTEMPDIR
fi
