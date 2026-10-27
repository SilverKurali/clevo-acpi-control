#!/usr/bin/env bash
# offline-test.sh — 在 acpiexec 沙箱里验证 SCMD 调用，不碰真实硬件
#
# 原理：把本机全部 ACPI 表导出来，用 ACPICA 的解释器离线加载，
#       然后执行 ACPI 方法。全程不写任何硬件寄存器。
#
# 局限：OperationRegion 在沙箱里被模拟为全零，所以依赖固件变量的分支
#       （如 PSF4 & 0x04）在沙箱里一定为假。它只能验证：
#         · 方法是否存在、路径是否正确
#         · 参数个数与类型是否匹配
#         · 命令分派逻辑是否如预期
#       不能验证：真实固件变量的值。

set -euo pipefail

ACPI_DIR="${ACPI_DIR:-/tmp/acpidump}"
SCMD_PATH="${SCMD_PATH:-\\_SB.WMI.SCMD}"

command -v acpiexec >/dev/null || {
    echo "缺少 acpiexec。安装： sudo dnf install acpica-tools"; exit 1; }

# --- 1. 导出 ACPI 表 ---
if [ ! -f "$ACPI_DIR/dsdt.dat" ]; then
    echo "[1/3] 导出 ACPI 表 → $ACPI_DIR"
    mkdir -p "$ACPI_DIR"
    ( cd "$ACPI_DIR" && sudo acpidump -b >/dev/null 2>&1 )
else
    echo "[1/3] 复用已有 ACPI 表： $ACPI_DIR"
fi

TABLES=("$ACPI_DIR/dsdt.dat")
while IFS= read -r f; do TABLES+=("$f"); done < <(ls "$ACPI_DIR"/ssdt*.dat 2>/dev/null | sort -V)

echo "[2/3] 表数量： ${#TABLES[@]}"
echo "[3/3] 离线执行测试"
echo

run() {
    local desc="$1"; shift
    local expr="$1"; shift
    printf '  %-42s' "$desc"
    local out
    out=$(acpiexec -b "execute $expr" "${TABLES[@]}" 2>&1 \
          | grep -A2 'returned object' | grep -oE '= [0-9A-F]{16}' | head -1 || true)
    if [ -z "$out" ]; then
        echo "无法求值"
    else
        echo "$out"
    fi
}

echo "  命令号   说明"
echo "  ------   ----"
run "0x13 (EC 键盘开关)"       "$SCMD_PATH 0 0x13 0"
run "0x14 (固定返回 0x14)"     "$SCMD_PATH 0 0x14 0"
run "0x1D (固定返回 0x1D)"     "$SCMD_PATH 0 0x1D 0"
run "0x19 mode=0  (quiet)"     "$SCMD_PATH 0 0x19 0"
run "0x19 mode=1  (saving)"    "$SCMD_PATH 0 0x19 1"
run "0x19 mode=2  (performance)" "$SCMD_PATH 0 0x19 2"
run "0x19 mode=3  (entertainment)" "$SCMD_PATH 0 0x19 3"

echo
echo "说明："
echo "  · 0x14 / 0x1D 返回对应命令号 = 调用约定正确"
echo "  · 0x19 返回 FFFFFFFFFFFFFFFF = 固件能力门禁在沙箱里为假（正常现象）"
echo "  · 沙箱结果不能替代真机验证，但能排除路径写错、参数个数错这类问题"
