// clevo_ecmd - generic Clevo/Insyde EC mailbox (ECMD) probe
// ECMD payload layout (from DSDT Method ECMD):
//   [0]=len  [1]=flags(bit7=readback, low7=stall ms)  [2]=FCMD
//   [3]=FDAT [4]=FBUF [5]=FBF1 [6]=FBF2 [7]=FBF3
// EC registers: FCMD=0xF8 FDAT=0xF9 FBUF=0xFA FBF1=0xFB FBF2=0xFC FBF3=0xFD
// write order: FDAT..FBF3 first, FCMD last (trigger)
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/mutex.h>
#include <linux/delay.h>
#include <linux/version.h>
#include <linux/acpi.h>
extern int ec_read(u8 addr, u8 *val);
extern int ec_write(u8 addr, u8 val);

#define PROC_NAME "clevo_ecmd"
#define FCMD 0xF8
#define FDAT 0xF9
#define FBUF 0xFA
#define FBF1 0xFB
#define FBF2 0xFC
#define FBF3 0xFD

static DEFINE_MUTEX(ecmd_lock);
static struct proc_dir_entry *ecmd_entry;
static char last_result[128] = "none\n";

static int do_ecmd(u8 cmd, u8 dat, u8 buf, u8 b1, u8 b2, u8 b3, unsigned int stall_ms, u8 *out6)
{
	int i, ret = 0;
	u8 val;

	mutex_lock(&ecmd_lock);
	ec_write(FDAT, dat);
	ec_write(FBUF, buf);
	ec_write(FBF1, b1);
	ec_write(FBF2, b2);
	ec_write(FBF3, b3);
	ec_write(FCMD, cmd);          /* trigger */

	if (stall_ms)
		msleep(stall_ms);
	else
		msleep(1);

	out6[0] = cmd;
	for (i = 1; i < 6; i++) {
		if (ec_read(FCMD + i, &val)) { ret = -EIO; break; }
		out6[i] = val;
	}
	mutex_unlock(&ecmd_lock);
	return ret;
}

static ssize_t ecmd_write(struct file *f, const char __user *ubuf, size_t count, loff_t *ppos)
{
	char kb[128];
	unsigned int cmd, dat, buf, b1, b2, b3, stall = 0;
	u8 out[6];
	int n, i, off = 0;

	if (count >= sizeof(kb))
		return -EINVAL;
	if (copy_from_user(kb, ubuf, count))
		return -EFAULT;
	kb[count] = '\0';

	n = sscanf(kb, "%x %x %x %x %x %x %u", &cmd, &dat, &buf, &b1, &b2, &b3, &stall);
	if (n < 6)
		return -EINVAL;

	if (do_ecmd(cmd & 0xFF, dat & 0xFF, buf & 0xFF, b1 & 0xFF, b2 & 0xFF, b3 & 0xFF, stall, out))
		return -EIO;

	off += snprintf(last_result + off, sizeof(last_result) - off, "cmd=%02X ret:", cmd & 0xFF);
	for (i = 0; i < 6; i++)
		off += snprintf(last_result + off, sizeof(last_result) - off, " %02X", out[i]);
	snprintf(last_result + off, sizeof(last_result) - off, "\n");
	return count;
}

static ssize_t ecmd_read(struct file *f, char __user *ubuf, size_t count, loff_t *ppos)
{
	return simple_read_from_buffer(ubuf, count, ppos, last_result, strlen(last_result));
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 6, 0)
static const struct proc_ops ecmd_fops = {
	.proc_read = ecmd_read,
	.proc_write = ecmd_write,
};
#else
static const struct file_operations ecmd_fops = {
	.read = ecmd_read,
	.write = ecmd_write,
};
#endif

static int __init clevo_ecmd_init(void)
{
	ecmd_entry = proc_create(PROC_NAME, 0600, NULL, &ecmd_fops);
	if (!ecmd_entry)
		return -ENOMEM;
	pr_info("clevo_ecmd: /proc/%s ready\n", PROC_NAME);
	return 0;
}

static void __exit clevo_ecmd_exit(void)
{
	proc_remove(ecmd_entry);
}

module_init(clevo_ecmd_init);
module_exit(clevo_ecmd_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Clevo/Insyde EC mailbox (ECMD) probe");
