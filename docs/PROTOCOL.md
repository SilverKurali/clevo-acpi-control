# Clevo / Tongfang ACPI Control Protocol

逆向自 **COLORFUL P15 23**（Clevo/Tongfang 代工，Insyde BIOS `1.07.10COLO2`，2024-04-26）
的 ACPI 接口。本文档记录从 DSDT 与厂商驱动中提取的完整调用协议。

> 所有结论均来自本机 `DSDT` 反汇编与 `ControlCenter 3.0 Driver v1.9` 安装包分析，
> 未使用任何猜测值。标注 `[已验证]` 的项已在本机确认。

---

## 1. 硬件与固件标识

| 项目 | 值 |
|---|---|
| 机型 | COLORFUL P15 23 |
| BIOS | INSYDE Corp. `1.07.10COLO2`（2024-04-26） |
| CPU | Intel Core i7-13620H（Raptor Lake-P，CPUID `0xB06A2`） |
| dGPU | NVIDIA RTX 4060 Laptop（`10de:28a0`，AD107M） |
| 厂商 ACPI HID | `CLV0001`（DCHU）、`CLV0002`（DCHP） |
| WMI 设备 | `PNP0C14` ×2（`\_SB.WMI`、`\_SB.DCHU` 之外） |

---

## 2. 两个 ACPI 入口

### 2.1 设备 `\_SB.WMI`（`PNP0C14`, `_UID = 0`）

`_WDG` 中的三个厂商 GUID：

| GUID | Object ID | Instance |
|---|---|---|
| `ABBC0F6D-8EA1-11D1-00A0-C90629100000` | `0x4242` | 0x01 |
| `ABBC0F6B-8EA1-11D1-00A0-C90629100000` | `0x00D0` | 0x01 |
| `ABBC0F6C-8EA1-11D1-00A0-C90629100000` | `0x00D1` | 0x01 |

方法：

| 方法 | 参数 | 说明 |
|---|---|---|
| `SCMD` | 3 | **Set Command**，命令分派器 |
| `GCMD` | 3 | **Get Command**，读取分派器 |
| `WMBB` | 3 | WMI 入口，转发到 `SCMD` / `GCMD` |

### 2.2 设备 `\_SB.DCHU`（`CLV0001`, `_UID = 1`）

| 方法 | 参数 | 说明 |
|---|---|---|
| `_DSM` | 4 | **Windows 驱动主入口** |
| `SCMD` | 3 | 同 `\_SB.WMI.SCMD`，独立副本 |
| `CC30` | 3 | "Control Center 3.0" 分派器 |
| `PK04`/`PK07`/`PK0C`/`PK0D`/`PK0E`/`PK11` | 3 | EC 命令封装 |
| `MMWB` | 3 | **任意物理内存写**（见 §6） |
| `GHPI`/`PSTG`/`PSLD` | 0/0/1 | 转发到 `\_SB.WMI` |

`_DSM` 的 UUID：**`93f224e4-fbdc-4bbf-add6-db71bdc0afad`**

`_DSM` 按 `Arg2`（功能号）分派：

| Arg2 | 目标 |
|---|---|
| `0x02` | `CPKG()` |
| `0x03` | `OCWR()` |
| `0x04, 0x07, 0x0C, 0x0D, 0x0E, 0x11` | `CC30()` |
| 35 个 id（`0x01,0x05,0x06,0x08,0x09,0x0A,0x10,0x12,0x32…0x7A`） | `GCMD()` |
| 39 个 id（`0x13,0x14,0x1D,0x1F,0x20,0x21,0x22,0x26,0x27,0x2A,0x2C,0x31,0x46…0x79`） | `SCMD()` |

> ⚠️ **`_DSM` 的分派表里没有 `0x19`**，`WMBB` 的分派表里也没有。
> 因此性能模式必须**直接调用 `SCMD`**，不能走 `_DSM` 或 `WMBB`。

---

## 3. `SCMD` 的调用约定 `[已验证]`

