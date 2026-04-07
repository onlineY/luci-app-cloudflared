#!/bin/sh
# Cloudflared Setup Script for OpenWrt/iStoreOS
# Downloads binary, authenticates, creates tunnel

set -e

# ===== Config =====
DOWNLOAD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download"

# ===== Colors =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ===== Language detection =====
# choose Chinese when LANG starts with zh or timezone hints at China
ZH=0
case "${LANG:-}" in
    zh*|Zh*) ZH=1 ;;   # typical zh_CN.UTF-8 etc
    *)
        # fallback: look at TZ/zone name or date zone
        if [ "$(date +%Z)" = "CST" ] || echo "${TZ:-}" | grep -q -E 'Shanghai|Beijing|Chongqing|Hongkong'; then
            ZH=1
        fi
        ;;
esac

# translate helper: t <english> <chinese>
t() {
    if [ "$ZH" -eq 1 ]; then
        printf "%s" "$2"
    else
        printf "%s" "$1"
    fi
}

info()  { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; exit 1; }
step()  { printf "\n${CYAN}===== %s =====${NC}\n" "$1"; }

# ===== Step 0: Check environment =====
step "$(t "Checking environment" "检查环境")"

if [ "$(id -u)" -ne 0 ]; then
    error "$(t "Please run as root: sudo sh setup.sh" "请以 root 身份运行：sudo sh setup.sh")"
fi

printf "  %s" "$(t "Enter install path [/opt/cloudflare]: " "请输入安装路径 [/opt/cloudflare]: ")"
read -r INPUT_PATH
BASE_PATH="${INPUT_PATH:-/opt/cloudflare}"
info "$(t "Install path:" "安装路径：") $BASE_PATH"

ARCH=$(uname -m)
case "$ARCH" in
    aarch64|arm64)  BIN_NAME="cloudflared-linux-arm64"   ;;
    x86_64|amd64)   BIN_NAME="cloudflared-linux-amd64"   ;;
    armv7l|armhf)   BIN_NAME="cloudflared-linux-arm"     ;;
    i386|i686)      BIN_NAME="cloudflared-linux-386"     ;;
    mips)           BIN_NAME="cloudflared-linux-mips"    ;;
    mipsel)         BIN_NAME="cloudflared-linux-mipsle"  ;;
    *)              error "$(t "Unsupported architecture:" "不支持的架构：") $ARCH" ;;
esac

info "$(t "Architecture" "架构"): $ARCH -> $BIN_NAME"
info "$(t "Base path" "基础路径"): $BASE_PATH"

mkdir -p "$BASE_PATH"

# ===== Step 1: Download cloudflared =====
step "$(t "Step 1/3: Download cloudflared" "步骤 1/3：下载 cloudflared")"

BIN_PATH="$BASE_PATH/$BIN_NAME"

if [ -x "$BIN_PATH" ]; then
    CURRENT_VER=$("$BIN_PATH" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    info "$(t "Found existing:" "已存在：") $BIN_PATH (v${CURRENT_VER:-unknown})"
    printf "  %s" "$(t "Re-download latest? [y/N]: " "重新下载最新版本？[y/N]: ")"
    read -r answer
    case "$answer" in
        [yY]*) ;;
        *)
            info "$(t "Skipping download, using existing binary." "跳过下载，使用现有二进制。")"
            SKIP_DOWNLOAD=1
            ;;
    esac
fi

if [ -z "$SKIP_DOWNLOAD" ]; then
    info "$(t "Downloading" "正在下载") $BIN_NAME ..."

    # Try curl first, then wget
    if command -v curl >/dev/null 2>&1; then
        curl -L -o "$BIN_PATH" "$DOWNLOAD_URL/$BIN_NAME" || error "Download failed"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$BIN_PATH" "$DOWNLOAD_URL/$BIN_NAME" || error "Download failed"
    else
        error "$(t "Neither curl nor wget found. Install one first." "未找到 curl 或 wget，请先安装其中一个。")"
    fi

    chmod +x "$BIN_PATH"

    NEW_VER=$("$BIN_PATH" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    info "$(t "Installed:" "已安装：") $BIN_PATH (v${NEW_VER:-unknown})"
fi

# ===== Step 2: Authenticate (get cert.pem) =====
step "$(t "Step 2/3: Authenticate with Cloudflare" "步骤 2/3：与 Cloudflare 认证")"

CERT_PATH="$BASE_PATH/cert.pem"

if [ -f "$CERT_PATH" ]; then
    info "$(t "cert.pem already exists at" "cert.pem 已存在于") $CERT_PATH"
    printf "  %s" "$(t "Re-authenticate? [y/N]: " "重新认证？[y/N]: ")"
    read -r answer
    case "$answer" in
        [yY]*) ;;
        *)
            info "$(t "Skipping authentication." "跳过认证。")"
            SKIP_AUTH=1
            ;;
    esac
fi

