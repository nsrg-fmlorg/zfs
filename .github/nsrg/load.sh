#!/bin/sh
# load.sh <srcdir>: unload whatever is loaded, load the tree's modules.
set -eu
cd "$1"
sudo scripts/zfs.sh -u >/dev/null 2>&1 || true
sudo scripts/zfs-helpers.sh -i >/dev/null
sudo scripts/zfs.sh
