#!/bin/bash
# keep bzImage, config, the .ko files, module sources and logs; drop the build tree and its worktree
set -u
K=~/tmp/klitmus
ls $K/kmod/*.ko > /dev/null 2>&1 || { echo "no modules built, keeping $K/build for a retry"; exit 0; }
git -C ~/src/git/linux worktree remove --force $K/build/src || rm -rf $K/build/src
rm -rf $K/build
git -C ~/src/git/linux worktree prune
du -sh $K