```asl
Method (SCMD, 3, Serialized)
{
    Name (ARGS, Zero)
    If (SizeOf (Arg2)) { ARGS = Arg2 }     // ← Arg2 直接取整数，不需要 Package
    Local0 = Zero
    If ((ToInteger (Arg1) == 0x13)) { ... Return (Local0) }
    If ((ToInteger (Arg1) == 0x14)) { Local0 = 0x14 ; Return (Local0) }
    ...
    Return (Ones)                          // 未匹配的命令返回 0xFFFFFFFFFFFFFFFF
}
```

- `Arg0` — 实例号，实测传 `0` 即可
- `Arg1` — **命令号**（如 `0x19`）
- `Arg2` — 数据（整数）

离线验证（`acpiexec`）：

| 调用 | 返回 | 结论 |
|---|---|---|
| `\_SB.WMI.SCMD 0 0x13 0` | `0x13` | ✅ |
| `\_SB.WMI.SCMD 0 0x14 0` | `0x14` | ✅ |
| `\_SB.WMI.SCMD 0 0x1D 0` | `0x1D` | ✅ |

---

## 4. 命令 `0x19` — 设置性能模式

```asl
Case (0x19)
{
    If ((PSF4 & 0x04))                       // ← 固件能力门禁
    {
        Local2 = (Local2 & 0x3F)
        If ((Local2 < 0x04))                 // ← 模式值只能是 0..3
        {
            Local3 = Local2

            ^^PC00.LPCB.EC.CPCM = Local2     // ① 写 EC 当前性能模式
            ^^PC00.LPCB.EC.ECMD (Local5)     // ② 下发风扇/功耗表
            PRM0 = 0x11 ; PRM1 = Local2
            SSMP = 0xC0                      // ③ 通知 DPTF

            // ④ 按 NTCF 的四个半字节位掩码设置 NPCF 授权位
            ^^NPCF.CTGP = One/Zero           //   基础 TGP 提升
            ^^NPCF.DTGP = One/Zero           //   Dynamic Boost
            ^^NPCF.DBAC = One/Zero           //   DB AC
            ^^NPCF.DBDC = One/Zero           //   DB DC
            Notify (NPCF, 0xC0)
        }
    }
}
```

### 4.1 模式编号

从各模式使用的参数后缀（`AMA?`/`ACB?`/`DTP?`）反推：

| 值 | 后缀 | 模式 | EC 值（`APPM`） |
|---|---|---|---|
| `0` | `Q` | **Quiet 安静** | `0x02` |
| `1` | `S` | **Saving 省电** | `0x03` |
| `2` | `P` | **Performance 性能** | `0x01` |
| `3` | `E` | **Entertainment 娱乐** | `0x00` |

`APPM` 原始定义：

```asl
Name (APPM, Buffer (0x04) { 0x02, 0x03, 0x01, 0x00 })
```

### 4.2 `NTCF` 位掩码

```asl
Local5 = ((One << Local3) &  NTCF        & 0x0F)   → CTGP
Local6 = ((One << Local3) & (NTCF >> 4)  & 0x0F)   → DTGP
Local7 = ((One << Local3) & (NTCF >> 8)  & 0x0F)   → DBAC
Local4 = ((One << Local3) & (NTCF >> 12) & 0x0F)   → DBDC
```

`NTCF` 是 16 位值，四个半字节分别是四类授权位在四种模式下的**位图**：

```
NTCF = [DBDC 半字节][DBAC 半字节][DTGP 半字节][CTGP 半字节]
         bits 12-15   bits 8-11    bits 4-7     bits 0-3
```

每一位对应一种模式（bit0=mode0 … bit3=mode3）。
`NTCF` 位于 `\_SB.PC00.PEG1.PEGP.NTCF`，是 `FieldUnitObj`。

---

## 5. 关键固件变量位置

### 5.1 `PSF4` — 性能模式能力门禁

