# The stock firmware's root filesystem, from a dump of its rootfs partition, as a chroot in a
# 32-bit ARM container: the script runs on the stock busybox, fw_setenv and openssl. Built by
# run.sh, with the dumps as the "dumps" build context.
FROM --platform=$BUILDPLATFORM debian:trixie-20261027 AS prep
RUN apt-get update && apt-get install -y --no-install-recommends \
	squashfs-tools gcc-arm-linux-gnueabi patchelf \
	&& rm -rf /var/lib/apt/lists/*
COPY --from=dumps mtd10-rootfs.bin /in/
RUN unsquashfs -q -d /stock /in/mtd10-rootfs.bin >/dev/null
COPY mtdshim.c /src/
# The stock uClibc ignores LD_PRELOAD: the shim takes libgcc_s's place and loads it in turn
RUN mv /stock/lib/libgcc_s.so.1 /stock/lib/libgcc_real.so.1 \
	&& arm-linux-gnueabi-gcc -O2 -marm -shared -fPIC -nostdlib -Wl,--hash-style=sysv \
		-Wl,-soname,libgcc_s.so.1 -o /stock/lib/libgcc_s.so.1 /src/mtdshim.c \
	&& patchelf --add-needed libgcc_real.so.1 /stock/lib/libgcc_s.so.1 \
	&& rm /stock/sbin/insmod /stock/sbin/rmmod /stock/sbin/ifconfig /stock/sbin/mtd
COPY stubs/ /stock/sbin/

FROM busybox:1.36
COPY --from=prep /stock /stock
COPY case.sh /
