#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Tests nbg6816-install.sh on the stock firmware's own userland, without a router:
#   test/run.sh DUMPS [SCRIPT]
# DUMPS holds a stock NBG6816's partitions as mtdN-NAME.bin (mtd3-env.bin, mtd5-HLOS.bin up to
# mtd10-rootfs.bin), dumped from the router; Zyxel's firmware isn't distributed here. SCRIPT is
# the built script (default out/nbg6816-install.sh). The kernel's part is stood in for: MTD
# geometry for fw_setenv (mtdshim.c), insmod, rmmod, mtd erase and the LAN's ifconfig (stubs/).
set -eu

DUMPS=${1:?usage: test/run.sh DUMPS [SCRIPT]}
TEST=$(cd "$(dirname "$0")" && pwd)
SCRIPT=${2:-$TEST/../out/nbg6816-install.sh}
IMAGE=nbg6816-install-test
[ -f "$SCRIPT" ] || { echo "no $SCRIPT: build it first (docker build -o out .)" >&2; exit 1; }

docker build -q --platform linux/arm/v7 --build-context dumps="$DUMPS" -t $IMAGE "$TEST" >/dev/null
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# An erased HLOS, as long as the dump's
FF=$WORK/ff
HLOS=$(echo "$DUMPS"/mtd5-*.bin)
dd if=/dev/zero bs=65536 count=$(($(wc -c <"$HLOS") / 65536)) 2>/dev/null |
	LC_ALL=C tr '\0' '\377' >"$FF"

FAILED=0
fail() { echo "FAIL $CASE: $*"; FAILED=1; }

# U-Boot's environment as the script must leave it, for a PC at 192.168.1.2
ARM='mw.l 0x0208a04c 0x780000; mw.l 0x0208a05c 0x780000; mw.l 0x0208a038 1; mw.l 0x0208a040 1'
BOOTCMD='mw.l 0x0208a040 0; run boot_flash; run boot_tftp'
BOOT_FLASH='run setmtdparts flashargs addtty addmtd;sf probe;sf read ${loadaddr} ${kernel_paddr} 0xa00000;iminfo ${loadaddr} && bootm ${loadaddr}'
BOOT_TFTP="setenv ipaddr 192.168.1.1; setenv netmask 255.255.255.0; setenv serverip 192.168.1.2; setenv tftpblocksize 1400; mw.l \${loadaddr} 0 1; $ARM; if tftpboot \${loadaddr} nbg6816-initramfs.bin; then if iminfo \${loadaddr}; then $ARM; bootm \${loadaddr}; fi; fi"
LAN='br-lan    Link encap:Ethernet  HWaddr 00:00:5E:00:53:01
          inet addr:192.168.1.1  Bcast:192.168.1.255  Mask:255.255.255.0'

# setup NAME: a fresh router in $WORK/NAME, as the dumps hold it, the PC at 192.168.1.2 on its
# LAN; a case changes what it tests before run
setup() {
	CASE=$1
	C=$WORK/$1
	mkdir -p "$C/dev" "$C/sys"
	for f in "$DUMPS"/mtd3-*.bin "$DUMPS"/mtd[5-9]-*.bin "$DUMPS"/mtd10-*.bin; do
		n=$(basename "$f" .bin)
		cp "$f" "$C/dev/${n%%-*}"
		mkdir "$C/sys/${n%%-*}"
		echo "${n#*-}" >"$C/sys/${n%%-*}/name"
		echo 0x800 >"$C/sys/${n%%-*}/flags"
	done
	cp "$SCRIPT" "$C/script"
	echo "$LAN" >"$C/ifconfig"
	SSH='192.168.1.2 50000 192.168.1.1 22'
	: >"$C/calls"
	cp "$FF" "$C/ff"
}

