#!/bin/sh
# oldkernel.sh <image>: build the kernel modules in a container against
# that distribution's kernel headers, so that compatibility branches the
# runner's own kernel never takes are compiled at all.  Prints the
# configure results a branch names in .github/nsrg/oldkernel-defines.
set -eu
image=$1
defines=$(cat .github/nsrg/oldkernel-defines 2>/dev/null || echo HAVE_)
docker run --rm -e DEFINES="$defines" -v "$PWD":/src -w /src "$image" sh -c '
	set -eu
	export DEBIAN_FRONTEND=noninteractive
	. /etc/os-release
	case $ID in
	ubuntu)	hdr=linux-headers-generic ;;
	debian)	hdr=linux-headers-amd64 ;;
	esac
	apt-get update -qq
	apt-get install -y -qq build-essential autoconf automake libtool \
	    gawk libblkid-dev uuid-dev libudev-dev libssl-dev zlib1g-dev \
	    libaio-dev libattr1-dev libelf-dev python3 python3-dev \
	    python3-setuptools python3-cffi libffi-dev libcurl4-openssl-dev \
	    libtirpc-dev git $hdr >/dev/null
	obj=$(ls -d /usr/src/linux-headers-*-generic \
	    /usr/src/linux-headers-*-amd64 2>/dev/null | tail -1)
	src=$(ls -d /usr/src/linux-headers-*-common 2>/dev/null | tail -1)
	[ -n "$src" ] || src=$obj
	echo "$PRETTY_NAME: building against $obj"
	git config --global --add safe.directory /src
	sh autogen.sh >/dev/null
	./configure -q --enable-debug --with-config=kernel \
	    --with-linux="$src" --with-linux-obj="$obj"
	for d in $DEFINES; do
		grep -E "^#define $d|^/\\* #undef $d" zfs_config.h || true
	done
	make -s -j"$(nproc)"
	echo "$PRETTY_NAME: build ok"
'