```asl
OperationRegion (OGNS, SystemMemory, 0x37DD7018, 0x00000386)
Field (OGNS, AnyAcc, Lock, Preserve)
{
    PSF0, 32,   // +0x00
    PSF1, 32,   // +0x04
    PSF2, 32,   // +0x08
    PSF3, 32,   // +0x0C
    PSF4, 32,   // +0x10  →  物理地址 0x37DD7028
    PSF5, 32,
    PSF6, 32,
    ...
}
```

**`PSF4` 的物理地址 = `0x37DD7028`。**

判定条件：`PSF4 & 0x04` 必须为真，否则 `Case (0x19)` 整个块被跳过（`SCMD` 返回 `Ones`）。

> 该地址在不同 BIOS 版本上可能不同 —— 使用前请从本机 DSDT 重新提取。

### 5.2 读取 `PSF4` 的命令

`\_SB.WMI.GCMD` 命令 `0x60` 返回 `PSF4`（含 EC 状态修正）：

```asl
If ((ToInteger (Arg1) == 0x60))
{
    Local0 = PSF4
    If (^^PC00.LPCB.EC.ECOK)
    {
        If (((PSF6 & 0x0F) && (^^PC00.LPCB.EC.RINF & 0x10)))
        {
            Local0 |= 0x10
        }
    }
    Return (Local0)
}
```

其它已知只读命令：

| 命令 | 方法 | 返回 |
|---|---|---|
| `0x52` | `GCMD` | `PSF1` |
| `0x60` | `GCMD` | `PSF4` |
| `0x7A` | `GCMD` | `PSF2` 的掩码 + 能力位 |

---

## 6. `MMWB` — 任意物理内存写

```asl
Method (MMWB, 3, NotSerialized)
{
    OperationRegion (MWVL, SystemMemory, Arg0, One)
    Field (MWVL, ByteAcc, NoLock, Preserve) { TEMP, 8 }
    TEMP = ((TEMP & Arg2) | Arg1)      // mem[Arg0] = (mem[Arg0] & Arg2) | Arg1
}
```

参数全为整数，`acpi_call` 可直接调用。**这是厂商驱动用来直接改写 MMIO 的原语**。
本项目**不使用**它 —— 风险过高，且 `SCMD` 已足够。

---

## 7. 厂商驱动分析

`ControlCenter 3.0 Driver v1.9`（Package v6.052）

| 文件 | 说明 |
|---|---|
| `AcpiBridge.sys` | KMDF 驱动，绑定 `ACPI\CLV0001` |
| `AcpiBridge1.sys` | 同上（第二份） |
| `HKKbdFltr.sys` / `HKMouFltr.sys` | Fn 键过滤驱动 |
| `HKClipSvc.exe` / `HKFltrInstaller.exe` | 热键服务 |
| `DCHUService.exe` | Insyde UEFI 更新服务 |
| `LaunchFnkey.exe` / `AddFn.exe` | Fn 键辅助 |

驱动信息：

```
CompanyName   : Insyde Software Corporation
FileVersion   : 1.0.0.7
OEM           : CLEVO CO
PDB 路径      : C:\Emmett\Clevo\acpi-bridge-driver\x64\Release\AcpiBridge.pdb
设备接口 GUID : {86994c74-ad43-4812-b7e7-0c420b5c5fd7}
需要能力      : Clevo.* (DEVPKEY_DeviceInterface_UnrestrictedAppCapabilities)
```

调用链：

```
Control Center UI
  → DeviceIoControl({86994c74-...})
  → AcpiBridge.sys（绑定 ACPI\CLV0001）
  → \_SB.DCHU._DSM(UUID 93f224e4-..., rev, func, data)
  → SCMD / GCMD / CC30
  → EC + NPCF
```

---

## 8. Linux 侧现状

| 项目 | 状态 |
|---|---|
| `CLV0001:00` / `CLV0002:00` | ✅ 存在于 `/sys/bus/acpi/devices/` |
| `NVDA0820:00`（= `\_SB.NPCF`） | ✅ 存在，无驱动绑定 |
| WMI 设备 | ✅ 4 个，其中 3 个为厂商 GUID |
| `nvidia-powerd` | ✅ 运行中，但报错（见下） |
| `ec_sys` 模块 | ❌ 内核未提供 |
| `acpi_call` | ❌ Fedora 仓库无，需自建（见 `MiMillieuh/acpi_call-fedora`） |

