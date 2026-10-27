# clevo-acpi-control

**中文 | [English](README.md)**


通过厂商自己的 ACPI 接口控制 **Clevo / Tongfang** 系笔记本的性能模式 —— 包括
解锁 NVIDIA 笔记本 GPU 被固件锁住的 TGP / Dynamic Boost。

不碰固件、不刷 vBIOS、不 patch 驱动。走的是 Windows 控制中心用的同一条路径。

```
sudo clevo-acpi-control status
sudo clevo-acpi-control set performance
```

---

## ⚠️ 适用机型（先看这个）

### ✅ 仅适用于：七彩虹 COLORFUL **P15 / P16（2024 款）**

| 机型 | 状态 |
|---|---|
| COLORFUL **P15**（DMI 报告 `P15 23`，BIOS `1.07.10COLO2` 2024-04-26） | ✅ **已完整实测** |
| COLORFUL **P16**（2024 款） | ⚠️ 未实测，接口大概率相同 |

### ❌ 其它机型不要用

这套 `SCMD` 接口是 Clevo/Insyde 为七彩虹定制的。**在其它机器上调用可能写坏 EC 寄存器。**

明确不适用（EC 与 ACPI 接口完全不同）：

```
MSI / ASUS / Lenovo / Dell / HP / Acer / Razer
以及其它品牌的 Clevo/Tongfang 代工机型（XMG / Monster / Eluktronics / Sager …）
```

**先检测再动手**（只读，零风险）：

```bash
sudo clevo-acpi-control status
```

如果输出里 `PSF4` 读不出来、或者没有 `\_SB.WMI.SCMD` 接口，就说明不适用。

> 工具本身也会检查 DMI 机型名，不是 P15/P16 时会警告并拒绝写入。

---

## 它解决什么问题

很多 Clevo/Tongfang 代工的笔记本（七彩虹、未来人类、XMG、Monster、Eluktronics…）
在 Windows 下用厂商控制中心切换「性能模式」时，GPU 能跑满标称 TGP
（例如 RTX 4060 Laptop 从 85 W 提到 140 W）。

**Linux 下这个模式永远是关的。** 固件里有一个授权位，只有 Windows 控制中心
才会把它置 1。后果在日志里能直接看到：

```
nvidia-powerd[921]: ERROR! Client (presumably SBIOS) has requested to
                    disable Dynamic Boost DC controller
```

`nvidia-smi -pl` 也改不了 —— 移动版 GPU 的功耗上限由 vBIOS/EC 决定，
驱动层禁止运行时修改：

```
$ sudo nvidia-smi -pl 115
Changing power management limit is not supported in current scope
```

本工具直接调用固件提供的 ACPI 方法，把那个授权位置起来。

---

## 工作原理

厂商控制中心做的事，本质上就是一次 ACPI 调用：

```
\_SB.WMI.SCMD(0, 0x19, <mode>)      # mode: 0=quiet 1=saving 2=performance 3=entertainment
```

这个方法内部会：

1. 写 EC 的当前性能模式寄存器（风扇/功耗表跟着切）
2. 通知 DPTF
3. 按 `NTCF` 位掩码逐个设置 `NPCF` 下的四个授权位：
   - `CTGP` — 基础 TGP 提升
   - `DTGP` — Dynamic Boost
   - `DBAC` / `DBDC` — DB AC / DC

完整逆向记录（ACPI 路径、命令表、位掩码布局、固件变量地址）见
**[docs/PROTOCOL.md](docs/PROTOCOL.md)**。

---

## 支持的硬件

**已验证路径（ACPI 结构层面）：**

| 机型 | BIOS | 状态 |
|---|---|---|
| COLORFUL P15 23 | Insyde `1.07.10COLO2` | 协议已提取，待真机验证 |

**理论上适用**（同一套 `SCMD` 接口的 Clevo/Tongfang 机型）：
七彩虹 / 未来人类 / XMG / Schenker / Monster / Eluktronics / Sager / Metabox /
Aftershock / MECHREVO / Avell 等 Clevo-Tongfang 代工机型。

**不适用**：MSI、ASUS、Lenovo、Dell、HP、Acer（EC 与 ACPI 接口完全不同，
**不要尝试**，写错 EC 寄存器可能损坏硬件）。

判断方法：看 DSDT 里有没有 `\_SB.WMI.SCMD` 方法。

```bash
sudo acpidump -b -o /tmp/acpi && cd /tmp/acpi
acpiexec -b "methods" *.dat | grep -i 'WMI.SCMD'
```

---

## 依赖

- `acpi_call` 内核模块