# run ARGS: the script run as ssh does, in the stock root
run() {
	mounts=
	for d in "$C"/dev/mtd*; do
		mounts="$mounts -v $d:/stock/dev/$(basename "$d")"
	done
	[ ! -e "$C/openwrt_release" ] || mounts="$mounts -v $C/openwrt_release:/stock/etc/openwrt_release"
	# $mounts unquoted: a list of options
	docker run --rm --platform linux/arm/v7 -e SSH_CONNECTION="$SSH" -v "$C":/stock/t \
		-v "$C/sys":/stock/sys/class/mtd $mounts $IMAGE sh /case.sh "$@"
	RC=$(cat "$C/rc")
}

ok() { [ "$RC" = 0 ] || fail "exit $RC: $(cat "$C/stderr")"; }
refused() {
	[ "$RC" != 0 ] || fail "not refused"
	grep -q "$1" "$C/stderr" || fail "no '$1' in: $(cat "$C/stderr")"
}
# unchanged [EXCEPT...]: every partition as the dumps hold it, except those named
unchanged() {
	for d in "$C"/dev/mtd*; do
		n=$(basename "$d")
		case " $* " in *" $n "*) continue ;; esac
		f=$C/expected-$n
		[ -e "$f" ] || f=$(echo "$DUMPS/$n"-*.bin)
		cmp -s "$d" "$f" || fail "$n written"
	done
}
var() { grep "^$1=" "$C/printenv" | cut -d= -f2-; }
# expect VAR VALUE: U-Boot's VAR as the stock fw_printenv reads it after the run
expect() { [ "$(var "$1")" = "$2" ] || fail "$1: $(var "$1")"; }
# setenv VAR VALUE: in the case's env, by the stock fw_setenv, before the run
setenv() {
	docker run --rm --platform linux/arm/v7 -v "$C/dev/mtd3":/stock/dev/mtd3 $IMAGE sh -c \
		'mknod /stock/dev/null c 1 3; chroot /stock /usr/sbin/fw_setenv "$0" "$1"' "$1" "$2"
	cp "$C/dev/mtd3" "$C/expected-mtd3"
}
nothing_written() {
	unchanged
	[ "$(cat "$C/sys/mtd3/flags")" = 0x800 ] || fail "env left writeable"
}

# The factory environment, as the stock fw_printenv reads it
setup factory-env
run backup >/dev/null
grep -q 'Bad CRC' "$C/printenv" && fail "the dump's env has a bad CRC"
grep -vE '^(bootcmd|boot_flash|boot_tftp)=' "$C/printenv" >"$WORK/others"

setup install
run install
ok
expect bootcmd "$BOOTCMD"
expect boot_flash "$BOOT_FLASH"
expect boot_tftp "$BOOT_TFTP"
grep -vE '^(bootcmd|boot_flash|boot_tftp)=' "$C/printenv" | cmp -s - "$WORK/others" ||
	fail "other variables changed"
