# 接手文档 — clevo-acpi-control

> **写于 2026-10-26 23:30，因家中断电中断。**
> 本文档自包含：读完这一份就能接着干，不需要之前的对话记录。
>
> 技术细节全在 `docs/PROTOCOL.md`（558 行），本文只讲**状态、计划、坑**。

---

## 0. 一分钟速览

| 项 | 状态 |
|---|---|
| 项目路径 | `~/下载/work/work3/clevo-acpi-control/` |
| 核心功能 | ✅ **已验证可用**（ACPI 侧） |
| 待验证 | ⏸ **插电后 GPU 功耗上限是否真的提高** |
| 机型 | COLORFUL P15 23 / BIOS `1.07.10COLO2` / i7-13620H / RTX 4060 Laptop |
| git | 已 `init` + `add`，**未 commit，未 push** |

**一句话结论：** 通过 `\_SB.WMI.SCMD 0 0x79 0x19000002` 可以把固件切到性能档，
并把 `NPCF.CTGP`（基础 TGP 授权位）从 0 翻成 1 —— 已在真机验证。
但**电池供电时 GPU 被锁在 35 W，看不出 TGP 提升，必须插电验证**。

---

## 1. 已完成并验证的事

- [x] 从 DSDT 完整逆向 Clevo/Insyde 的 `SCMD` 协议
- [x] 分析厂商驱动 `AcpiBridge.sys`（绑定 `ACPI\CLV0001`）的调用链
- [x] 编译 `acpi_call` 并适配内核 7.2（原版 2013 年代码编不过）
- [x] 真机读出一批 ACPI 变量（`PSF4` / `NTCF` / `CPCM` / `CTGP` 等）
- [x] **真机验证档位切换**：`CPCM 3→2`，`CTGP 0→1`
- [x] 工具实现：`status` / `set` / `probe`
- [x] 文档 558 行

## 2. 未验证 / 待做

- [ ] **插电时 TGP 上限是否真的提高**（最高优先级）
- [ ] 四个档位的实际功耗差异（决定 GNOME 三档映射）
- [ ] 一键安装脚本 `install.sh`
- [ ] 中文交互菜单（小白版）
- [ ] D-Bus 集成（让 GNOME 电源模式驱动固件档位）
- [ ] `LICENSE`（GPL-3.0 全文）

---

## 3. 环境状态（重要！）

### 3.1 `acpi_call` 模块（已改为 DKMS）

**2026-10-27 更新：已配置 DKMS，内核升级会自动重编。**

```
DKMS 包:  acpi_call/0.1.0
源码:     /usr/src/acpi_call-0.1.0/   （含现代内核补丁）
自动重编: /usr/lib/kernel/install.d/40-dkms.install + dkms.service
状态查询: dkms status
手动重编: sudo dkms autoinstall
```

以下为旧的手动方式，仅在 DKMS 不可用时使用：

```
源码:   /tmp/acpi_call/           ← /tmp 可能被清理，重启后大概率没了
模块:   ~/下载/work/work3/clevo-acpi-control/patches/acpi_call.ko
补丁:   ~/下载/work/work3/clevo-acpi-control/patches/acpi_call-modern-kernel.patch
```

**重启后模块不会自动加载。** 每次要用先执行：

```bash
sudo modprobe acpi_call          # 如果模块已装进系统
# 或者临时加载：
sudo insmod ~/下载/work/work3/clevo-acpi-control/patches/acpi_call.ko
```

如果 `/tmp/acpi_call` 没了，重新编译：

```bash
git clone https://github.com/mkottman/acpi_call /tmp/acpi_call
cd /tmp/acpi_call
git apply ~/下载/work/work3/clevo-acpi-control/patches/acpi_call-modern-kernel.patch
make
sudo insmod ./acpi_call.ko
```

### 3.2 我为省电而改过的系统设置（需要知悉/还原）

| 项目 | 改成 | 还原方法 |
|---|---|---|
| tuned profile | `powersave` | `sudo tuned-adm profile throughput-performance` |
| CPU 最高频率 | 1.8 GHz | `sudo cpupower frequency-set -u 4.7GHz` 或重启 |
| 屏幕亮度 | 20% | 手动调 / 重启 |
| WiFi 省电 | on | `sudo iw dev wlp0s20f3 set power_save off` |
| 文件索引器 | 已停 + masked | `systemctl --user unmask localsearch-3.service && systemctl --user start localsearch-3.service` |
| GPU 时钟 | 锁 210 MHz | `sudo nvidia-smi -rgc` |

**注意：** 直接写 sysfs 会和 `tuned` 打架（界面显示与实际不符）。
以后改电源模式一律走 `tuned-adm` 或 GNOME 界面。

---

## 4. 可直接复制的关键命令

### 4.1 读状态（只读，零风险）

