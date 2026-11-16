// SPDX-License-Identifier: GPL-2.0
/*
 * clevo_fan.c — Clevo EC 风扇转速 hwmon 驱动
 *
 * 数据来源：EC RAM 0xD0/0xD1（CPU 风扇）、0xD2/0xD3（GPU 风扇），
 * 16 位大端原始值（tach 周期计数）。换算公式取自官方
 * FanSpeedSetting.exe（.NET 3.93.0.0）Page_system_monitor.UpdateUI_CPUFan：
 *
 *     rpm = round(60.0 / (5.565217391304348e-05 * raw) * 2.0)
 *         = round(2156250 / raw)
 *
 * raw == 0 时官方程序保持上一次显示值；本驱动返回 0（风扇停转）。
 *
 * 只读，不写任何 EC 寄存器。
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/acpi.h>
#include <linux/hwmon.h>
#include <linux/hwmon-sysfs.h>
#include <linux/device.h>
#include <linux/err.h>

/* 由 drivers/acpi/ec.c 导出（EXPORT_SYMBOL），未在公共头文件声明 */
extern int ec_read(u8 addr, u8 *val);

#define EC_FAN1_HI	0xD0
#define EC_FAN2_HI	0xD2
#define FAN_STRIDE	2
#define FAN_COUNT	2

/* 标定分子：rpm = NUM / raw，NUM 可经模块参数覆盖 */
static unsigned int rpm_num = 2156250;
module_param(rpm_num, uint, 0444);
MODULE_PARM_DESC(rpm_num, "RPM = rpm_num / raw_ec_value (default 2156250)");

static const char *const fan_names[FAN_COUNT] = { "cpu", "gpu" };

/* 读 16 位大端，三次夹读防撕裂 */
static int ec_read_u16_be(u8 hi, u16 *out)
{
	u8 h, l, h2;
	int i, ret;

	for (i = 0; i < 3; i++) {
		ret = ec_read(hi, &h);
		if (ret)
			return ret;
		ret = ec_read(hi + 1, &l);
		if (ret)
			return ret;
		ret = ec_read(hi, &h2);
		if (ret)
			return ret;
		if (h == h2) {
			*out = ((u16)h << 8) | l;
			return 0;
		}
	}
	return -EIO;
}

static int clevo_fan_read(struct device *dev, enum hwmon_sensor_types type,
			  u32 attr, int channel, long *val)
{
	u16 raw;
	int ret;

	if (type != hwmon_fan || attr != hwmon_fan_input)
		return -EOPNOTSUPP;
	if (channel < 0 || channel >= FAN_COUNT)
		return -EINVAL;

	ret = ec_read_u16_be(EC_FAN1_HI + channel * FAN_STRIDE, &raw);
	if (ret)
		return ret;

	*val = raw ? DIV_ROUND_CLOSEST((u32)rpm_num, raw) : 0;
	return 0;
}

static int clevo_fan_read_string(struct device *dev,
				 enum hwmon_sensor_types type, u32 attr,
				 int channel, const char **str)
{
	if (type != hwmon_fan || attr != hwmon_fan_label)
		return -EOPNOTSUPP;
	if (channel < 0 || channel >= FAN_COUNT)
		return -EINVAL;
	*str = fan_names[channel];
	return 0;
}

static umode_t clevo_fan_is_visible(const void *data,
				    enum hwmon_sensor_types type,
				    u32 attr, int channel)
{
	if (type != hwmon_fan)
		return 0;
	if (attr == hwmon_fan_input || attr == hwmon_fan_label)
		return 0444;
	return 0;
}

static const struct hwmon_ops clevo_fan_ops = {
	.is_visible	= clevo_fan_is_visible,
	.read		= clevo_fan_read,
	.read_string	= clevo_fan_read_string,
};

static const struct hwmon_channel_info *const clevo_fan_info[] = {
	HWMON_CHANNEL_INFO(fan,
			   HWMON_F_INPUT | HWMON_F_LABEL,
			   HWMON_F_INPUT | HWMON_F_LABEL),
	NULL
};

static const struct hwmon_chip_info clevo_fan_chip = {
	.ops	= &clevo_fan_ops,
	.info	= clevo_fan_info,
};

static struct device *clevo_fan_dev;
static struct device *clevo_fan_hwmon;

static int __init clevo_fan_init(void)
{
	u8 probe;

	if (ec_read(EC_FAN1_HI, &probe) != 0)
		return -ENODEV;

	clevo_fan_dev = root_device_register("clevo_fan");
	if (IS_ERR(clevo_fan_dev))
		return PTR_ERR(clevo_fan_dev);

	clevo_fan_hwmon = hwmon_device_register_with_info(clevo_fan_dev,
							  "clevo_fan", NULL,
							  &clevo_fan_chip, NULL);
	if (IS_ERR(clevo_fan_hwmon)) {
		int ret = PTR_ERR(clevo_fan_hwmon);
		root_device_unregister(clevo_fan_dev);
		return ret;
	}

	pr_info("clevo_fan: registered hwmon (fan1=EC 0xD0, fan2=EC 0xD2, num=%u)\n",
		rpm_num);
	return 0;
}

static void __exit clevo_fan_exit(void)
{
	hwmon_device_unregister(clevo_fan_hwmon);
	root_device_unregister(clevo_fan_dev);
}

module_init(clevo_fan_init);
module_exit(clevo_fan_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Clevo EC fan RPM hwmon driver");
MODULE_AUTHOR("clevo-acpi-control");
