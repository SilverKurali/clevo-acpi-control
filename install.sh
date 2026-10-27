#!/usr/bin/env bash
# install.sh — 一键安装 clevo-acpi-control
#
#   sudo ./install.sh            安装
#   sudo ./install.sh --uninstall 卸载

set -uo pipefail

PREFIX=/usr/local
BINDIR="$PREFIX/bin"
MODDIR="/lib/modules/$(uname -r)/extra"
DESKTOP_DIR="/usr/share/applications"
SUDOERS_FILE="/etc/sudoers.d/clevo-acpi-control"
SYSTEMD_DIR="/etc/systemd/system"
CONF_FILE="/etc/clevo-acpi-control.conf"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_USER="${SUDO_USER:-$USER}"

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1m[%s]\033[0m %s\n' "$1" "$2"; }

[ "$(id -u)" -ne 0 ] && { red "请用 sudo 运行： sudo $0"; exit 1; }

# ─────────────────────────────── 卸载 ───────────────────────────────
if [ "${1:-}" = "--uninstall" ]; then
    step 1 "停止并移除服务"
    systemctl disable --now clevo-profile-sync 2>/dev/null
    systemctl disable --now clevo-acpi-control 2>/dev/null
    rm -f "$SYSTEMD_DIR/clevo-profile-sync.service" "$SYSTEMD_DIR/clevo-acpi-control.service"
    systemctl daemon-reload 2>/dev/null

    step 2 "移除文件"
    rm -f "$BINDIR/clevo-acpi-control" "$BINDIR/clevo" "$BINDIR/clevo-profile-sync"
    rm -f "$DESKTOP_DIR/clevo-acpi-control.desktop"
    rm -f "$SUDOERS_FILE" "$CONF_FILE"

    step 3 "卸载内核模块"
    modprobe -r acpi_call 2>/dev/null
    rm -f "$MODDIR/acpi_call.ko"
    depmod -a 2>/dev/null

    grn "✓ 已卸载。"
    echo "  注：已切换的性能档位会保持到下次重启（重启后回到固件默认）。"
    exit 0
fi

# ─────────────────────────────── 安装 ───────────────────────────────
grn "═══════════════════════════════════════════"
grn "  clevo-acpi-control 安装程序"
grn "═══════════════════════════════════════════"
echo "  当前用户：$REAL_USER"
echo "  内核版本：$(uname -r)"

# ---------- 1. 内核模块 ----------
step 1 "安装 acpi_call 内核模块"

if lsmod | grep -q '^acpi_call'; then
    grn "  ✓ 模块已加载"
else
    KO="$SRC_DIR/patches/acpi_call.ko"
    if [ -f "$KO" ] && insmod "$KO" 2>/dev/null; then
        grn "  ✓ 预编译模块加载成功"
    else
        ylw "  预编译模块与本内核不匹配，尝试重新编译..."
        BUILD=$(mktemp -d)
        if ! command -v make >/dev/null || [ ! -d "/usr/src/kernels/$(uname -r)" ]; then
            red "  ✗ 缺少编译工具。请先安装："
            echo "      sudo dnf install -y kernel-devel make gcc git"
            rm -rf "$BUILD"
            exit 1
        fi
        if ! git clone -q --depth 1 https://github.com/mkottman/acpi_call "$BUILD/src" 2>/dev/null; then
            red "  ✗ 无法下载 acpi_call 源码（检查网络）"
            rm -rf "$BUILD"; exit 1
        fi
        ( cd "$BUILD/src" \
          && git apply "$SRC_DIR/patches/acpi_call-modern-kernel.patch" \
          && make ) >/dev/null 2>&1
        if [ -f "$BUILD/src/acpi_call.ko" ] && insmod "$BUILD/src/acpi_call.ko" 2>/dev/null; then
            cp "$BUILD/src/acpi_call.ko" "$SRC_DIR/patches/acpi_call.ko"
            grn "  ✓ 编译并加载成功"
        else
            red "  ✗ 编译失败。请把上面的错误发出来。"
            rm -rf "$BUILD"; exit 1
        fi
        rm -rf "$BUILD"
    fi
fi

mkdir -p "$MODDIR"
if [ -f "$SRC_DIR/patches/acpi_call.ko" ]; then
    cp "$SRC_DIR/patches/acpi_call.ko" "$MODDIR/acpi_call.ko"
    depmod -a 2>/dev/null
    echo "acpi_call" > /etc/modules-load.d/clevo-acpi-control.conf
    grn "  ✓ 已设为开机自动加载"
fi

# ---------- 2. 主程序 ----------
step 2 "安装主程序"
install -Dm755 "$SRC_DIR/src/clevo-acpi-control" "$BINDIR/clevo-acpi-control"
install -Dm755 "$SRC_DIR/src/clevo"              "$BINDIR/clevo"
install -Dm755 "$SRC_DIR/src/clevo-profile-sync" "$BINDIR/clevo-profile-sync"
grn "  ✓ $BINDIR/clevo-acpi-control"
grn "  ✓ $BINDIR/clevo  （交互菜单 / interactive menu）"
grn "  ✓ $BINDIR/clevo-profile-sync  （桌面电源模式同步）"

# ---------- 3. 免密码 ----------
step 3 "配置免密码（只允许这两个程序）"
cat > "$SUDOERS_FILE" <<EOF
# clevo-acpi-control：只授权这两个程序，其余命令仍需密码
$REAL_USER ALL=(root) NOPASSWD: $BINDIR/clevo-acpi-control, $BINDIR/clevo
EOF
chmod 440 "$SUDOERS_FILE"
if visudo -cf "$SUDOERS_FILE" >/dev/null 2>&1; then
    grn "  ✓ 已配置（运行 clevo 不再需要输密码）"
else
    red "  ✗ sudoers 语法检查失败，已移除"
    rm -f "$SUDOERS_FILE"
fi

# ---------- 4. 桌面图标 ----------
step 4 "安装桌面图标"
install -Dm644 "$SRC_DIR/desktop/clevo-acpi-control.desktop" \
    "$DESKTOP_DIR/clevo-acpi-control.desktop"
grn "  ✓ 应用菜单里会出现「Clevo 性能控制」"

# ---------- 5. 服务 ----------
step 5 "安装 systemd 服务"
if [ ! -f "$CONF_FILE" ]; then
    install -Dm644 "$SRC_DIR/config/clevo-acpi-control.conf" "$CONF_FILE"
    grn "  ✓ 配置文件： $CONF_FILE"
else
    echo "  配置文件已存在，保留： $CONF_FILE"
fi

install -Dm644 "$SRC_DIR/systemd/clevo-profile-sync.service" \
    "$SYSTEMD_DIR/clevo-profile-sync.service"
install -Dm644 "$SRC_DIR/systemd/clevo-acpi-control.service" \
    "$SYSTEMD_DIR/clevo-acpi-control.service"
systemctl daemon-reload 2>/dev/null

grn "  ✓ clevo-profile-sync  — 跟随桌面电源模式自动切档（推荐）"
grn "  ✓ clevo-acpi-control  — 开机固定切到某个档（备用）"
echo
echo "  推荐启用「跟随桌面电源模式」："
echo "      sudo systemctl enable --now clevo-profile-sync"
echo
echo "  启用后，右上角的电源模式就同时管 CPU 和固件档位了。"
echo "  两个服务不要同时启用（会互相覆盖）。"

# ---------- 完成 ----------
echo
grn "═══════════════════════════════════════════"
grn "  安装完成"
grn "═══════════════════════════════════════════"
echo
echo "  使用方法（任选一种）："
echo
echo "    1. 应用菜单 → 「Clevo 性能控制」"
echo "    2. 终端输入： clevo"
echo "    3. 命令行：   sudo clevo-acpi-control status"
echo
echo "  当前状态："
"$BINDIR/clevo-acpi-control" status 2>/dev/null | sed 's/^/    /'
echo