### `nvidia-powerd` 的关键报错

```
nvidia-powerd[921]: ERROR! Client (presumably SBIOS) has requested to
                    disable Dynamic Boost DC controller
```

这正是 `NPCF.CTGP/DTGP` 未置位的直接后果 —— SBIOS 主动关闭 Dynamic Boost，
GPU 因此锁在基础 TGP 85 W，拿不到规格书标称的 140 W。

---

## 9. GPU 可调能力（本机实测）

| 能力 | 命令 | 结果 |
|---|---|---|
| 功耗上限 | `nvidia-smi -pl` | ❌ `not supported in current scope` |
| 频率锁定 | `nvidia-smi -lgc` | ✅ 可用 |
| 频率解锁 | `nvidia-smi -rgc` | ✅ 可用 |
| 持久模式 | `nvidia-smi -pm` | ✅ 可用 |
| 应用时钟 | `nvidia-smi -ac` | ⚠️ 已废弃 |

```
Current Power Limit : 85 W
Default Power Limit : 85 W
Min / Max           : 5 W / 140 W   （Max 仅为 vBIOS 上报范围，驱动不允许修改）
频率上限            : 图形 3105 MHz / 显存 8001 MHz
```

---

## 10. 待验证项

| 项 | 方法 | 风险 |
|---|---|---|
| `PSF4 & 0x04` 是否为真 | `GCMD 0 0x60 0` 读取 | 零（只读） |
| `NTCF` 性能模式半字节是否置了 CTGP/DTGP | 读取 `PEGP.NTCF` | 零（只读） |
| `SCMD 0 0x19 2` 实际效果 | 真机调用 | 中（写 EC + Notify） |

---

## 参考

- `siphomateke/tongfang-control` — 同方系非官方控制中心（GK5CP0Z 时代，方法论参考）
- `MiMillieuh/tongfang-laptop-linux-guide` — 同方系 Linux 指南（`acpi_call` 用法）
- `MiMillieuh/acpi_call-fedora` — Fedora 的 `acpi_call` DKMS 包
- `tuxedocomputers/tuxedo-cc-wmi` — Tuxedo（Clevo/Uniwill）WMI 内核驱动
- `YoyPa/isw` — Clevo EC 寄存器映射参考

---

## 11. 真机验证结果（2026-10-26）

在本机（COLORFUL P15 23，BIOS `1.07.10COLO2`）上通过 `acpi_call` 实测：

| 探测 | 命令 | 返回 | 结论 |
|---|---|---|---|
| 接口连通 | `\_SB.WMI.SCMD 0 0x14 0` | `0x14` | ✅ 调用约定正确 |
| PSF1 | `\_SB.WMI.GCMD 0 0x52 0` | `0x4680025` | ✅ 区域读取正常 |
| **PSF4** | `\_SB.WMI.GCMD 0 0x60 0` | **`0x21`** | ⚠️ **bit 2 (0x04) 未置位** |
| PSF2 掩码 | `\_SB.WMI.GCMD 0 0x7A 0` | `0x70020053` | ✅ |
| SCMD 0x13 | `\_SB.WMI.SCMD 0 0x13 0` | `0x13` | ✅ |

### 11.1 结论：`SCMD 0x19` 在本固件上被禁用

`PSF4 = 0x00000021` = `0b0010_0001` → **`PSF4 & 0x04 == 0`**。

`Case (0x19)` 的整个主体包在 `If ((PSF4 & 0x04))` 里，因此该命令在本机
**被固件直接跳过**，调用会返回 `Ones` 且不产生任何效果。

### 11.2 `NPCF` 授权位无第二条写入路径

全 DSDT 范围内，`NPCF.CTGP` / `DTGP` / `DBAC` / `DBDC` 的写入点只有两处：

