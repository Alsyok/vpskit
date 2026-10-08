#!/bin/bash

# ⚠️ 免责声明：
# 本脚本仅供学习与技术研究使用。
# 使用本脚本造成的任何后果（包括但不限于法律风险、服务器封禁、
# 网络中断、数据丢失等）均由使用者自行承担。
# 请确保你的使用行为符合当地法律法规。

# 来源：https://github.com/hooghub/singboxversion/blob/main/sbinstall.sh
# 本版本仅扩展国家查询与节点文件后台同步，保留原证书和核心下载流程。
# Sing-box 一键部署脚本
# 完整修正版
#
# 特性：
# - IPv4 / IPv6 双栈
# - IPv6-only 友好
# - sing-box 安装：官方 deb-install.sh -> 官方 release 多源 -> raw 备用
# - acme.sh：官方 archive -> 自有镜像
# - Let's Encrypt / 自签证书
# - VLESS-TLS
# - VLESS-REALITY
# - Hysteria2
# - 自动生成节点 URI
# - 自动生成二维码
# - 自动生成订阅文件
#
# 支持模式：
# 1) 域名 + Let's Encrypt
# 2) 公网 IP + 自签固定域名 kyn.com
#
# 注意：
# - 模式2自签：
#   VLESS-TLS 使用 allowInsecure=1
#   Hysteria2 使用 insecure=1
# - IPv6-only 客户端必须具备 IPv6 网络

set -euo pipefail
[ -x /usr/local/lib/argo-node-files/run ] || { echo "请通过完整 VPSKit 安装入口运行。" >&2; exit 1; }

log() {
  echo -e "$*"
}

echo "=================== Sing-box 部署前环境检查 ==================="

# ============================================================
# 检查 root
# ============================================================

if [[ ${EUID:-1} -ne 0 ]]; then
  log "[✖] 请用 root 权限运行"
  exit 1
fi

log "[✔] Root 权限 OK"

# ============================================================
# 检测公网 IPv4
# ============================================================

SERVER_IPV4="$(
  curl -4 -s --max-time 3 ipv4.icanhazip.com 2>/dev/null ||
  curl -4 -s --max-time 3 ifconfig.me 2>/dev/null ||
  true
)"

# ============================================================
# 检测公网 IPv6
# ============================================================

SERVER_IPV6=""

if curl -6 -s --max-time 3 ipv6.icanhazip.com >/tmp/ipv6 2>/dev/null; then
  SERVER_IPV6="$(cat /tmp/ipv6)"
elif curl -6 -s --max-time 3 ifconfig.me >/tmp/ipv6 2>/dev/null; then
  SERVER_IPV6="$(cat /tmp/ipv6)"
fi

rm -f /tmp/ipv6 2>/dev/null || true

if [[ -n "$SERVER_IPV4" ]]; then
  echo "[✔] 检测到公网 IPv4: $SERVER_IPV4"
else
  echo "[✖] 未检测到公网 IPv4"
fi

if [[ -n "$SERVER_IPV6" ]]; then
  echo "[✔] 检测到公网 IPv6: $SERVER_IPV6"
else
  echo "[!] 未检测到公网 IPv6（可忽略）"
fi

# ============================================================
# 自动安装依赖
# ============================================================

REQUIRED_CMDS=(
  python3
  curl
  ss
  openssl
  dig
  systemctl
  bash
  socat
  cron
  ufw
  qrencode
  tar
)

PKG_MGR=""

if command -v apt-get >/dev/null 2>&1; then
  PKG_MGR="apt"
elif command -v dnf >/dev/null 2>&1; then
  PKG_MGR="dnf"
elif command -v yum >/dev/null 2>&1; then
  PKG_MGR="yum"
else
  log "[✖] 未找到支持的包管理器（apt/yum/dnf）"
  exit 1
fi

MISSING_CMDS=()

for cmd in "${REQUIRED_CMDS[@]}"; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING_CMDS+=("$cmd")
done

