#!/bin/bash
set -e 

export TF_FORCE_GPU_ALLOW_GROWTH=true
export TF_CPP_MIN_LOG_LEVEL=3
export TF_NUM_INTEROP_THREADS=4
export TF_NUM_INTRAOP_THREADS=4
export CUDA_DEVICE_ORDER=PCI_BUS_ID
export CUDA_VISIBLE_DEVICES=3
export DEBUG_DEVEL=1

ROOT_PATH=$(pwd)/../..

#
acc=3
vcc=10
pics_lambda=5
nlinv_lambda=5
reg_iter=4
max_iter=11
redu=2.5
start=70
end=150

graph_folder=$ROOT_PATH/MRI-Image-Priors/PixelCNN/exported
cplx_small=$graph_folder/cplx_small
cplx_large=$graph_folder/cplx_large

folder=redu_${redu}_${nlinv_lambda}_${pics_lambda}_$acc
mkdir -p $ROOT_PATH/results/small/$folder
cd $ROOT_PATH/results/small/$folder

dat=/home/ague/archive/vol/2023-02-17_MRT5_DCRD_0015/meas_MID00020_FID75992_t1_mprage_tra_p2_iso.dat 

# read dat file
# and restore the normal grid and remove oversampling
if [ ! -f kdat.cfl ]; then
    bart twixread -A $dat kdat
    bart zeros 4 108 282 224 16 tmp
    bart join 0 tmp kdat kdat_
    bart reshape $(bart bitmask 0 4) 2 256 kdat_ tmp
    bart avg $(bart bitmask 0) tmp kdat__
    bart transpose 0 4 kdat__ kdat_
    bart resize -c 1 256 kdat_ kdat_256
    bart cc -p $vcc kdat_256 ckdat_256
    bart fft -i $(bart bitmask 2) ckdat_256 kdat_xy
    rm tmp.* kdat__.* kdat_.* kdat_256.*
fi

bart upat -Y256 -Z256 -y$acc -z1 -c30 mask
bart transpose 0 1 mask mask
bart transpose 1 2 mask mask
bart fmac mask kdat_xy kdat_xy_u

pics()
{
    bart pics -g -i80 -R TF:{$1}:$pics_lambda $4 $5 $3_pics_$2
}

nlinv()
{
    bart nlinv -g -a660 -b44 -i$max_iter -C50 -r$redu --reg-iter=$reg_iter -R TF:{$1}:$nlinv_lambda:1 $4 $3_nlinv_$2 $3_nlinv_coils_$2
}

for num in $(seq $start $end)
do
tmp_slice=$(mktemp /tmp/slice-script.XXXXXX)
tmp_coils=$(mktemp /tmp/coils-script.XXXXXX)
bart slice 2 $num kdat_xy_u $tmp_slice
bart ecalib -r 20 -m1 -c 0.001 $tmp_slice $tmp_coils

# pics
bart pics -g -l1 -r 0.02 $tmp_slice $tmp_coils l1_pics_$num
bart pics -g -l2 -r 0.02 $tmp_slice $tmp_coils l2_pics_$num
pics $cplx_small $num cplx_small $tmp_slice $tmp_coils
pics $cplx_large $num cplx_large $tmp_slice $tmp_coils

# nlinv
bart nlinv -g -a660 -b44 -i10 -r2 $tmp_slice l2_nlinv_$num l2_nlinv_coils_$num
bart nlinv -g -a660 -b44 -i$max_iter -C50 -r$redu --reg-iter=$reg_iter -R W:3:0:0.1 $tmp_slice l1_nlinv_$num l1_nlinv_coils_$num
nlinv $cplx_small $num cplx_small $tmp_slice
nlinv $cplx_large $num cplx_large $tmp_slice
done

# expect the worst reconstruction without any prior knowledge
bart fft -i $(bart bitmask 0 1) kdat_xy_u cimgs
bart rss $(bart bitmask 3) cimgs zero_filled
bart extract 2 $start $(($end + 1)) zero_filled czero_filled

# expect the best reconstruction from the most k-space data using pics
bart ecalib -r 20 -m1 ckdat_256 coils
bart pics -g -l1 -r 0.02 ckdat_256 coils volume
bart extract 2 $start $(($end + 1)) volume cvolume

# expect the best reconstruction from the most k-space data using nlinv
for num in $(seq $start $end)
do
tmp_slice=$(mktemp /tmp/abc-script.XXXXXX)
bart slice 2 $num kdat_xy $tmp_slice
bart nlinv -g -a660 -b44 -i$max_iter -C50 -r2 --reg-iter=$reg_iter -R W:3:0:0.1 $tmp_slice nlinv_$num nlinv_coils_$num
done

# concatenate slices
concatenate()
{
s1=""
for num in $(seq $start $end)
do
    s1=$s1$1_$num" "
done
bart join 2 $s1 $1_volume
}


concatenate cplx_large_pics
concatenate cplx_small_pics
concatenate l1_pics
concatenate l2_pics
concatenate cplx_large_nlinv
concatenate cplx_small_pics
concatenate l2_nlinv
concatenate l1_nlinv
concatenate nlinv