if [ -z "$SKIP_AUTH" ]; then
    info "$(t "Running cloudflared login..." "正在运行 cloudflared 登录...")"
    info "$(t "A URL will appear below. Copy it and open in your browser to authorize." "下面会出现一个 URL。复制并在浏览器中打开以授权。")"
    printf "\n"

    # Run login, output goes to stderr, capture it
    "$BIN_PATH" login 2>&1 | while IFS= read -r line; do
        # Print all output so user sees the URL
        printf "  %s\n" "$line"
    done

    # After login, cert.pem is saved to ~/.cloudflared/cert.pem
    SRC_CERT=""
    for p in "$HOME/.cloudflared/cert.pem" "/root/.cloudflared/cert.pem"; do
        if [ -f "$p" ]; then
            SRC_CERT="$p"
            break
        fi
    done

    if [ -z "$SRC_CERT" ]; then
        error "$(t "cert.pem not found after login. Authentication may have failed." "登录后未找到 cert.pem。认证可能失败。")"
    fi

    if [ "$SRC_CERT" != "$CERT_PATH" ]; then
        cp "$SRC_CERT" "$CERT_PATH"
        info "$(t "Moved cert.pem:" "移动 cert.pem：") $SRC_CERT -> $CERT_PATH"
    else
        info "$(t "cert.pem already at" "cert.pem 已在") $CERT_PATH"
    fi
fi

# ===== Step 3: Create tunnel =====
step "$(t "Step 3/3: Create tunnel" "步骤 3/3：创建隧道")"

# Check if tunnel JSON already exists
EXISTING_JSON=$(find "$BASE_PATH" -maxdepth 1 -name "*.json" -type f 2>/dev/null | head -1)
if [ -n "$EXISTING_JSON" ]; then
    EXISTING_ID=$(basename "$EXISTING_JSON" .json)
    info "$(t "Tunnel JSON already exists:" "隧道 JSON 已存在：") $EXISTING_JSON"
    info "$(t "Tunnel ID:" "隧道 ID：") $EXISTING_ID"
    printf "  %s" "$(t "Create a new tunnel instead? [y/N]: " "是否创建新隧道？[y/N]: ")"
    read -r answer
    case "$answer" in
        [yY]*) ;;
        *)
            info "$(t "Skipping tunnel creation." "跳过隧道创建。")"
            SKIP_TUNNEL=1
            TUNNEL_ID="$EXISTING_ID"
            ;;
    esac
fi

if [ -z "$SKIP_TUNNEL" ]; then
    printf "  Enter tunnel name: "
    read -r TUNNEL_NAME

    if [ -z "$TUNNEL_NAME" ]; then
        error "$(t "Tunnel name cannot be empty." "隧道名称不能为空。")"
    fi

    info "$(t "Creating tunnel:" "创建隧道：") $TUNNEL_NAME"
    "$BIN_PATH" --origincert "$CERT_PATH" tunnel create "$TUNNEL_NAME" 2>&1 | while IFS= read -r line; do
        printf "  %s\n" "$line"
    done

    # cloudflared writes JSON next to cert.pem (BASE_PATH), or ~/.cloudflared/
    TUNNEL_JSON=""
    for dir in "$BASE_PATH" "$HOME/.cloudflared" "/root/.cloudflared"; do
        found=$(find "$dir" -maxdepth 1 -name "*.json" -type f 2>/dev/null | head -1)
        if [ -n "$found" ]; then
            TUNNEL_JSON="$found"
            break
        fi
    done

    if [ -z "$TUNNEL_JSON" ]; then
        error "$(t "Tunnel JSON not found after creation. Check output above." "创建后未找到隧道 JSON。请检查上方输出。")"
    fi

    TUNNEL_ID=$(basename "$TUNNEL_JSON" .json)

    # Move to BASE_PATH if not already there
    if [ "$(dirname "$TUNNEL_JSON")" != "$BASE_PATH" ]; then
        cp "$TUNNEL_JSON" "$BASE_PATH/"
        info "$(t "Moved tunnel JSON:" "移动隧道 JSON：") $TUNNEL_JSON -> $BASE_PATH/$(basename "$TUNNEL_JSON")"
    else
        info "$(t "Tunnel JSON:" "隧道 JSON：") $TUNNEL_JSON"
    fi
    info "$(t "Tunnel ID:" "隧道 ID：") $TUNNEL_ID"
fi

# ===== Done =====
step "$(t "Setup complete!" "设置完成！")"

printf "\n"
info "Files in $BASE_PATH:"
ls -la "$BASE_PATH/" 2>/dev/null | grep -v "^total" | grep -v "^d" | while IFS= read -r line; do
    printf "  %s\n" "$line"
done

printf "\n"
info "Next steps:"
printf "  1. Install the LuCI plugin (if not already):\n"
printf "     ${CYAN}opkg install luci-app-cloudflared*.ipk${NC}\n"
printf "  2. Open LuCI -> Services -> Cloudflared\n"
printf "  3. Add your ingress rules (subdomain -> IP:port)\n"
printf "  4. Click Save & Apply\n"
printf "\n"
info "Hot update (no reinstall needed):"
printf "  cloudflared-hotupdate --domain your-new-domain.com\n"
printf "  cloudflared-hotupdate   # force re-login + cert refresh only\n"
printf "\n"