if [[ ${#MISSING_CMDS[@]} -gt 0 ]]; then

  log "[!] 检测到缺失命令: ${MISSING_CMDS[*]}"
  log "[!] 使用包管理器: $PKG_MGR"
  log "[!] 自动安装依赖中..."

  declare -A PKGS=()

  add_pkg() {
    PKGS["$1"]=1
  }

  for cmd in "${MISSING_CMDS[@]}"; do

    case "$PKG_MGR" in

      apt)
        case "$cmd" in
          dig)
            add_pkg "dnsutils"
            ;;
          ss)
            add_pkg "iproute2"
            ;;
          cron)
            add_pkg "cron"
            ;;
          qrencode)
            add_pkg "qrencode"
            ;;
          *)
            add_pkg "$cmd"
            ;;
        esac
        ;;

      yum|dnf)
        case "$cmd" in
          dig)
            add_pkg "bind-utils"
            ;;
          ss)
            add_pkg "iproute"
            ;;
          cron)
            add_pkg "cronie"
            ;;
          *)
            add_pkg "$cmd"
            ;;
        esac
        ;;

    esac

  done

  INSTALL_PACKAGES=()

  for pkg in "${!PKGS[@]}"; do
    INSTALL_PACKAGES+=("$pkg")
  done

  case "$PKG_MGR" in

    apt)
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive \
        apt-get install -y "${INSTALL_PACKAGES[@]}"
      ;;

    dnf)
      dnf -y makecache
      dnf -y install "${INSTALL_PACKAGES[@]}"
      ;;

    yum)
      yum -y makecache
      yum -y install "${INSTALL_PACKAGES[@]}"
      ;;

  esac

  POST_MISSING=()

  for cmd in "${REQUIRED_CMDS[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 ||
      POST_MISSING+=("$cmd")
  done

  if [[ ${#POST_MISSING[@]} -gt 0 ]]; then

    log "[✖] 安装后仍缺少命令: ${POST_MISSING[*]}"

    log "[!] 某些系统仓库可能没有对应软件包。"
    log "[!] 例如部分 RHEL 系统没有 ufw。"
    log "[!] 请手动安装缺失组件，或者改用 firewalld。"

    exit 1
  fi

else

  log "[✔] 依赖齐全，无需安装。"

fi

# ============================================================
# 检查常用端口
# ============================================================

for port in 80 443; do

  if ss -tuln | grep -q ":$port"; then
    log "[!] 端口 $port 当前已被占用"
  else
    log "[✔] 端口 $port 空闲"
  fi

done

# ============================================================
# 用户确认
# ============================================================

read -rp \
  "环境检查完成 ✅  确认继续执行部署吗？(y/N): " \
  CONFIRM

[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0

# ============================================================
# 模式选择
# ============================================================

while true; do

  log ""
  log "请选择部署模式："
  log "1) 使用域名 + Let's Encrypt 证书"
  log "2) 使用公网 IP + 自签固定域名 kyn.com"

  read -rp "请输入选项 (1 或 2): " MODE

  if [[ "$MODE" =~ ^[12]$ ]]; then
    break
  fi

  log "[!] 输入错误，请重新输入 1 或 2"

done

# ============================================================
# 下载函数
# IPv6 优先 -> IPv4
# 多 URL 回退
# ============================================================

download_with_fallback() {

  local out="$1"
  shift

  local url

  for url in "$@"; do

    log ">>> 尝试下载: $url"

    if curl -6 -fL \
      --retry 2 \
      --retry-delay 1 \
      --connect-timeout 6 \
      --max-time 180 \
      "$url" \
      -o "$out" 2>/dev/null; then

      return 0

    fi

    if curl -4 -fL \
      --retry 2 \
      --retry-delay 1 \
      --connect-timeout 6 \
      --max-time 180 \
      "$url" \
      -o "$out" 2>/dev/null; then

      return 0

    fi

    log "[!] 下载失败，换下一个源..."

  done

  return 1
}

# ============================================================
# 检测 CPU 架构
# ============================================================

detect_arch() {

  case "$(uname -m)" in

    x86_64|amd64)
      echo "amd64"
      ;;

    aarch64|arm64)
      echo "arm64"
      ;;

    *)
      echo ""
      ;;

  esac

}

# ============================================================
# 官方 deb-install.sh
# ============================================================

try_official_deb_install() {

  command -v apt-get >/dev/null 2>&1 || return 1
  command -v curl >/dev/null 2>&1 || return 1
  command -v bash >/dev/null 2>&1 || return 1

  command -v sing-box >/dev/null 2>&1 && return 0

  log ">>> 尝试官方安装脚本："
  log "https://sing-box.app/deb-install.sh"

  if bash <(
    curl -fsSL https://sing-box.app/deb-install.sh
  ); then
    :
  else
    log "[!] 官方 deb-install.sh 执行失败"
    log "[!] 进入多源下载兜底..."
  fi

  command -v sing-box >/dev/null 2>&1
}

# ============================================================
# 官方 release 多源安装
# ============================================================

install_from_official_release_with_proxies() {

  local ARCH="$1"

  local ORI
  ORI="https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-${ARCH}.tar.gz"

  local SRC1
  SRC1="https://v6.gh-proxy.org/${ORI}"

  local SRC2
  SRC2="https://mirror.ghproxy.com/${ORI}"

  local SRC3
  SRC3="${ORI}"

  local TGZ="/tmp/sing-box.tgz"

  if download_with_fallback \
    "$TGZ" \
    "$SRC1" \
    "$SRC2" \
    "$SRC3"; then

    log "[✔] 官方 release 下载成功"
    log "[>] 开始安装..."

    rm -rf /tmp/sing-box-* 2>/dev/null || true

    tar -xzf "$TGZ" -C /tmp

    local BIN_PATH

    BIN_PATH="$(
      find /tmp \
        -maxdepth 3 \
        -type f \
        -name sing-box \
        -perm -u+x \
        2>/dev/null |
      head -n1 ||
      true
    )"

    if [[ -z "$BIN_PATH" ]]; then
      log "[✖] 解压后未找到 sing-box 二进制"
      return 1
    fi

    install -m 755 \
      "$BIN_PATH" \
      /usr/local/bin/sing-box

    log "[✔] sing-box 安装完成："
    /usr/local/bin/sing-box version | head -n1

    return 0

  fi

  return 1
}

# ============================================================
# raw 仓库备用安装
# ============================================================

