#!/bin/sh
set -eu
mkdir -p /var/tmp/ztest
./ztest -V -T 600 -f /var/tmp/ztest
