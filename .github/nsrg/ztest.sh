#!/bin/sh
# Run as root, as zloop.sh is: ztest talks to /dev/zfs.
set -eu
# ztest runs zdb from PATH to verify the pool when it finishes.
PATH=$(pwd):$PATH
export PATH
mkdir -p /var/tmp/ztest
./ztest -V -T 600 -f /var/tmp/ztest