grep -q 'Bad CRC' "$C/printenv" && fail "bad CRC after the write"
cmp -s "$C/dev/mtd5" "$C/ff" || fail "HLOS not erased"
unchanged mtd3 mtd5
[ "$(cat "$C/calls")" = "insmod /tmp/env_rw.ko
rmmod env_rw
mtd erase HLOS" ] || fail "calls: $(cat "$C/calls")"
cmp -s "$C/insmod.ko" "$(dirname "$SCRIPT")/env_rw.ko" || fail "the module loaded isn't env_rw.ko"
[ "$(cat "$C/sys/mtd3/flags")" = 0x800 ] || fail "env left writeable"
cp "$C/dev/mtd3" "$WORK/installed-env"

# Run again on an environment it wrote (the stock kernel still there): the same result
setup rerun
cp "$WORK/installed-env" "$C/dev/mtd3"
run install
ok
cmp -s "$C/dev/mtd3" "$WORK/installed-env" || fail "env differs from the first run's"

# Run again after a run that stopped halfway, boot_flash written and not bootcmd
setup halfway
setenv boot_flash "$BOOT_FLASH"
run install
ok
expect bootcmd "$BOOTCMD"
expect boot_tftp "$BOOT_TFTP"

setup backup
run backup >/dev/null
ok
mkdir "$C/out"
docker run --rm -v "$C":/c busybox:1.36 sh -c 'cd /c/out && tar xf /c/stdout && md5sum -c md5sums' \
	>/dev/null || fail "tar or md5sums"
cat "$DUMPS"/mtd5-*.bin "$DUMPS"/mtd6-*.bin "$DUMPS"/mtd7-*.bin "$DUMPS"/mtd8-*.bin \
	"$DUMPS"/mtd9-*.bin "$DUMPS"/mtd10-*.bin | cmp -s - "$C/out/stock-firmware.bin" ||
	fail "stock-firmware.bin isn't HLOS..rootfs"
cmp -s "$DUMPS"/mtd3-*.bin "$C/out/stock-env.bin" || fail "stock-env.bin isn't env"
nothing_written

# Another stock version: refused, then installed with --untested-version
setup other-version
perl -0777 -pe 's/V1\.00\(AAWB\.12\)C0/V1.00(AAWB.11)C0/' "$C/dev/mtd7" >"$C/expected-mtd7"
cp "$C/expected-mtd7" "$C/dev/mtd7"
run install
refused 'could work'
nothing_written
CASE=untested-version
run install --untested-version
ok
expect bootcmd "$BOOTCMD"

setup layout
echo kernel >"$C/sys/mtd5/name"
run install
refused 'stock flash layout'
nothing_written

setup other-firmware
echo 'DISTRIB_TARGET="ipq806x/nbg6817"' >"$C/openwrt_release"
run install
refused "not the NBG6816's stock firmware"
nothing_written

setup bad-crc
perl -0777 -pe 's/bootdelay=3/bootdelay=4/' "$C/dev/mtd3" >"$C/expected-mtd3"
cp "$C/expected-mtd3" "$C/dev/mtd3"
run install
refused 'bad CRC'
nothing_written

# An environment someone changed, by the stock fw_setenv
setup changed-env
setenv bootcmd 'run boot_net; run boot_flash'
run install
refused "isn't the factory one"
nothing_written

setup pc-elsewhere
SSH='10.0.0.5 50000 192.168.1.1 22'
run install
refused "isn't on the router's LAN"
nothing_written

setup via-wan
SSH='192.168.1.2 50000 10.1.1.1 22'
run install
refused "connect to the router's LAN address"
nothing_written

# The stock Dropbear listens on every family: an IPv4 client can come as a mapped address
setup mapped
SSH='::ffff:192.168.1.2 50000 ::ffff:192.168.1.1 22'
run install
ok
expect boot_tftp "$BOOT_TFTP"

setup ipv6
SSH='fe80::2 50000 fe80::1 22'
run install
refused "isn't IPv4"
nothing_written

setup no-ssh
SSH=
run install
refused 'run it over ssh'
nothing_written

setup corrupt-module
awk 'f && !done && length($0) == 64 { $0 = (substr($0, 1, 1) == "A" ? "B" : "A") substr($0, 2); done = 1 }
	/openssl enc -d -base64/ { f = 1 } 1' "$SCRIPT" >"$C/script"
run install
refused 'embedded module is corrupt'
nothing_written

setup insmod-fails
: >"$C/insmod-fails"
run install
refused "didn't load"
nothing_written

setup env-stays-ro
: >"$C/env-stays-ro"
run install
refused 'still read-only'
nothing_written
grep -q '^rmmod' "$C/calls" || fail "module left loaded"

# The erase failing: the environment is written, and the user is told to boot from the PC
setup erase-fails
: >"$C/erase-fails"
run install
refused 'erasing the stock kernel failed'
expect bootcmd "$BOOTCMD"

setup no-lan
rm "$C/ifconfig"
run install
refused 'no LAN bridge'
nothing_written

[ $FAILED = 0 ] && echo "all tests passed"
exit $FAILED
