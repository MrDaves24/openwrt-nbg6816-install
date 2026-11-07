# Builds env_rw.ko and nbg6816-install.sh into out/:
#   docker build -o out .
# The module is built as the one tested on the stock firmware was, and the build fails unless it
# is that module byte for byte (env_rw.ko.sha256): the same compiler (OpenWrt's toolchain, from
# source at a pinned commit: OpenWrt's published SDKs carry another GCC, or don't last), the same
# kernel tree and configuration, the same paths (they are in its debug information).

# OpenWrt's toolchain for ipq806x. Its version string carries a hash of OpenWrt's toolchain/
# sources, so any commit with the same sources gives the same compiler.
FROM debian:trixie-20261027 AS toolchain
RUN apt-get update && apt-get install -y --no-install-recommends \
	build-essential clang flex bison g++ gawk gettext git \
	libncurses-dev libssl-dev python3 python3-setuptools rsync swig unzip zlib1g-dev \
	file wget ca-certificates xz-utils zstd bzip2 patch perl diffutils cpio bc \
	&& rm -rf /var/lib/apt/lists/*
# Building as root is discouraged, and some host tools' configure scripts refuse it
RUN useradd -m -u 1000 build && mkdir /openwrt /k && chown build:build /openwrt /k
USER build
WORKDIR /openwrt
ARG OPENWRT=85e54359cf7de03033f74faa7f7cc7f287313c34
RUN git init -q && git fetch -q --depth 1 https://github.com/openwrt/openwrt.git $OPENWRT \
	&& git checkout -q FETCH_HEAD
RUN printf '%s\n' CONFIG_TARGET_ipq806x=y CONFIG_TARGET_ipq806x_generic=y >.config \
	&& make defconfig >/dev/null \
	&& { make -j$(nproc) tools/install toolchain/install >/dev/null 2>&1 \
		|| make -j1 V=s tools/install toolchain/install; }

# Vanilla Linux 3.4, configured so that a module's vermagic and struct module layout match the
# stock kernel's (it has no symbol versions, so that is all insmod checks): any ARMv7 SMP board,
# no preemption, symbol versions, unwind tables (they grow struct module) or p2v patching (it
# adds "p2v8" to the vermagic), which then needs RAM's base; no outer cache controller (its
# inlines reference outer_cache, which the stock kernel doesn't export); the 3G split. 3.4 has
# no olddefconfig, and its oldconfig prompts: alldefconfig with a fragment.
FROM toolchain AS module
WORKDIR /k
RUN wget -q https://cdn.kernel.org/pub/linux/kernel/v3.x/linux-3.4.tar.xz \
	&& echo 'ff3dee6a855873d12487a6f4070ec2f7996d073019171361c955639664baa0c6  linux-3.4.tar.xz' \
		| sha256sum -c >/dev/null \
	&& tar xf linux-3.4.tar.xz && rm linux-3.4.tar.xz
WORKDIR /k/linux-3.4
# The toolchain's directory is named after its target and versions: a fixed path to it
RUN ln -s /openwrt/staging_dir/toolchain-*/bin /k/cc
ENV STAGING_DIR=/openwrt/staging_dir ARCH=arm CROSS_COMPILE=/k/cc/arm-openwrt-linux-muslgnueabi-
# 3.4 knows compilers up to gcc 4: a newer one gets the gcc 4 header
RUN GCC=$(${CROSS_COMPILE}gcc -dumpversion | cut -d. -f1) \
	&& cp include/linux/compiler-gcc4.h include/linux/compiler-gcc$GCC.h \
	&& { cat arch/arm/configs/vexpress_defconfig; printf '%s\n' CONFIG_SMP=y CONFIG_MODULES=y \
		CONFIG_MODULE_UNLOAD=y '# CONFIG_MODVERSIONS is not set' '# CONFIG_PREEMPT is not set' \
		'# CONFIG_ARM_UNWIND is not set' CONFIG_EMBEDDED=y CONFIG_EXPERT=y \
		'# CONFIG_ARM_PATCH_PHYS_VIRT is not set' CONFIG_PHYS_OFFSET=0x41500000 \
		'# CONFIG_CACHE_L2X0 is not set' '# CONFIG_VMSPLIT_2G is not set' CONFIG_VMSPLIT_3G=y \
		CONFIG_PAGE_OFFSET=0xC0000000; } >/k/fragment \
	&& make KCONFIG_ALLCONFIG=/k/fragment alldefconfig </dev/null >/dev/null \
	&& make modules_prepare </dev/null >/dev/null
COPY --chown=build env-rw /k/mod
COPY env_rw.ko.sha256 nbg6816-install.sh.in /k/
RUN make M=/k/mod modules </dev/null >/dev/null \
	&& cd /k/mod && sha256sum -c /k/env_rw.ko.sha256
# The script carries the module, in base64 (the stock busybox has no decoder, its openssl has)
RUN cd /k && base64 -w 64 mod/env_rw.ko >ko.b64 \
	&& sha=$(sha256sum mod/env_rw.ko | cut -d' ' -f1) \
	&& awk -v sha="$sha" '$0 == "@ENV_RW_KO@" { while ((getline l < "ko.b64") > 0) print l; next } \
		{ gsub("@ENV_RW_SHA256@", sha) } 1' nbg6816-install.sh.in >nbg6816-install.sh

FROM scratch
COPY --from=module /k/mod/env_rw.ko /k/nbg6816-install.sh /
