# clevo_ecmd —— 通用 Clevo/Insyde EC 邮箱探测模块

按 DSDT `Method (ECMD)` 的时序驱动 EC 邮箱，用于在 Linux 侧直接给 EC 下发固件命令。

## 寄存器与时序

| EC 地址 | 名称 |
|---|---|
| `0xF8` | `FCMD`  命令字（**最后写，写即触发**） |
| `0xF9` | `FDAT`  数据 / 16 位地址高字节 |
| `0xFA` | `FBUF`  缓冲 / 16 位地址低字节 |
| `0xFB-0xFD` | `FBF1..FBF3` |

## 用法

```bash
make
sudo insmod clevo_ecmd.ko

# FCMD FDAT FBUF FBF1 FBF2 FBF3 STALL(ms)
echo "C0 03 00 00 00 00 0" | sudo tee /proc/clevo_ecmd
cat /proc/clevo_ecmd          # cmd=C0 ret: C0 80 02 1F 32 00
```

## 已知命令字（摘自 DSDT）

- `0xB1` —— 16 位地址读，地址 = `FDAT<<8 | FBUF`，`FBF1` 为附加参数
- `0xC0` —— 按块读，`FDAT` = 块号 0-3
- `0xC1`、`0xC4`、`0xB8`、`0xCA`、`0xCB`、`0xD7` —— 见 `docs/PROTOCOL.md` §19

> 警告：这是**裸命令接口**，写错命令字可能影响风扇/电源控制。除探测外不要随意下发。
