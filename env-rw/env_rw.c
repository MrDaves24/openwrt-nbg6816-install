// SPDX-License-Identifier: GPL-2.0-only
// Makes the "env" partition writable while loaded, so the stock firmware's fw_setenv can
// rewrite U-Boot's environment; unloading makes it read-only again. Built for the stock
// 3.4 kernel only, by the Dockerfile.
#include <linux/module.h>
#include <linux/err.h>
#include <linux/mtd/mtd.h>

static struct mtd_info *mtd;

static int __init env_rw_init(void)
{
	mtd = get_mtd_device_nm("env");
	if (IS_ERR(mtd))
		return PTR_ERR(mtd);
	mtd->flags |= MTD_WRITEABLE;
	return 0;
}

static void __exit env_rw_exit(void)
{
	mtd->flags &= ~MTD_WRITEABLE;
	put_mtd_device(mtd);
}

module_init(env_rw_init);
module_exit(env_rw_exit);
MODULE_LICENSE("GPL");