```
97604-97626    \_SB.WMI.SCMD   Case (0x19)
107325-107356  \_SB.DCHU.SCMD  Case (0x19)
```

两处均受 `PSF4 & 0x04` 守卫。**没有其它方法能设置这些位。**

⇒ **GPU TGP 解锁（85 W → 140 W）在本机固件层面不可行。**
这不是工具能力问题，是 BIOS 没有启用该功能。

### 11.3 但风扇/性能档仍可通过 Fn+ESC 控制

`EC.CPCM`（当前性能档寄存器）的写入点共有 6 处：

| 行 | 所属方法 | 说明 |
|---|---|---|
| 30424 | `\_SB.PC00.LPCB.EC._WAK` | 唤醒时恢复 |
| 100050 | `\_SB.PC00.LPCB.EC._REG` | 区域可用时恢复 |
| **100975** | **`\_SB.PC00.LPCB.EC._Q46`** | **EC 查询 0x46 → 热键** |
| **101495** | **`\_SB.PC00.LPCB.EC._Q5D`** | **EC 查询 0x5D → 热键** |
| 97477 | `\_SB.WMI.SCMD` Case(0x19) | 被 PSF4 门禁挡住 |
| 107196 | `\_SB.DCHU.SCMD` Case(0x19) | 被 PSF4 门禁挡住 |

`_Q46` / `_Q5D` 是 EC 查询方法，由 EC 在检测到热键时触发 —— 即 **Fn+ESC**。
这条路径完全在 ACPI 内部完成，**不依赖任何操作系统驱动**。

⇒ **在 Linux 下按 Fn+ESC 应该能直接切换风扇/性能档**，无需任何工具。
   值得实测确认（监听 `acpi_listen` 或 `journalctl -k -f` 后按 Fn+ESC）。

`ECPM` 模式映射表：

```asl
Name (ECPM, Buffer (0x05) { 0x03, 0x02, 0x00, 0x01, 0x02 })
```

`APPM`（SCMD 0x19 使用）：

```asl
Name (APPM, Buffer (0x04) { 0x02, 0x03, 0x01, 0x00 })
```

### 11.4 对项目的影响

原计划的核心功能（TGP 解锁）在本机不可用。项目定位调整为：

1. **诊断工具** —— 检测 `PSF4 & 0x04`，告诉用户其机型是否支持 TGP 解锁
2. **风扇/性能档控制** —— 走可用的路径（EC 查询或 `_DSM`→`CC30`→`PK0x`）
3. **协议文档** —— 本文档本身对同系列机型有参考价值

`status` 命令的 `PSF4` 检测是核心价值：**让其他用户在动手前就知道自己的机器支不支持。**

---

## 12. `PSF4 & 0x04` 是整组特性的总开关

本机 `PSF4 = 0x21`（bit 2 未置位）时，以下三处全部失效：

| 位置 | 方法 | 被门禁包裹的内容 |
|---|---|---|
| 97450 | `\_SB.WMI.SCMD` `Case (0x19)` | 写 `EC.CPCM` + 设置 `NPCF.CTGP/DTGP/DBAC/DBDC` |
| 107169 | `\_SB.DCHU.SCMD` `Case (0x19)` | 同上（独立副本） |
| **101463** | **`\_SB.PC00.LPCB.EC._Q5D`** | **EC 查询处理（疑似 Fn+ESC 热键）** |

`_Q5D` 的结构：

```asl
Method (_Q5D, 0, NotSerialized)
{
    P80B = 0x5D
    If ((PSF4 & 0x04))                    // ← 同一道门禁
    {
        If ((^^^^WMI.HKDR || ^^^^DCHU.HKDR))
        {
            NEVT (0x59, 0x59)             // 有监听者 → 发事件
        }
        Else
        {
            Local5 = ECMD (Buffer { 0x02, 0x80, 0xD8, 0x00, ... })
            Local1 = DerefOf (Local5 [0x02])
            If ((Local1 == One)) { Local1 = Zero } Else { Local1 = One }
            Local5 = Buffer { 0x03, 0x00, 0xD8, 0x01, ... }
            Local5 [0x04] = Local1
            ECMD (Local5)                 // 翻转某个 EC 状态位
        }
    }
}
```

