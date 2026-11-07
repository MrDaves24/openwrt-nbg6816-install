// SPDX-License-Identifier: GPL-2.0-only
// Test stand-in for the stock kernel's MTD driver: the stock fw_printenv and fw_setenv ask it
// for the env partition's geometry and to erase it, and here /dev/mtd3 is a plain file. Built
// without a libc, so it makes its system calls itself.
static long sys3(long n, long a, long b, long c)
{
	register long r0 asm("r0") = a;
	register long r1 asm("r1") = b;
	register long r2 asm("r2") = c;
	register long r7 asm("r7") = n;
	asm volatile("svc 0" : "+r"(r0) : "r"(r1), "r"(r2), "r"(r7) : "memory");
	return r0;
}

#define SYS_write 4
#define SYS_lseek 19
#define SYS_ioctl 54

int ioctl(int fd, unsigned long req, void *arg)
{
	unsigned char *p = arg;
	unsigned int *w = arg;
	static char ff[4096];
	unsigned int len;
	int i;

	switch (req) {
	case 0x80204d01: // MEMGETINFO: a 64 KB NOR partition, one erase block
		for (i = 0; i < 32; i++)
			p[i] = 0;
		p[0] = 3; // MTD_NORFLASH
		w[1] = 0xc00; // MTD_WRITEABLE | MTD_BIT_WRITEABLE
		w[2] = 0x10000; // size
		w[3] = 0x10000; // erasesize
		w[4] = 1; // writesize
		return 0;
	case 0x40084d02: // MEMERASE: the range back to 0xff
		for (i = 0; i < 4096; i++)
			ff[i] = (char)0xff;
		if (sys3(SYS_lseek, fd, w[0], 0) < 0)
			return -1;
		for (len = w[1]; len; len -= i) {
			i = len > 4096 ? 4096 : len;
			if (sys3(SYS_write, fd, (long)ff, i) != i)
				return -1;
		}
		return 0;
	case 0x40084d05: // MEMLOCK
	case 0x40084d06: // MEMUNLOCK
	case 0x40084d0b: // MEMGETBADBLOCK
		return 0;
	default:
		i = sys3(SYS_ioctl, fd, req, (long)arg);
		return i < 0 && i > -4096 ? -1 : i;
	}
}
