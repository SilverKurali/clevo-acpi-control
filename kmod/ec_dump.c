// SPDX-License-Identifier: GPL-2.0
/*
 * ec_dump.c — dump ACPI EC RAM to /proc/ec_dump
 *
 * 用于识别风扇转速等未通过 ACPI 暴露的 EC 寄存器。
 * ec_read() 由 drivers/acpi/ec.c 导出，内部已处理 EC 访问锁。
 *
 * 只读，不写任何 EC 寄存器。
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/uaccess.h>
#include <linux/acpi.h>

#define EC_DUMP_SIZE 256

/* 由 drivers/acpi/ec.c 导出（EXPORT_SYMBOL），但未在公共头文件声明 */
extern int ec_read(u8 addr, u8 *val);

static int ec_dump_show(struct seq_file *m, void *v)
{
	u8 val;
	int i;

	seq_puts(m, "# ACPI EC RAM dump — offset: value (dec)\n");
	for (i = 0; i < EC_DUMP_SIZE; i++) {
		if (ec_read((u8)i, &val) != 0) {
			seq_printf(m, "0x%02X ERR\n", i);
			continue;
		}
		seq_printf(m, "0x%02X %3u\n", i, val);
	}
	return 0;
}

static int ec_dump_open(struct inode *inode, struct file *file)
{
	return single_open(file, ec_dump_show, NULL);
}

static const struct proc_ops ec_dump_ops = {
	.proc_open    = ec_dump_open,
	.proc_read    = seq_read,
	.proc_lseek   = seq_lseek,
	.proc_release = single_release,
};

static int __init ec_dump_init(void)
{
	if (!proc_create("ec_dump", 0444, NULL, &ec_dump_ops))
		return -ENOMEM;
	pr_info("ec_dump: /proc/ec_dump ready\n");
	return 0;
}

static void __exit ec_dump_exit(void)
{
	remove_proc_entry("ec_dump", NULL);
	pr_info("ec_dump: unloaded\n");
}

module_init(ec_dump_init);
module_exit(ec_dump_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Dump ACPI EC RAM to /proc/ec_dump (read-only)");
MODULE_AUTHOR("clevo-acpi-control");