install_from_your_raw_repo() {

  local ARCH="$1"

  log "[!] 外部源全部失败"
  log "[!] 回退从仓库 raw 下载 sing-box..."

  local CORE_BASE
  CORE_BASE="https://raw.githubusercontent.com/hooghub/singboxversion/main/bin"

  local CORE_URL
  CORE_URL="${CORE_BASE}/sing-box-linux-${ARCH}"

  if download_with_fallback \
    "/usr/local/bin/sing-box" \
    "$CORE_URL"; then

    chmod +x /usr/local/bin/sing-box

    log -n ">>> 仓库内核版本："

    if download_with_fallback \
      /tmp/sbver \
      "${CORE_BASE}/VERSION"; then

      cat /tmp/sbver

    else

      echo "unknown"

    fi

    log "[✔] sing-box 安装完成："
    /usr/local/bin/sing-box version | head -n1

    return 0
  fi

  return 1
}

# ============================================================
# 安装 sing-box
# ============================================================

install_singbox() {

  if command -v sing-box >/dev/null 2>&1; then

    local SB_PATH
    SB_PATH="$(command -v sing-box)"

    log "[✔] sing-box 已存在："
    "$SB_PATH" version | head -n1

    return 0
  fi

  log ">>> 安装 sing-box..."
  log ">>> 官方脚本 -> 官方 release 多源 -> raw 备用"

  local ARCH
  ARCH="$(detect_arch)"

  if [[ -z "$ARCH" ]]; then
    log "[✖] 不支持的架构: $(uname -m)"
    exit 1
  fi

  # 1. 官方 deb-install.sh

  if try_official_deb_install; then

    log "[✔] 官方脚本安装完成："
    sing-box version | head -n1

    return 0
  fi

  # 2. 官方 release 多源

  if install_from_official_release_with_proxies "$ARCH"; then
    return 0
  fi

  # 3. raw 备用

  if install_from_your_raw_repo "$ARCH"; then
    return 0
  fi

  log "[✖] sing-box 安装失败"
  log "[✖] 官方脚本 + release 多源 + raw 均不可用"

  exit 1
}

install_singbox

# ============================================================
# 证书目录
# ============================================================

CERT_DIR="/etc/ssl/sing-box"

mkdir -p "$CERT_DIR"

# ============================================================
# 随机端口
# ============================================================

get_random_port() {

  while :; do

    local PORT
    PORT=$((RANDOM % 50000 + 10000))

    if ! ss -tuln | grep -q ":$PORT"; then
      echo "$PORT"
      return
    fi

  done
}

# ============================================================
# 证书处理
#
# 这里是本次修正版最重要的地方：
#
# MODE=1
#   域名 + Let's Encrypt
#
# MODE=2
#   kyn.com + 自签证书
#
# acme.sh 只在 MODE=1 中执行
# ============================================================

