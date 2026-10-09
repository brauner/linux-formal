# Dartagnan (Dat3M) on jens: mount gp-on-demand refcount harness

State file; copy lives at ~/tmp/dat3m/RESUME.md on jens and in the laptop
scratchpad dat3m/.  Everything is user-local, no root was used.

## What is installed on jens (user brauner)
- ~/tmp/dat3m/Dat3M      git clone of https://github.com/hernanponcedeleon/Dat3M,
                          master b81ec6c55503e824bb0ddc4ebac6c6f0a63d56d8
                          (2026-09-24, "Reorganize unit tests (#1089)",
                          = 4.4.1-73-gb81ec6c55; tag 4.4.1 = d8de5e8ef6aa, 2026-05-22)
- ~/opt/maven             Apache Maven 3.9.16 (binary tarball, sha512 verified)
- ~/opt/jdk21             Eclipse Temurin JDK 21.0.12.1+1 (tarball from api.adoptium.net,
                          sha256 ce79869e1307ed8ee1e2baa86a412b1eb5b75d10a01006d788a6f968bcfaee94)
                          needed because jens only has openjdk-25-jre-headless
                          (no javac, no ct.sym: mvn fails with "release version 17 not supported")
- ~/.m2                   Maven repository cache (deletable)
- ~/tmp/dat3m/dl          downloaded tarballs (deletable)
- ~/tmp/dat3m/harness     mnt_gp.c (the harness) + ll/ (compiled LLVM IR per variant)
- ~/tmp/dat3m/logs        build-*.log, build.rc, <target>/<variant>.log
- ~/tmp/dat3m/results.tsv target, variant, result, seconds, log
- ~/tmp/dat3m/output      DAT3M_OUTPUT scratch

## Build (JVM mode, ~/tmp/dat3m/build.sh, run inside tmux session `dat3m`)
    export JAVA_HOME=$HOME/opt/jdk21 PATH=$HOME/opt/jdk21/bin:$PATH
    cd ~/tmp/dat3m/Dat3M && taskset -c 256-511 ~/opt/maven/bin/mvn -B -q clean install -DskipTests
Result: dartagnan/target/dartagnan.jar.  Native (GraalVM) mode not built.
Never start a build or a check while ~/tmp/jens-bigvm.lock exists.

## Run one variant by hand
    export DAT3M_HOME=~/tmp/dat3m/Dat3M DAT3M_OUTPUT=~/tmp/dat3m/output PATH=~/opt/jdk21/bin:$PATH
    clang-19 -I $DAT3M_HOME/include -Xclang -disable-O0-optnone -S -emit-llvm -g -gcolumn-info \
        -DTARGET_LKMM -DSCEN_A1 ~/tmp/dat3m/harness/mnt_gp.c -o /tmp/A1.ll
    cd $DAT3M_HOME && taskset -c 256-511 java -Xmx24g -jar dartagnan/target/dartagnan.jar \
        cat/linux-kernel.cat --target=lkmm /tmp/A1.ll --bound=2 --property=program_spec,cat_spec
Targets: lkmm (cat/linux-kernel.cat, -DTARGET_LKMM), arm8 (cat/aarch64.cat, -DTARGET_LKMM_HW
-DGP_AS_NOP), power (cat/power.cat, same), tso (cat/tso.cat, -DTARGET_C11 -DGP_AS_NOP).
Scenario/mutation switches: see the header comment of mnt_gp.c.

## Run the matrix
    bash ~/tmp/dat3m/run.sh <lkmm|arm8|power|tso> [bound] [variant-regex]
(appends to ~/tmp/dat3m/results.tsv; logs under ~/tmp/dat3m/logs/<target>/)

## Status
(see the bottom of this file; updated as work proceeds)

## Status 2026-10-09 ~09:00 UTC: DONE for the planned matrix
- Built: dartagnan.jar (JVM mode) from master b81ec6c55 (4.4.1-73), Temurin 21, Maven 3.9.16.
  Build attempts: 08:37 (fail: no JDK, only openjdk-25-jre-headless), 08:43 (fail, same),
  08:47:11-08:47:31 OK (20 s wall, deps already cached from attempt 1).
- Ran: 6 targets x 17 variants = 102 checks, all with --bound=2, every one PASS or FAIL
  (no UNKNOWN, no ERROR): see results.tsv; logs/<target>/<variant>.log; witnesses in
  output/*.dot for lkmm-A1m-nomb-in-sum and arm8-B1m-walker-nomb.
  Targets: lkmm (cat/linux-kernel.cat, --property=program_spec,cat_spec), arm8, power, tso,
  plus power-c11 and arm8-c11 (harness compiled with the __atomic builtins and
  smp_rmb/smp_wmb as acquire/release fences, which is the kernel's lwsync mapping on POWER).
- Nothing is running.  tmux session `dat3m` has idle windows only.
- Divergences found and explained (see the report): tso PASSes A1m-nowmb and
  A1m-nomb-in-sum (TSO keeps store-store and load-load order); Dartagnan's power lowering
  maps smp_rmb/smp_wmb to `sync` (kernel: lwsync), hiding B1m-walker-nomb and
  D1m-holder-wmb-only (both FAIL with power-c11); arm8-c11 hides D1m because a C11
  release fence is dmb ish on arm64 (kernel smp_wmb is dmb ishst; the lkmm.h route FAILs it).

## Left to do (optional)
- Combined 3-thread scenario (holder + walker + unmounter, NR_CPUS=3) with both A1 and B
  assertions: add SCEN_ALL3 to mnt_gp.c (threads exist, only main() wiring is missing).
- RCU on hardware models: rcu.h has an RCU_IMP reference implementation (per-thread
  counters + grace-period flip) that would let A2/C2 run under arm8/power with a modelled
  grace period instead of GP_AS_MB.  Needs MAX_THREADS and the gp_ongoing() loop bounded.
- Higher bounds are unnecessary (no UNKNOWN at --bound=2: the only loops are the lock spins).
- Cleanup if space is needed: rm -rf ~/.m2 ~/tmp/dat3m/dl (≈ 400 MB); ~/opt/jdk21 is 330 MB.
