# Install OpenWrt on a Zyxel NBG6816 from its stock firmware

The Zyxel NBG6816 (Armor Z1) runs OpenWrt, but its stock firmware can't install it: its web
interface takes only Zyxel's images, and its bootloader reads 2 MB of flash, less than OpenWrt's
kernel. This repo holds what the install needs on the stock side: `nbg6816-install.sh`, which
changes the bootloader's settings from the stock firmware's shell, and `env_rw.ko`, the kernel module
it loads to do so.

**The install guide** is the installation section of OpenWrt's commit adding the device,
"ipq806x: add support for Zyxel NBG6816". In short: turn SSH on in the stock web interface, run
the script over SSH (`backup` first, then `install`), reboot into OpenWrt's initramfs served by a
TFTP server on your PC, then `sysupgrade -n`. Get `nbg6816-install.sh` from this repo's releases.

## What the script does

It runs on the stock firmware, read from stdin by `sh -s`, so it never needs to be copied over.

- `backup` streams a tar to stdout: `stock-firmware.bin` (the partitions `HLOS` through
  `rootfs` concatenated, 30848 KB, which OpenWrt's `firmware` partition covers exactly),
  `stock-env.bin` (U-Boot's environment, with the router's MAC addresses and serial number) and
  their md5sums. Restoring is `mtd -r write stock-firmware.bin firmware` from OpenWrt.
- `install` checks, then writes:
  1. the stock flash layout and firmware, and the version: on anything but V1.00(AAWB.12)C0,
     Zyxel's last, it stops unless run again with `--untested-version`;
  2. U-Boot's environment: a good CRC, and the factory boot commands (or the ones this script
     wrote);
  3. the addresses: the router's LAN address for the bootloader, the PC's from the SSH connection;
  4. loads the embedded `env_rw.ko`, checked by its sha256, which makes the `env` partition
     writeable (the stock kernel keeps it read-only), and checks that it is;
  5. writes the environment with the stock `fw_setenv`, reads it back, unloads the module;
  6. erases the stock kernel (`HLOS`), last.

  Any failure before the last step leaves the router booting the stock firmware, unchanged.

The environment it leaves boots the flash, reading 10 MB and checking the image's CRCs first,
and only if that fails, arms the watchdog and fetches `nbg6816-initramfs.bin` over TFTP from the PC's
address. Erasing the stock kernel makes the next boot that TFTP boot; after `sysupgrade`, the
router boots OpenWrt from flash, and the TFTP comes back only if the flash's image is broken.
Without a PC answering, the watchdog resets the router every 4 minutes and it tries again.

## Building

    docker build -o out .

This gives `out/env_rw.ko` and `out/nbg6816-install.sh`. The build fails unless the module is,
byte for byte, the one tested on the stock firmware (`env_rw.ko.sha256`): it builds OpenWrt's
toolchain from source at a pinned commit (about 20 minutes and a few GB the first time), then
the module against vanilla Linux 3.4, configured so that its vermagic and module layout match the
stock kernel's. Only OpenWrt's compiler is used: this isn't an OpenWrt package. The match was checked on one machine (an arm64 Mac with OrbStack).

## Testing

    test/run.sh DUMPS

runs the script on the stock firmware's own userland (its busybox, `fw_setenv`, `openssl`) in a
32-bit ARM container, against copies of a stock router's partitions in `DUMPS` (`mtd3-env.bin`,
`mtd5-HLOS.bin` to `mtd10-rootfs.bin`, dumped from the router: Zyxel's firmware isn't
distributed here). The kernel's part is stood in for: the MTD driver for `fw_setenv`, `insmod`,
`rmmod`, `mtd erase` and the LAN's `ifconfig`. The tests check the backup, the environment
`install` leaves (and nothing else changed), the order of the writes, and that every refusal
writes nothing.

What the tests can't show was done on one unit, in the steps this install takes: `env_rw.ko`
loading on the stock kernel and `fw_setenv` writing the environment, a TFTP boot of OpenWrt's
initramfs over the stock flash, and `sysupgrade` from it. The environment this script writes, and
the revert, were never run on a router.

## License

GPL-2.0-only ([LICENSE](LICENSE)).