⇒ **在 `PSF4` bit 2 未置位的机器上，Fn+ESC 大概率也不产生任何效果。**
   （待实测确认：按 Fn+ESC 后观察 `journalctl -k` 是否出现 `P80B`/`_Q5D` 相关记录）

---

## 13. 当前性能档的读取方式（未解决）

`EC.CPCM` 是当前性能档寄存器，但**没有任何 ACPI 方法直接返回它**。
DSDT 中 `CPCM` 的读取点仅两处内部使用：

```
94799   Local6 = ((UCTB >> CPCM) & One)          // 位运算
95167   ABLI (EC.BRS0 & 0xFF, EC.CPCM)           // 电池相关计算
```

写入点 6 处（见 §11.3）。

**要显示当前模式，必须直接读 EC 寄存器。** 需要：

1. `EC.CPCM` 在 EC RAM 中的字节偏移 —— **本 DSDT 中未找到字段声明**，
   可能在某个 SSDT 中，或通过 `External` 引用。待查。
2. EC 访问通道 —— 内核未提供 `ec_sys` 模块。可选：
   - 自行编译 `drivers/acpi/ec_sys.c`
   - 写一个最小模块调用内核导出的 `ec_read(addr, &val)`
   - `_DSM` → `CC30` → `PK0x` 走 EC 命令读（buffer 参数，acpi_call 需传字符串）

> 这决定了项目能否提供「当前模式」反馈。没有反馈的 Fn+ESC 切换是盲操作，
> 用户无法判断自己处在哪一档 —— 这是必须解决的问题，否则功能价值有限。

---

## 14. 下一步（按优先级）

1. 在 SSDT 中定位 `EC.CPCM` 的寄存器偏移
2. 实现 EC 读取（最小内核模块或 `ec_sys`）
3. 实测 Fn+ESC 是否触发 `_Q5D`（监听内核日志）
4. 若 `PSF4` bit 2 在其它 BIOS 版本上为 1，则本项目核心功能可用 ——
   `status` 命令已能检测该位，可作为机型兼容性判据

---

## 15. ✅ 真机验证成功（2026-10-26 23:2x）

### 15.1 修正：真正的命令号是 `0x79`，不是 `0x19`

`0x19` 是**子命令**，藏在扩展命令 `0x79` 的高字节里：

```asl
If ((ToInteger (Arg1) == 0x79))
{
    Local1 = ((ARGS & 0xFF000000) >> 0x18)    // 子命令
    Local2 = (ARGS & 0x00FFFFFF)              // 数据
    Local0 = 0x79
    Switch (ToInteger (Local1))
    {
        Case (0x19) { /* 性能模式 */ }
        ...
    }
}
```

**参数编码：** `ARGS = (子命令 << 24) | 数据`

| 操作 | 调用 |
|---|---|
| 设为性能档 (mode 2) | `\_SB.WMI.SCMD 0 0x79 0x19000002` |
| 设为安静档 (mode 0) | `\_SB.WMI.SCMD 0 0x79 0x19000000` |

成功时返回 `0x79`。

### 15.2 修正：`PSF4 = 0x21C`，门禁是**开**的

早先读到 `0x21` 是解析错误 —— `/proc/acpi/call` 的返回格式是

```
"<结果>\0called\0"
```

`called` 是上一次写入残留的字符串。若用文本工具处理，`called` 里的 `c`/`a`/`e`/`d`
都是合法十六进制字符，会被误并入数值（`0x21c` → `0x21`）。

**正确解析：取第一个 NUL 之前的内容。**

`PSF4 = 0x21C` = `0b0010_0001_1100` → **bit 2 置位，`Case (0x19)` 可执行。**

### 15.3 实测结果

