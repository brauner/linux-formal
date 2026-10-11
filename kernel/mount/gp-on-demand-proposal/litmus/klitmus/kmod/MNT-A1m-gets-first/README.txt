Kernel modules produced by klitmus7

REQUIREMEMTS
  - kernel headers for compiling modules.
  - commands insmod and rmmod for installing and removing kernel modules.

COMPILING
  Once kernel headers are installed, just type 'make'

RUNNING
  Run script 'run.sh' as root, e.g. as 'sudo sh run.sh'
  Some parameters can be passed to the script by adding
  key=value command line arguments.
  Main arguments are as follows:
    * size=<n>   Tests operate on arrays of size <n>.
    * nruns=<n>  And are repeated <n> times.
    * stride=<n> Arrays are scanned with stride <n>.
    * avail=<n>  Number of cores are devoted to tests.

  If <avail> is the special value zero or exceeds <a>, the number of actually online cores,
  then tests will occupy <a> cores.

  By default the script runs as if called as:
    sudo sh run.sh size=100000 nruns=10 stride=1 avail=0

