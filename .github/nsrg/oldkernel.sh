#!/bin/sh
# oldkernel.sh: build the kernel modules against Linux 5.4 headers, in an
# Ubuntu 20.04 container.  Kernels before 5.11 lack kmap_local_page(),
# so HAVE_KMAP_LOCAL_PAGE is unset and the kmap()/kunmap() branches in
# abd_os.c are compiled; the runner's own kernel never builds them.
set -eu
docker run --rm -v "$PWD":/src -w /src ubuntu:20.04 sh -c '
	set -eu
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y -qq build-essential autoconf automake libtool \
	    gawk alien fakeroot dkms libblkid-dev uuid-dev libudev-dev \
	    libssl-dev zlib1g-dev libaio-dev libattr1-dev libelf-dev \
	    python3 python3-dev python3-setuptools python3-cffi \
	    libffi-dev libcurl4-openssl-dev libtirpc-dev \
	    git linux-headers-generic >/dev/null
	kdir=$(ls -d /usr/src/linux-headers-*-generic | tail -1)
	echo "building against $kdir"
	git config --global --add safe.directory /src
	sh autogen.sh >/dev/null
	./configure -q --enable-debug --with-config=kernel \
	    --with-linux="$kdir" --with-linux-obj="$kdir"
	grep -E "HAVE_KMAP_LOCAL_PAGE" zfs_config.h || true
	make -s -j"$(nproc)"
'