| 时刻 | CPCM | CTGP | DTGP |
|---|---|---|---|
| 切换前（娱乐档） | `0x3` | **`0x0`** | `0x1` |
| `SCMD 0 0x79 0x19000002` 后 | **`0x2`** | **`0x1`** | `0x1` |
| `SCMD 0 0x79 0x19000000` 后 | `0x0` | `0x0` | `0x1` |

**`NPCF.CTGP` 从 0 变为 1 —— 基础 TGP 提升授权成功。**

### 15.4 `NTCF = 0xBB44` 解码

| 授权位 | 掩码 | 启用的档位 |
|---|---|---|
| `CTGP` 基础 TGP | `0x4` | 仅 performance (2) |
| `DTGP` Dynamic Boost | `0x4` | 仅 performance (2) |
| `DBAC` DB 交流 | `0xB` | quiet / saving / entertainment |
| `DBDC` DB 直流 | `0xB` | quiet / saving / entertainment |

⇒ **只有"性能档"会解锁 GPU 的 TGP 提升与 Dynamic Boost。**

### 15.5 待验证

- TGP 实际数值变化（`nvidia-smi -q -d POWER`）需要 GPU 负载才能观察
- `nvidia-powerd` 的 `ERROR! ... disable Dynamic Boost DC controller`
  是开机时打的日志，切换后需重启该服务才会重新评估
- 电池供电下性能档会显著增加功耗（实测切换+验证期间掉电 18%）

---

## 16. ✅ 插电验证成功 + 四档实测数据（2026-10-27 12:3x）

### 16.1 TGP 提升已验证

**插电状态**下执行 `SCMD 0 0x79 0x19000002`（性能档）：

| 指标 | 切换前 | 切换后 |
|---|---|---|
| `Current Power Limit` | **85 W** | **115 W** |
| `CPCM` | `0x3` | `0x2` |
| `NPCF.CTGP` | `0x0` | `0x1` |
| `NPCF.DTGP` | `0x1` | `0x1` |

⇒ **GPU 功耗上限提升 +35%，项目核心功能完全验证通过。**

电池供电时 `Current Power Limit` 恒为 35 W（DC 限制），TGP 验证必须插电。

### 16.2 四档实测（插电、空载、各静置 3 秒）

| 档位 | CPCM | **CPU PL1** | GPU 上限 | 包温 |
|---|---|---|---|---|
| 安静 quiet | `0x0` | **15 W** | 85 W | 44 °C |
| 省电 saving | `0x1` | **15 W** | 85 W | 43 °C |
| 娱乐 entertainment | `0x3` | **45 W** | 85 W | 44 °C |
| 性能 performance | `0x2` | **90 W** | **115 W** | 43 °C |

**关键发现：**

1. **「安静」与「省电」的 CPU 功耗上限完全相同（都是 15 W）** —— 两个档位实际等价。
   这印证了用户在 Windows 上的观察：省电档相对安静档只多撑 2–3 分钟，
   代价却是锁 60 Hz + 降亮度。**该档位应弃用。**

2. **「娱乐」是真正的中间档（45 W）** —— 适合做「平衡」。

3. **「性能」是唯一同时提升 CPU（90 W）和 GPU（115 W）的档位。**

### 16.3 最终 GNOME 三档映射

| GNOME 电源模式 | 固件档位 | CPU PL1 | GPU 上限 |
|---|---|---|---|
| 节能 Power Saver | **安静 quiet (0)** | 15 W | 85 W |
| 平衡 Balanced | **娱乐 entertainment (3)** | 45 W | 85 W |
| 性能 Performance | **性能 performance (2)** | 90 W | 115 W |

`省电 saving (1)` 弃用（与安静等价），仅保留给命令行手动调用。

### 16.4 附注

- `nvidia-powerd` 的 `ERROR! ... disable Dynamic Boost DC controller`
  是**开机时**打的日志（DC = 电池），插电后不影响；该服务不会重新评估。
- 切换后无需重启任何服务，`nvidia-smi` 立即反映新的 `Current Power Limit`。