if [[ "$MODE" == "1" ]]; then

  # ----------------------------------------------------------
  # 模式1：域名 + Let's Encrypt
  # ----------------------------------------------------------

  while true; do

    read -rp \
      "请输入你的域名 (例如: example.com): " \
      DOMAIN

    if [[ -z "$DOMAIN" ]]; then
      log "[!] 域名不能为空"
      continue
    fi

    DOMAIN_IPV4="$(
      dig +short A "$DOMAIN" |
      tail -n1 ||
      true
    )"

    DOMAIN_IPV6="$(
      dig +short AAAA "$DOMAIN" |
      tail -n1 ||
      true
    )"

    log "[✔] 域名解析检查完成"
    log "    IPv4: ${DOMAIN_IPV4:-无}"
    log "    IPv6: ${DOMAIN_IPV6:-无}"

    break

  done

  # ----------------------------------------------------------
  # 安装 acme.sh
  # ----------------------------------------------------------

  if ! command -v acme.sh >/dev/null 2>&1 &&
     [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then

    log ">>> 安装 acme.sh ..."

    ACME_TGZ="/tmp/acme.sh.tar.gz"
    ACME_SRC="/tmp/acme.sh-src"

    rm -f "$ACME_TGZ"
    rm -rf "$ACME_SRC"

    ACME_OFFICIAL_URL="https://github.com/acmesh-official/acme.sh/archive/master.tar.gz"

    ACME_MIRROR_URL="https://raw.githubusercontent.com/hooghub/singboxversion/main/acme.sh/master.tar.gz"

    log ">>> 下载 acme.sh archive..."

    # 官方 GitHub

    if download_with_fallback \
      "$ACME_TGZ" \
      "$ACME_OFFICIAL_URL"; then

      log "[✔] acme.sh 官方 archive 下载成功"

    # 自有镜像

    elif download_with_fallback \
      "$ACME_TGZ" \
      "$ACME_MIRROR_URL"; then

      log "[✔] acme.sh 仓库镜像下载成功"

    else

      log "[✖] acme.sh 下载失败"
      log "[✖] 官方源和仓库镜像均不可用"

      exit 1

    fi

    mkdir -p "$ACME_SRC"

    if ! tar -xzf "$ACME_TGZ" \
      -C "$ACME_SRC" \
      --strip-components=1; then

      log "[✖] acme.sh archive 解压失败"
      exit 1

    fi

    if [[ ! -f "$ACME_SRC/acme.sh" ]]; then

      log "[✖] acme.sh archive 中未找到 acme.sh"
      exit 1

    fi

    chmod +x "$ACME_SRC/acme.sh"

    log ">>> 使用本地 acme.sh 源码安装..."

if ! (
  cd "$ACME_SRC"
  ./acme.sh \
    --install \
    --home "$HOME/.acme.sh"
); then

  log "[✖] acme.sh 安装失败"
  exit 1
    fi

    rm -rf "$ACME_SRC"
    rm -f "$ACME_TGZ"

    source "$HOME/.bashrc" 2>/dev/null || true

  fi

  # ----------------------------------------------------------
  # 确认 acme.sh
  # ----------------------------------------------------------

  if [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then

    log "[✖] acme.sh 安装后未找到："
    log "$HOME/.acme.sh/acme.sh"

    exit 1
  fi

  # ----------------------------------------------------------
  # 设置 Let's Encrypt
  # ----------------------------------------------------------

  "$HOME/.acme.sh/acme.sh" \
    --set-default-ca \
    --server letsencrypt

  LE_CERT_PATH="$HOME/.acme.sh/${DOMAIN}_ecc/fullchain.cer"
  LE_KEY_PATH="$HOME/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.key"

  # ----------------------------------------------------------
  # 已存在证书
  # ----------------------------------------------------------

  if [[ -f "$LE_CERT_PATH" && -f "$LE_KEY_PATH" ]]; then

    log "[✔] 已检测到现有 Let's Encrypt 证书"
    log "[>] 直接导入"

    cp \
      "$LE_CERT_PATH" \
      "$CERT_DIR/fullchain.pem"

    cp \
      "$LE_KEY_PATH" \
      "$CERT_DIR/privkey.pem"

    chmod 644 \
      "$CERT_DIR/fullchain.pem" \
      "$CERT_DIR/privkey.pem"

  else

    # --------------------------------------------------------
    # 申请新证书
    # --------------------------------------------------------

    log ">>> 申请新的 Let's Encrypt TLS 证书"

    USE_LISTEN=""

    if [[ -n "${SERVER_IPV4:-}" ]]; then

      USE_LISTEN="--listen-v4"

    elif [[ -n "${SERVER_IPV6:-}" ]]; then

      USE_LISTEN="--listen-v6"

    else

      log "[✖] 未检测到可用 IPv4 或 IPv6"
      log "[✖] 无法申请证书"

      exit 1

    fi

    "$HOME/.acme.sh/acme.sh" \
      --issue \
      -d "$DOMAIN" \
      --standalone \
      $USE_LISTEN \
      --keylength ec-256 \
      --force

    "$HOME/.acme.sh/acme.sh" \
      --install-cert \
      -d "$DOMAIN" \
      --ecc \
      --key-file "$CERT_DIR/privkey.pem" \
      --fullchain-file "$CERT_DIR/fullchain.pem" \
      --force

    chmod 644 \
      "$CERT_DIR/fullchain.pem" \
      "$CERT_DIR/privkey.pem"

    log "[✔] TLS 证书申请完成"

  fi

else

  # ----------------------------------------------------------
  # 模式2：公网 IP + 自签证书
  # ----------------------------------------------------------

  DOMAIN="kyn.com"

  log "[!] 自签模式"
  log "[!] 固定域名：$DOMAIN"

  SAN="DNS:$DOMAIN"

  if [[ -n "${SERVER_IPV4:-}" ]]; then
    SAN+=",IP:$SERVER_IPV4"
  fi

  if [[ -n "${SERVER_IPV6:-}" ]]; then
    SAN+=",IP:$SERVER_IPV6"
  fi

  openssl req \
    -x509 \
    -nodes \
    -days 365 \
    -newkey rsa:2048 \
    -keyout "$CERT_DIR/privkey.pem" \
    -out "$CERT_DIR/fullchain.pem" \
    -subj "/CN=$DOMAIN" \
    -addext "subjectAltName = $SAN" -addext "basicConstraints=critical,CA:FALSE" -addext "extendedKeyUsage=serverAuth"

  chmod 644 \
    "$CERT_DIR/fullchain.pem" \
    "$CERT_DIR/privkey.pem"

  log "[✔] 自签证书生成完成"
  log "[✔] SAN: $SAN"

fi

# ============================================================
# 输入端口
# ============================================================

read -rp \
  "请输入 VLESS TCP TLS 端口 (随机端口直接回车): " \
  VLESS_PORT

if [[ -z "${VLESS_PORT:-}" ]]; then
  VLESS_PORT="$(get_random_port)"
fi

read -rp \
  "请输入 VLESS REALITY 端口 (随机端口直接回车): " \
  VLESS_R_PORT

if [[ -z "${VLESS_R_PORT:-}" ]]; then
  VLESS_R_PORT="$(get_random_port)"
fi

read -rp \
  "请输入 Hysteria2 UDP 端口 (随机端口直接回车): " \
  HY2_PORT

if [[ -z "${HY2_PORT:-}" ]]; then
  HY2_PORT="$(get_random_port)"
fi

# ============================================================
# IPv6 独立端口
# ============================================================

VLESS6_PORT="$(get_random_port)"
VLESS_R6_PORT="$(get_random_port)"
HY2_6_PORT="$(get_random_port)"

# ============================================================
# UUID / Hysteria2 密码
# ============================================================

UUID="$(cat /proc/sys/kernel/random/uuid)"

HY2_PASS="$(
  openssl rand -base64 16 |
  tr -dc 'a-zA-Z0-9' |
  head -c 24
)"

# ============================================================
# REALITY 参数
# ============================================================

read -rp \
  "REALITY 伪装站点(Handshake server) [默认: www.yahoo.com]: " \
  REALITY_SERVER

REALITY_SERVER="${REALITY_SERVER:-www.yahoo.com}"

read -rp \
  "REALITY SNI(server_name) [默认同上]: " \
  REALITY_SNI

REALITY_SNI="${REALITY_SNI:-$REALITY_SERVER}"

REALITY_KEYPAIR="$(
  sing-box generate reality-keypair
)"

