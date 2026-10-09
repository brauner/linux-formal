#!/bin/bash
# all configurations under SC; see run.py --help
cd "$(dirname "$0")" && exec python3 run.py "$@"
