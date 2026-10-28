#!/bin/sh
# deps.sh [checkstyle|clang]
# Package list from .github/workflows/scripts/qemu-3-deps-vm.sh (ubuntu24,
# ONLY_DEPS: the runner kernel has no linux-modules-extra package),
# checkstyle tools from .github/workflows/checkstyle.yaml.
set -eu
export DEBIAN_FRONTEND=noninteractive
extra=
case ${1:-} in
checkstyle)	extra="cppcheck devscripts mandoc pax-utils shellcheck flake8" ;;
clang)		extra="clang" ;;
strict)		extra="clang sparse" ;;
esac
sudo apt-get update -y
# shellcheck disable=SC2086
sudo apt-get install -y \
  acl attr autoconf bc build-essential cpio cryptsetup dbench fio gdb git \
  ksh jq libacl1-dev libaio-dev libattr1-dev libblkid-dev \
  libcurl4-openssl-dev libelf-dev libffi-dev libmount-dev libpam0g-dev \
  libssl-dev libtirpc-dev libtool libtool-bin libudev-dev libunwind-dev \
  linux-headers-"$(uname -r)" lsscsi \
  parted python3 python3-cffi python3-dev python3-packaging \
  python3-setuptools rsync strace sysstat uuid-dev xfslibs-dev zlib1g-dev \
  $extra
sudo find /lib/modules -name zfs -type d -prune -exec rm -rf {} +
