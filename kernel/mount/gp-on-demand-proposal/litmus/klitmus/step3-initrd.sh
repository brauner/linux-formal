#!/bin/bash
set -u
K=~/tmp/klitmus
adds=(); for ko in $K/kmod/*.ko; do adds+=(--add "$ko:/klitmus/$(basename $ko)"); done
[ ${#adds[@]} -gt 0 ] || { echo "no modules"; exit 1; }
python3 ~/src/umount-bench/bin/mkinitrd.py -o $K/initrd.cpio --init $K/init.sh "${adds[@]}" && ls -la $K/initrd.cpio
