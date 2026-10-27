# ec_dump — ACPI EC RAM 诊断模块

> **只读。** 不写任何 EC 寄存器。

本机（COLORFUL P15 23）的**风扇转速完全没有通过 ACPI 暴露** ——
整个 DSDT 里没有任何 fan 方法，只有一个温度热区 `TZ0._TMP`。
要读风扇相关数据只能直接访问 EC 寄存器。

内核已导出 `ec_read()`（`drivers/acpi/ec.c`），所以不需要完整的 `ec_sys` 模块，
一个 ~60 行的小模块就够了。

## 编译

```bash
sudo dnf install -y kernel-devel gcc make    # 或对应发行版的包
cd kmod && make
sudo insmod ec_dump.ko
```

## 使用

```bash
sudo cat /proc/ec_dump
```

输出格式：`偏移 十进制值`，共 256 行。

```bash
# 只看某几个寄存器
sudo grep -E '^0x(C[EF]|D[013]) ' /proc/ec_dump
```

## 已知发现

在 COLORFUL P15 23 上，对比「冷机」与「16 线程满载 45 秒」两种状态：

| 寄存器 | 冷 | 热 | 变化 |
|---|---|---|---|
| `0xCE` | 138 | 204 | +66 |
| `0xCF` | 124 | 204 | +80 |
| `0xD1` | 0 | 128 | +128 |
| `0xD3` | 66 | 140 | +74 |

这四个寄存器明确随风扇/热负载变化，**但具体编码未确定**：

- `0xCE` / `0xCF` 在满载时同时饱和到 `204`（≈ 255 的 80%），
  更像两个独立的**占空比**寄存器，而不是一个 16 位 RPM 值
- `0xD1` 从 0 跳到 128，`0xD3` 从 66 到 140，含义不明

社区资料（`Cigilipuf/monster-hw-ctrl`、`YoyPa/isw`）记载 Clevo 约定
`0xCE/0xCF` = CPU 风扇 RPM、`0xD0/0xD1` = GPU 风扇 RPM，**与本机实测不符** ——
这台机器的 EC 映射与那些老款 Clevo 不同。

### 待办

要确认编码，需要：

1. 找一台能读到真实转速的机器做交叉对照，或
2. 从厂商 Windows 驱动里提取 EC 映射表，或
3. 用声学/转速计做物理测量对照

在此之前，本项目**不提供风扇转速读数**，避免给出错误数据。