```bash
sudo modprobe acpi_call
cd ~/下载/work/work3/clevo-acpi-control
sudo ./src/clevo-acpi-control status
```

### 4.2 读单个 ACPI 变量

```bash
# 注意：必须用 NUL 截断，否则 "called" 里的十六进制字符会污染数值
sudo bash -c 'echo "\_SB.PC00.LPCB.EC.CPCM" > /proc/acpi/call; cat /proc/acpi/call' \
  | tr -d '\0' | head -1
```

### 4.3 切档位

```bash
# 性能档
sudo bash -c 'echo "\_SB.WMI.SCMD 0 0x79 0x19000002" > /proc/acpi/call; cat /proc/acpi/call'
# 安静档
sudo bash -c 'echo "\_SB.WMI.SCMD 0 0x79 0x19000000" > /proc/acpi/call; cat /proc/acpi/call'
```

成功返回 `0x79`。

### 4.4 用工具切（推荐）

```bash
sudo ./src/clevo-acpi-control set performance
sudo ./src/clevo-acpi-control set quiet
sudo ./src/clevo-acpi-control set saving
sudo ./src/clevo-acpi-control set entertainment
```

---

## 5. 明天（来电后）的执行顺序

### 第 1 步：插电验证 TGP ← **决定项目生死**

```bash
sudo modprobe acpi_call
cd ~/下载/work/work3/clevo-acpi-control

# 插电状态下先看基线
nvidia-smi -q -d POWER | grep -E 'Current Power Limit|Default Power Limit|Max Power Limit'

# 切性能档
sudo ./src/clevo-acpi-control set performance
sleep 3

# 再看
nvidia-smi -q -d POWER | grep -E 'Current Power Limit|Default Power Limit|Max Power Limit'
journalctl -u nvidia-powerd -n 5
```

**判据：**

| 结果 | 含义 | 下一步 |
|---|---|---|
| `Current Power Limit` 从 85 W 涨到 105/140 W | ✅ 项目成立 | 继续第 2 步 |
| 数值不变，但 `nvidia-powerd` 的 ERROR 消失 | ⚠️ 部分生效 | 加 GPU 负载再测一次 |
| 完全不变 | ❌ 只做只读诊断工具 | 砍掉 `set` 功能，重心转文档 |

**基线数据（电池供电时）：** `Current Power Limit = 35 W`（DC 下被限制），
`Default = 85 W`，`Max = 140 W`。

### 第 2 步：实测四档差异

每个档位静置 3 分钟，记录：

```bash
# CPU 功耗上限
cat /sys/class/powercap/intel-rapl/intel-rapl:0/constraint_0_power_limit_uw
# 温度
cat /sys/class/hwmon/hwmon7/temp1_input     # coretemp package（hwmon 编号可能变）
# GPU 上限
nvidia-smi -q -d POWER | grep 'Current Power Limit'
```

做一张表，决定 GNOME 三档 → 固件四档的映射。

**用户提供的先验信息：** 在 Windows 上对比过「省电」和「安静」两档，
续航只差 2–3 分钟，但省电档会锁 60 Hz + 降亮度。
⇒ 说明 EC 的 0/1/3 三档实际功耗差异很小，**不用在这上面花太多功夫**。

**注意：** Windows 控制台锁刷新率/降亮度是**软件动作**，不是 EC 档位本身。
我们调 ACPI 只改 EC 档位，不会碰刷新率和亮度。

### 第 3 步：定映射

初步方案（等实测确认）：

```
GNOME 节能  →  安静(0)      （丢掉"省电(1)"，它是鸡肋档）
GNOME 平衡  →  娱乐(3)
GNOME 性能  →  性能(2)      ← 唯一解锁显卡 TGP 的档
```

### 第 4 步：小白版

- `install.sh` 一键安装（装模块 + 装脚本 + 装 systemd 服务 + 装桌面图标）
- 中文交互菜单：

```
  Clevo 性能控制
  ─────────────────
  当前：安静档

  1) 性能   （风扇响，显卡全开）
  2) 平衡
  3) 省电
  4) 安静   （风扇最静）

  5) 看看现在什么状态
  0) 退出

  请输入数字：
```

### 第 5 步（可选）：D-Bus 集成

监听 `net.hadess.PowerProfiles` 的 `ActiveProfile` 变化 → 同步设置 EC 档位。

**注意 Fedora 44 用的是 `tuned` + `tuned-ppd`，不是 power-profiles-daemon。**
D-Bus 接口仍是 `net.hadess.PowerProfiles`（由 `tuned-ppd` 提供）。

---

## 6. 踩过的坑（别再踩一遍）

### 6.1 `acpi_call` 在新内核上编不过

2013 年的代码，两个错：