Fedora 用户可以直接用现成的 DKMS 包：
[MiMillieuh/acpi_call-fedora](https://github.com/MiMillieuh/acpi_call-fedora)

Debian/Ubuntu：

```bash
sudo apt install acpi-call-dkms
```

手动编译：

```bash
git clone https://github.com/mkottman/acpi_call
cd acpi_call && make && sudo make install
```

---

## 使用

```bash
sudo modprobe acpi_call

# 只读探测（零风险）
sudo ./src/clevo-acpi-control probe

# 查看状态
sudo ./src/clevo-acpi-control status

# 先看要执行什么，不实际执行
sudo ./src/clevo-acpi-control set performance --dry-run

# 真正切换
sudo ./src/clevo-acpi-control set performance
```

### 验证是否生效

```bash
nvidia-smi -q -d POWER | grep -A2 'Power Limit'
journalctl -u nvidia-powerd -n 5      # ERROR 那条应该消失
```

同时风扇转速应明显变化（EC 的性能模式也切了）。

### 开机自动应用

```bash
sudo install -m644 systemd/clevo-acpi-control.service /etc/systemd/system/
sudo systemctl enable --now clevo-acpi-control
```

---

## 安全说明

| 操作 | 风险 |
|---|---|
| `probe` / `status` | **零** —— 只调只读命令 |
| `set <mode>` | 低-中 —— 写 EC 寄存器并发 DPTF 通知 |

- 如果 `SCMD` 返回 `0xFFFFFFFFFFFFFFFF`，说明命令被固件跳过（通常是能力位未置），
  不会造成任何改变。
- 建议第一次执行前先跑 `probe`，确认接口可达。
- 出问题时长按电源键强制断电即可恢复（性能模式不持久化，重启回到默认）。

### 已知的坑

**不要**在没有验证的情况下调用 `MMWB`（`\_SB.DCHU.MMWB`）—— 它能写任意物理内存，
参数给错会直接锁死机器。

**不要**在非 Clevo/Tongfang 机器上尝试 —— EC 寄存器含义完全不同。

---

## 项目状态

- [x] ACPI 协议完整逆向（DSDT 逐行验证）
- [x] 厂商驱动分析（`AcpiBridge.sys` 调用链）
- [x] 离线模拟验证调用约定（`acpiexec`）
- [x] **真机验证成功：GPU 功耗上限 85 W → 115 W**
- [x] 四档实测（CPU PL1 15/15/45/90 W）
- [x] 一键安装脚本 + 中文交互菜单 + 桌面图标
- [ ] D-Bus 集成（让 GNOME 电源模式驱动固件档位）
- [ ] 风扇转速读取

### ✅ 实测结果

插电状态，执行 `clevo-acpi-control set performance`：

| 指标 | 切换前 | 切换后 |
|---|---|---|
| GPU `Current Power Limit` | **85 W** | **115 W** |
| CPU PL1 | 45 W | **90 W** |
| `CPCM`（固件档位） | `0x3` 娱乐 | `0x2` 性能 |
| `NPCF.CTGP`（TGP 授权） | `0x0` | `0x1` |

### 四档实测（插电、空载）

| 档位 | CPU PL1 | GPU 上限 |
|---|---|---|
| 安静 quiet (0) | 15 W | 85 W |
| 省电 saving (1) | 15 W | 85 W |
| 娱乐 entertainment (3) | 45 W | 85 W |
| 性能 performance (2) | **90 W** | **115 W** |

> 「安静」与「省电」功耗上限完全相同 —— 省电档没有意义，已弃用。

### 快速开始

```bash
git clone <repo> && cd clevo-acpi-control
sudo ./install.sh
```

然后：

```
应用菜单 → 「Clevo 性能控制」
```

或在终端输入 `clevo`，用数字菜单选择档位。

## 参考与致谢

- [siphomateke/tongfang-control](https://gitlab.com/siphomateke/tongfang-control) —
  同方系非官方控制中心，WMI 逆向方法论的参考
- [MiMillieuh/tongfang-laptop-linux-guide](https://github.com/MiMillieuh/tongfang-laptop-linux-guide) —
  同方系 Linux 指南
- [MiMillieuh/acpi_call-fedora](https://github.com/MiMillieuh/acpi_call-fedora) —
  Fedora 的 `acpi_call` DKMS 打包
- [tuxedocomputers/tuxedo-cc-wmi](https://github.com/tuxedocomputers/tuxedo-cc-wmi) —
  Tuxedo（Clevo/Uniwill）WMI 内核驱动
- [YoyPa/isw](https://github.com/YoyPa/isw) — Clevo EC 寄存器映射

## 许可

GPL-3.0