REALITY_PRIVATE_KEY="$(
  echo "$REALITY_KEYPAIR" |
  awk '/PrivateKey/ {print $2}'
)"

REALITY_PUBLIC_KEY="$(
  echo "$REALITY_KEYPAIR" |
  awk '/PublicKey/ {print $2}'
)"

REALITY_SHORT_ID="$(
  openssl rand -hex 8
)"

# ============================================================
# 生成 sing-box 配置
# ============================================================

mkdir -p /etc/sing-box

cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": $VLESS_PORT,
      "users": [
        {
          "uuid": "$UUID"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificate_path": "$CERT_DIR/fullchain.pem",
        "key_path": "$CERT_DIR/privkey.pem"
      }
    },
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $VLESS6_PORT,
      "users": [
        {
          "uuid": "$UUID"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificate_path": "$CERT_DIR/fullchain.pem",
        "key_path": "$CERT_DIR/privkey.pem"
      }
    },
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": $VLESS_R_PORT,
      "users": [
        {
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_SNI",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$REALITY_SERVER",
            "server_port": 443
          },
          "private_key": "$REALITY_PRIVATE_KEY",
          "short_id": [
            "$REALITY_SHORT_ID"
          ]
        }
      }
    },
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $VLESS_R6_PORT,
      "users": [
        {
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_SNI",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$REALITY_SERVER",
            "server_port": 443
          },
          "private_key": "$REALITY_PRIVATE_KEY",
          "short_id": [
            "$REALITY_SHORT_ID"
          ]
        }
      }
    },
    {
      "type": "hysteria2",
      "listen": "0.0.0.0",
      "listen_port": $HY2_PORT,
      "users": [
        {
          "password": "$HY2_PASS"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificate_path": "$CERT_DIR/fullchain.pem",
        "key_path": "$CERT_DIR/privkey.pem"
      }
    },
    {
      "type": "hysteria2",
      "listen": "::",
      "listen_port": $HY2_6_PORT,
      "users": [
        {
          "password": "$HY2_PASS"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificate_path": "$CERT_DIR/fullchain.pem",
        "key_path": "$CERT_DIR/privkey.pem"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
EOF

log "[✔] sing-box 配置生成完成：/etc/sing-box/config.json"

# ============================================================
# 检查 sing-box 配置
# ============================================================

if ! sing-box check -c /etc/sing-box/config.json; then
  log "[✖] sing-box 配置检查失败"
  exit 1
fi

log "[✔] sing-box 配置检查通过"

# ============================================================
# systemd 服务
# ============================================================

# 1. 探测真实的 sing-box 路径
REAL_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box")

# 节点信息同步组件（证书与核心下载逻辑保持原样）
NODE_SYNC_BIN=/usr/local/lib/singbox-node-sync/run
NODE_SYNC_STATE=/var/lib/singbox-node-sync
install -d -m 700 /usr/local/lib/singbox-node-sync "$NODE_SYNC_STATE"
cat > "$NODE_SYNC_BIN" <<'NODE_SYNC_PY'
#!/usr/bin/env python3
"""Node metadata only: never restarts or edits sing-box configuration."""
import base64,fcntl,hashlib,ipaddress,json,os,pathlib,re,subprocess,sys,tempfile,time,urllib.parse,uuid
STATE=pathlib.Path('/var/lib/singbox-node-sync')
CONFIG=pathlib.Path('/etc/sing-box/config.json')
OUTPUT=pathlib.Path('/etc/nodes/sing-box/links.txt')
RUN=pathlib.Path('/run/singbox-node-sync')
def run(args,**kw):
    return subprocess.run(args,check=True,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=20,**kw).stdout
def read(p):return json.loads(pathlib.Path(p).read_text())
def atomic(p,data):
    p=pathlib.Path(p);p.parent.mkdir(parents=True,exist_ok=True)
    fd,name=tempfile.mkstemp(prefix='.'+p.name+'-',dir=p.parent)
    try:
        os.fchmod(fd,0o600)
        with os.fdopen(fd,'wb') as f:f.write(data.encode() if isinstance(data,str) else data);f.flush();os.fsync(f.fileno())
        os.replace(name,p)
    finally:
        if os.path.exists(name):os.unlink(name)
# Unified TXT publication only; core configuration and readiness checks stay unchanged.
def publish_nodes(content):
    # VPSKIT_SHARED_PUBLICATION
    import runpy
    runpy.run_path('/usr/local/lib/argo-node-files/run',run_name='vpskit_publication')['publish']('sing-box',content)

def write(p,data):atomic(p,json.dumps(data,ensure_ascii=False))
def digest(data):return hashlib.sha256(data).hexdigest()
def checked_config():
    data=CONFIG.read_bytes();cfg=json.loads(data)
    binary=read(STATE/'deployment.json')['binary']
    run([binary,'check','-c',str(CONFIG)])
    if CONFIG.read_bytes()!=data:raise RuntimeError('配置检查期间发生变化，等待下次检查')
    return data,cfg
def process():
    if run(['systemctl','is-active','sing-box.service']).decode().strip()!='active':raise RuntimeError('sing-box 未运行')
    pid=int(run(['systemctl','show','sing-box.service','--property=MainPID','--value']).decode().strip())
    if pid<=0:raise RuntimeError('无法确认 sing-box PID')
    proc=pathlib.Path('/proc')/str(pid)
    ticks=proc.joinpath('stat').read_text().rsplit(')',1)[1].split()[19]
    args=proc.joinpath('cmdline').read_bytes().split(b'\0')
    if b'-c' not in args or args[args.index(b'-c')+1]!=str(CONFIG).encode():raise RuntimeError('运行进程配置路径不匹配')
    return pid,ticks
def mark():
    # ExecStartPost runs while the unit is activating, so do not require is-active here.
    pid=int(os.environ.get('MAINPID','0'))
    if not pid:pid=int(run(['systemctl','show','sing-box.service','--property=MainPID','--value']).decode().strip())
    ticks=pathlib.Path('/proc',str(pid),'stat').read_text().rsplit(')',1)[1].split()[19]
    data=(RUN/'pending.json').read_bytes()
    if CONFIG.read_bytes()!=data:raise RuntimeError('启动期间配置发生变化，请重新启动核心')
    write(RUN/'active.json',{'pid':pid,'ticks':ticks,'sha':digest(data)})
    atomic(RUN/'loaded.json',data)
def country(ip):
    try:ip=str(ipaddress.ip_address(ip))
    except ValueError:return ''
    path=STATE/('country-'+digest(ip.encode())[:16]+'.json');now=time.time()
    cache={}
    try:cache=read(path)
    except (OSError,ValueError):pass
    if cache.get('expires',0)>now:return cache.get('label','')
    providers=[('https://ipwho.is/'+ip,'country_code','country'),('https://ipapi.co/'+ip+'/json/','country_code','country_name'),('https://ipinfo.io/'+ip+'/json','country',None)]
    for url,code_field,name_field in providers:
        try:
            raw=run(['curl','-fLsS','--connect-timeout','2','--max-time','3',url])
            obj=json.loads(raw);code=obj.get(code_field,'').upper()
            if obj.get('success') is False or obj.get('error') or not re.fullmatch('[A-Z]{2}',code):continue
            flag=''.join(chr(0x1f1e6+ord(c)-65) for c in code)
            name=obj.get(name_field) if name_field else code
            label=flag+(name if isinstance(name,str) and name else code)
            write(path,{'label':label,'expires':now+86400,'ip':ip});return label
        except (ValueError,OSError,subprocess.SubprocessError,AttributeError):continue
    # Keep an old valid country when providers are unavailable; retry failures after 10 minutes.
    label=cache.get('label','');write(path,{'label':label,'expires':now+600,'ip':ip});return label
def ip_for(tag,meta):
    preferred='ipv6' if 'V6' in tag else 'ipv4'
    return meta.get(preferred) or meta.get('ipv6' if preferred=='ipv4' else 'ipv4') or ''
def node_name(name,ip):
    suffix=country(ip)
    return urllib.parse.quote(name+('-'+suffix if suffix else ''),safe='')
def public_key(private):
    raw=base64.urlsafe_b64decode(private+'='*((4-len(private)%4)%4))
    if len(raw)!=32:raise RuntimeError('Reality 私钥长度错误')
    der=bytes.fromhex('302e020100300506032b656e04220420')+raw
    pub=run(['openssl','pkey','-inform','DER','-pubout','-outform','DER'],input=der)
    if len(pub)!=44 or pub[:12]!=bytes.fromhex('302a300506032b656e032100'):raise RuntimeError('无法解析 Reality 公钥')
    return base64.urlsafe_b64encode(pub[-32:]).decode().rstrip('=')
def listens(pid,cfg):
    inodes=set()
    for fd in pathlib.Path('/proc',str(pid),'fd').iterdir():
        try:
            target=os.readlink(fd)
            if target.startswith('socket:['):inodes.add(target[8:-1])
        except OSError:pass
    available=set()
    for table in ['tcp','tcp6','udp','udp6']:
        try:rows=pathlib.Path('/proc',str(pid),'net',table).read_text().splitlines()[1:]
        except OSError:continue
        for row in rows:
            fields=row.split()
            if len(fields)<10 or fields[9] not in inodes:continue
            if table.startswith('tcp') and fields[3]!='0A':continue
            available.add(('tcp' if table.startswith('tcp') else 'udp',int(fields[1].split(':')[-1],16)))
    for inbound in cfg.get('inbounds',[]):
        kind=inbound.get('type')
        if kind not in ['vless','hysteria2']:raise RuntimeError('出现非原脚本支持的入站，未覆盖节点文件')
        protocol='udp' if kind=='hysteria2' else 'tcp'
        port=inbound.get('listen_port')
        if not isinstance(port,int) or not 1<=port<=65535 or (protocol,port) not in available:raise RuntimeError('入站端口尚未由当前核心监听')
def generate(cfg,meta):
    lines=[]
    for inbound in cfg.get('inbounds',[]):
        tls=inbound.get('tls',{});kind=inbound['type'];reality=tls.get('reality',{}).get('enabled',False)
        if not tls.get('enabled') or inbound.get('transport'):raise RuntimeError('入站 TLS/传输已改变，暂不生成此类节点')
        v6=':' in inbound.get('listen','');tag=('DOMAIN-V6PORT' if v6 else 'DOMAIN-V4PORT') if meta['mode']=='1' else ('V6' if v6 else 'V4')
        # For domain mode use the matching plain TLS domain, not Reality's camouflage SNI.
        plain=next((x for x in cfg['inbounds'] if x.get('type') in ['vless','hysteria2'] and x.get('tls',{}).get('enabled') and not x.get('tls',{}).get('reality',{}).get('enabled') and (':' in x.get('listen',''))==v6),None)
        host=plain.get('tls',{}).get('server_name','') if meta['mode']=='1' and plain else meta.get('ipv6' if v6 else 'ipv4','')
        if not host:continue
        try:parsed=ipaddress.ip_address(host);host_br='['+host+']' if parsed.version==6 else host
        except ValueError:
            if not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?',host):raise RuntimeError('域名格式错误')
            host_br=host
        port=inbound['listen_port'];sni=tls.get('server_name','');insecure='0' if meta['mode']=='1' else '1'
        for user in inbound.get('users',[]):
            if kind=='vless':
                uid=str(uuid.UUID(user['uuid']));prefix='VLESS-REALITY' if reality else 'VLESS-TLS'
                query={'encryption':'none','security':'reality' if reality else 'tls','sni':sni}
                if reality:
                    ids=tls['reality'].get('short_id',[])
                    if not ids or not re.fullmatch('[a-fA-F0-9]{0,16}',ids[0]) or len(ids[0])%2:raise RuntimeError('Reality ShortID 格式错误')
                    query.update(fp='chrome',pbk=public_key(tls['reality']['private_key']),sid=ids[0],type='tcp',flow=user.get('flow',''))
                else:
                    query.update(allowInsecure='0',type='tcp')
                    der=run(['openssl','x509','-in',tls['certificate_path'],'-outform','DER'])
                    if not der:raise RuntimeError('证书读取失败，保留旧链接')
                    query['pcs']=hashlib.sha256(der).hexdigest()
                uri='vless://'+uid+'@'+host_br+':'+str(port)
            else:
                password=user.get('password','')
                if not password:raise RuntimeError('HY2 密码为空')
                prefix='HY2';uri='hysteria2://'+urllib.parse.quote(password,safe='')+'@'+host_br+':'+str(port)
                query={'insecure':insecure,'sni':sni}
            lines += ['# ===== '+tag+' '+prefix+' =====',uri+'?'+urllib.parse.urlencode(query,quote_via=urllib.parse.quote)+'#'+node_name(prefix+'-'+tag+'-'+host,ip_for(tag,meta)),'']
    if not lines:raise RuntimeError('未生成有效节点，保留旧文件')
    return '\n'.join(lines)+'\n'
def sync():
    pid,ticks=process();active=read(RUN/'active.json')
    data,cfg=checked_config()
    if active!={'pid':pid,'ticks':ticks,'sha':digest(data)} or (RUN/'loaded.json').read_bytes()!=data:raise RuntimeError('磁盘配置未确认已加载，请检查配置后重启 sing-box')
    listens(pid,cfg)
    content=generate(cfg,read(STATE/'deployment.json'))
    # Slow geolocation must not allow a service restart or config edit to race the write.
    if process()!=(pid,ticks) or CONFIG.read_bytes()!=data or read(RUN/'active.json')!=active:raise RuntimeError('生成期间配置或进程改变，保留旧文件')
    publish_nodes(content)

def main():
    STATE.mkdir(parents=True,exist_ok=True);RUN.mkdir(parents=True,exist_ok=True)
    os.chmod(STATE,0o700);os.chmod(RUN,0o700)
    with open(RUN/'lock','a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        mode=sys.argv[1] if len(sys.argv)>1 else '--once'
        if mode=='--capture':data,cfg=checked_config();atomic(RUN/'pending.json',data)
        elif mode=='--mark':mark()
        elif mode=='--label':print(node_name(sys.argv[2],sys.argv[3]))
        elif mode=='--once':sync()
        else:raise RuntimeError('未知运行参数')
if __name__=='__main__':
    try:main()
    except Exception as e:
        # Do not print JSON, passwords, private keys, or complete URIs to service logs.
        print(time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())+' 同步失败（保留旧文件）：'+type(e).__name__+' '+(str(e) if isinstance(e,RuntimeError) else '请检查配置、依赖及权限'),file=sys.stderr)
        sys.exit(1)
NODE_SYNC_PY
chmod 700 "$NODE_SYNC_BIN"
python3 - "$NODE_SYNC_STATE/deployment.json" "$MODE" "$DOMAIN" "$SERVER_IPV4" "$SERVER_IPV6" "$REAL_BIN" <<'NODE_SYNC_META'
import json,os,sys,tempfile
path=sys.argv[1]
fd,tmp=tempfile.mkstemp(dir=os.path.dirname(path));os.fchmod(fd,0o600)
with os.fdopen(fd,'w') as f:
    json.dump(dict(mode=sys.argv[2],domain=sys.argv[3],ipv4=sys.argv[4],ipv6=sys.argv[5],binary=sys.argv[6]),f)
os.replace(tmp,path)
NODE_SYNC_META

# 2. 直接覆盖并生成最新的服务文件（注意：EOF 不要带单引号）
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/usr/local/lib/singbox-node-sync/run --capture
ExecStart=${REAL_BIN} run -c /etc/sing-box/config.json
ExecStartPost=/usr/local/lib/singbox-node-sync/run --mark
Restart=on-failure
RestartSec=2s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# ============================================================
# 防火墙
# ============================================================

if command -v ufw >/dev/null 2>&1; then

  ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true

  ufw allow "${VLESS_PORT}/tcp" >/dev/null 2>&1 || true
  ufw allow "${VLESS6_PORT}/tcp" >/dev/null 2>&1 || true

  ufw allow "${VLESS_R_PORT}/tcp" >/dev/null 2>&1 || true
  ufw allow "${VLESS_R6_PORT}/tcp" >/dev/null 2>&1 || true

  ufw allow "${HY2_PORT}/udp" >/dev/null 2>&1 || true
  ufw allow "${HY2_6_PORT}/udp" >/dev/null 2>&1 || true

  ufw reload >/dev/null 2>&1 || true

fi

# ============================================================
# 启动 sing-box
# ============================================================

systemctl enable sing-box >/dev/null 2>&1 || true

systemctl restart sing-box

sleep 8

# ============================================================
# 服务状态
# ============================================================

log ""
log "=================== 服务状态 ==================="

systemctl --no-pager -l status sing-box || true

# ============================================================
# 监听端口检查
# ============================================================

log ""
log "=================== sing-box 监听端口状态 ==================="

check_port() {

  local name="$1"
  local ipver="$2"
  local proto="$3"
  local port="$4"

  [[ -z "${port:-}" ]] && return 0

  if [[ "$proto" == "tcp" ]]; then

    if ss -tlnp 2>/dev/null |
      grep -qE "LISTEN.*:${port}\b.*sing-box"; then

      echo "[✔️] ${name} ${ipver} (TCP/${port}) 已监听"

    else

      echo "[❌] ${name} ${ipver} (TCP/${port}) 未监听"

    fi

  else

    if ss -ulnp 2>/dev/null |
      grep -qE ":${port}\b.*sing-box"; then

      echo "[✔️] ${name} ${ipver} (UDP/${port}) 已监听"

    else

      echo "[❌] ${name} ${ipver} (UDP/${port}) 未监听"

    fi

  fi
}

check_port \
  "VLESS-TLS" \
  "IPv4" \
  "tcp" \
  "$VLESS_PORT"

check_port \
  "VLESS-TLS" \
  "IPv6" \
  "tcp" \
  "$VLESS6_PORT"

echo

check_port \
  "VLESS-REALITY" \
  "IPv4" \
  "tcp" \
  "$VLESS_R_PORT"

check_port \
  "VLESS-REALITY" \
  "IPv6" \
  "tcp" \
  "$VLESS_R6_PORT"

echo

check_port \
  "Hysteria2" \
  "IPv4" \
  "udp" \
  "$HY2_PORT"

check_port \
  "Hysteria2" \
  "IPv6" \
  "udp" \
  "$HY2_6_PORT"

# ============================================================
# 生成节点 URI
# ============================================================

SUB_FILE="/etc/nodes/sing-box/links.txt"
mkdir -p /etc/nodes/sing-box
chmod 700 /etc/nodes /etc/nodes/sing-box
# 首次输出及后续更新均由同一生成器完成；验证失败不覆盖旧文件。
if "$NODE_SYNC_BIN" --once; then
  log "[✔] 已验证并保存最新节点：$SUB_FILE"
else
  log "[✖] 节点同步验证失败，旧节点文件保持不变。请检查核心与同步日志。"
  exit 1
fi
cat > /etc/systemd/system/singbox-node-sync.service <<'NODE_SYNC_SERVICE'
[Unit]
Description=Validate and refresh sing-box node links
After=network-online.target sing-box.service
[Service]
Type=oneshot
ExecStart=/usr/local/lib/singbox-node-sync/run --once
UMask=0077
TimeoutStartSec=180
NODE_SYNC_SERVICE
cat > /etc/systemd/system/singbox-node-sync.timer <<'NODE_SYNC_TIMER'
[Unit]
Description=Check sing-box node metadata every 60 seconds
[Timer]
OnBootSec=45s
OnUnitActiveSec=60s
AccuracySec=5s
Unit=singbox-node-sync.service
[Install]
WantedBy=timers.target
NODE_SYNC_TIMER
systemctl daemon-reload
systemctl enable --now singbox-node-sync.timer
log "[✔] 已启用每 60 秒后台检查与开机启动"

# ============================================================
# 输出订阅文件
# ============================================================

log ""
log "节点链接将在统一命名的节点链接处显示。"

log ""
log "节点链接已保存到：$SUB_FILE"
log "合并订阅：/etc/nodes/subscription.txt"

log ""
log "=================== 部署完成 ==================="

log ""
log "VLESS-TLS IPv4 端口：$VLESS_PORT"
log "VLESS-TLS IPv6 端口：$VLESS6_PORT"

log ""
log "VLESS-REALITY IPv4 端口：$VLESS_R_PORT"
log "VLESS-REALITY IPv6 端口：$VLESS_R6_PORT"

log ""
log "Hysteria2 IPv4 端口：$HY2_PORT"
log "Hysteria2 IPv6 端口：$HY2_6_PORT"

log ""
log "UUID：$UUID"

log ""
log "REALITY SNI：$REALITY_SNI"
log "REALITY Server：$REALITY_SERVER"
log "REALITY PublicKey：$REALITY_PUBLIC_KEY"
log "REALITY ShortID：$REALITY_SHORT_ID"

log ""
log "订阅文件：$SUB_FILE"
