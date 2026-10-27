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

# ---------- 1. 内核模块（DKMS，内核升级自动重编） ----------
step 1 "安装 acpi_call 内核模块（DKMS）"

DKMS_VER=0.1.0
DKMS_SRC="/usr/src/acpi_call-$DKMS_VER"

if dkms status 2>/dev/null | grep -q "^acpi_call/$DKMS_VER"; then
    grn "  ✓ DKMS 已安装（acpi_call/$DKMS_VER）"
    dkms autoinstall -m acpi_call -v "$DKMS_VER" >/dev/null 2>&1 || true
else
    if ! command -v dkms >/dev/null; then
        ylw "  未安装 dkms，尝试安装..."
        if command -v dnf >/dev/null; then dnf install -y dkms >/dev/null 2>&1
        elif command -v apt-get >/dev/null; then apt-get install -y dkms >/dev/null 2>&1
        fi
    fi

    if command -v dkms >/dev/null; then
        # 准备源码：上游 acpi_call + 现代内核补丁
        BUILD=$(mktemp -d)
        if ! command -v make >/dev/null || [ ! -d "/usr/src/kernels/$(uname -r)" ]; then
            red "  ✗ 缺少编译工具，请先安装："
            echo "      sudo dnf install -y kernel-devel make gcc git dkms"
            rm -rf "$BUILD"; exit 1
        fi
        if ! git clone -q --depth 1 https://github.com/mkottman/acpi_call "$BUILD/src" 2>/dev/null; then
            red "  ✗ 无法下载 acpi_call 源码（检查网络）"
            rm -rf "$BUILD"; exit 1
        fi
        git -C "$BUILD/src" apply "$SRC_DIR/patches/acpi_call-modern-kernel.patch" 2>/dev/null || true
        cp "$SRC_DIR/kmod/Makefile.acpi_call" "$BUILD/src/Makefile"

        rm -rf "$DKMS_SRC"
        mkdir -p "$DKMS_SRC"
        cp "$BUILD/src/acpi_call.c" "$BUILD/src/Makefile" "$DKMS_SRC/"
        cp "$SRC_DIR/kmod/dkms.conf" "$DKMS_SRC/"
        rm -rf "$BUILD"

        if dkms add    -m acpi_call -v "$DKMS_VER" >/dev/null 2>&1 \
           && dkms build -m acpi_call -v "$DKMS_VER" >/dev/null 2>&1 \
           && dkms install -m acpi_call -v "$DKMS_VER" --force >/dev/null 2>&1; then
            grn "  ✓ DKMS 安装成功（内核升级会自动重编）"
        else
            red "  ✗ DKMS 构建失败。手动排查： dkms build -m acpi_call -v $DKMS_VER"
            exit 1
        fi
    else
        ylw "  dkms 不可用，回退到预编译模块"
        KO="$SRC_DIR/patches/acpi_call.ko"
        [ -f "$KO" ] || { red "  ✗ 找不到预编译模块"; exit 1; }
        install -Dm644 "$KO" "/lib/modules/$(uname -r)/extra/acpi_call.ko"
        depmod -a 2>/dev/null
        ylw "  ⚠ 此方式在内核升级后会失效，需要重新运行本脚本"
    fi
fi

# 确保已加载 + 开机自动加载
modprobe acpi_call 2>/dev/null || true
echo "acpi_call" > /etc/modules-load.d/clevo-acpi-control.conf
if [ -e /proc/acpi/call ]; then
    grn "  ✓ 模块已加载，/proc/acpi/call 就绪"
else
    red "  ✗ 模块加载失败"
    exit 1
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