1. `struct file_operations` → 内核 5.6+ 改成 `struct proc_ops`
   （`.read`→`.proc_read`，`.write`→`.proc_write`，去掉 `.owner`）
2. `#include <acpi/acpi.h>` → 必须改成 `<linux/acpi.h>`

补丁已保存在 `patches/acpi_call-modern-kernel.patch`。

### 6.2 `/proc/acpi/call` 的返回格式会骗人 ⚠️

格式是 `"<结果>\0called\0"`。`called` 是**上一次写入残留的字符串**。

**必须取第一个 NUL 之前的内容。** 否则：

- `0x21C` 会被读成 `0x21`（`C` 是合法十六进制，被并进去了）
- 这个错误导致我一度误判"固件门禁是关的"，白折腾了一轮

Python 正确写法：

```python
val = raw.split("\x00")[0].strip()
```

### 6.3 命令号是 `0x79`，不是 `0x19`

`0x19` 只是**子命令**，藏在扩展命令 `0x79` 的高字节：

```
ARGS = (子命令 << 24) | 数据
性能档 = (0x19 << 24) | 2 = 0x19000002
```

第一次直接调 `SCMD 0 0x19 2` 返回 `Ones`（未处理），就是这个原因。

### 6.4 `PSF4` 是 `0x21C`，门禁是**开**的

早先误读成 `0x21`，以为固件禁用了性能档。实际 `0x21C & 0x04 = 4`，门禁开着。

### 6.5 电池供电时 GPU 锁 35 W

`nvidia-smi` 在 DC 下报 `Current Power Limit = 35 W`。
`nvidia-powerd` 会打日志 `disable Dynamic Boost DC controller`（DC = 电池，正常行为）。
**TGP 相关验证必须插电做。**

### 6.6 `gpu-unlock-ada` 不建议

`JustAResearcher/gpu-unlock-ada` 对 `10de:28a0` 只有"解锁成功、性能未测"的记录；
同系 Clevo 机型（RTX 4090 Laptop）有"解锁了但零提升"的先例。
**而且这台没有核显兜底**（`lspci` 里没有 Intel 核显，eDP 内屏挂在 NVIDIA 上），
固件事务失败就是黑屏 + 必须断电。已判定不值得。

---

## 7. 关键数据速查

| 变量 | 值 | 含义 |
|---|---|---|
| `PSF4` | `0x21C` | bit 2 置位 → 性能档设置功能可用 |
| `NTCF` | `0xBB44` | 各档授权位掩码（见下） |
| `CPCM` | 当前 `0x0` | 当前固件档位 |
| `CTGP` | 当前 `0x0` | 基础 TGP 授权（切性能档后变 1） |
| `DTGP` | `0x1` | Dynamic Boost 授权 |
| `DBAC` / `DBDC` | `0x1` | DB 交流/直流 |

`NTCF = 0xBB44` 解码：

| 授权位 | 掩码 | 启用的档位 |
|---|---|---|
| `CTGP` 基础 TGP | `0x4` | 仅 performance(2) |
| `DTGP` Dynamic Boost | `0x4` | 仅 performance(2) |
| `DBAC` DB 交流 | `0xB` | quiet / saving / entertainment |
| `DBDC` DB 直流 | `0xB` | quiet / saving / entertainment |

档位编号：`0=quiet 安静`、`1=saving 省电`、`2=performance 性能`、`3=entertainment 娱乐`

---

## 8. 项目文件

```
clevo-acpi-control/
├── README.md                              项目说明
├── docs/
│   ├── PROTOCOL.md                        逆向协议全文（558 行，核心资产）
│   └── HANDOVER.md                        本文档
├── src/
│   └── clevo-acpi-control                 主工具（status / set / probe）
├── tools/
│   └── offline-test.sh                    acpiexec 离线验证（零风险）
├── systemd/
│   └── clevo-acpi-control.service         开机自动应用
├── patches/
│   ├── acpi_call-modern-kernel.patch      acpi_call 新内核适配补丁
│   └── acpi_call.ko                       已编译的模块
└── .gitignore
```

---

## 9. 关于发布到 GitHub

用户已表示"如果真的可以用就发到 GitHub"。

**当前判断：** ACPI 侧已验证可用，等插电确认 TGP 后即可发布。

发布时**必须先经用户确认**，且：
- 只能推到自己账号 `SilverKurali` 下
- **绝不向上游仓库提 PR**
- **绝不用 AI 提交 issue**

发布前补 `LICENSE`（GPL-3.0 全文）。

README 需要强调的：
1. 这是**第一份** Clevo/Insyde `SCMD` 协议公开记录（`tongfang-control` 那套是 2020 年的 `WMBC`，接口已换代）
2. `status` 命令可在动手前判断机型是否支持
3. `patches/` 里的内核适配补丁对其它人有用
