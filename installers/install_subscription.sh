#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# VPS Subscription API Installer V2
# ============================================================

APP_NAME="subscription-api"
API_SCRIPT="/root/subscription_api.py"
API_PORT="8765"
NODE_FILE="/etc/nodes/subscription.txt"

NGINX_SSL_ROOT="/etc/nginx/ssl"
NGINX_CONF_DIR="/etc/nginx/conf.d"

CERT_LIST="/tmp/subscription_cert_list.txt"

DOMAIN=""
CERT_SRC=""
KEY_SRC=""
CERT_DST=""
KEY_DST=""

# ============================================================
# 输出
# ============================================================

info() {
    echo -e "\033[1;36m[INFO]\033[0m $*"
}

success() {
    echo -e "\033[1;32m[ OK ]\033[0m $*"
}

warn() {
    echo -e "\033[38;5;120m[WARN]\033[0m $*"
}

die() {
    echo -e "\033[38;5;120m[ERROR]\033[0m $*" >&2
    exit 1
}

trap 'die "脚本执行失败，行号：$LINENO"' ERR
SUB_BACKUP=""
SUB_SUCCESS=0
subscription_exit() {
    local result=$?
    trap - ERR EXIT
    if [[ -n "$SUB_BACKUP" ]]; then
        if [[ "$SUB_SUCCESS" != 1 && -f "$SUB_BACKUP/backup.json" ]]; then
            python3 "$VPSKIT_ROOT/lib/subscription-manager.py" restore "$SUB_BACKUP" || echo '订阅恢复失败，请检查备份：'"$SUB_BACKUP" >&2
        else rm -rf -- "$SUB_BACKUP"; fi
    fi
    exit "$result"
}
trap subscription_exit EXIT

# ============================================================
# Root
# ============================================================

check_root() {
    [[ "$EUID" -eq 0 ]] || die "请使用 root 用户运行。"
}

# ============================================================
# 系统检测
# ============================================================

detect_system() {

    [[ -f /etc/os-release ]] || die "无法识别系统。"

    . /etc/os-release

    OS_NAME="${PRETTY_NAME:-$ID}"

    info "操作系统：${OS_NAME}"

    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MANAGER="apk"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    else
        die "不支持的系统：未找到 apt/apk/dnf/yum。"
    fi

    info "包管理器：${PKG_MANAGER}"
}

# ============================================================
# 安装依赖
# ============================================================

install_dependencies() {

    info "检查并安装依赖..."

    case "$PKG_MANAGER" in

        apt)
            export DEBIAN_FRONTEND=noninteractive

            apt-get update

            apt-get install -y \
                python3 \
                nginx \
                openssl \
                ca-certificates \
                curl
            ;;

        apk)
            apk add --no-cache \
                python3 \
                nginx \
                openssl \
                ca-certificates \
                curl
            ;;

        dnf)
            dnf install -y \
                python3 \
                nginx \
                openssl \
                ca-certificates \
                curl
            ;;

        yum)
            yum install -y \
                python3 \
                nginx \
                openssl \
                ca-certificates \
                curl
            ;;

    esac

    command -v python3 >/dev/null 2>&1 ||
        die "Python3 安装失败。"

    command -v openssl >/dev/null 2>&1 ||
        die "OpenSSL 安装失败。"

    command -v nginx >/dev/null 2>&1 ||
        die "Nginx 安装失败。"

    command -v curl >/dev/null 2>&1 ||
        die "curl 安装失败。"

    success "系统依赖正常。"
}

# ============================================================
# 证书扫描
# ============================================================

search_certificates() {
    info "正在搜索 SSL 证书..."
    local extra_dirs
    read -r -p $'\033[38;5;120m额外扫描目录（多个用冒号分隔，回车使用默认）：\033[0m' extra_dirs
    python3 - "$CERT_LIST" "$extra_dirs" <<'PY_SCAN'
import csv
import os
import re
import subprocess
import sys
from pathlib import Path

def run(args):
    try:
        return subprocess.check_output(["openssl", *args], stderr=subprocess.DEVNULL,
                                       timeout=5, stdin=subprocess.DEVNULL)
    except (subprocess.SubprocessError, OSError):
        return None

def public_key(path, certificate=False):
    args = ["x509", "-in", str(path), "-pubkey", "-noout"] if certificate else ["pkey", "-in", str(path), "-pubout", "-passin", "pass:"]
    return run(args)

def source(path):
    text = str(path)
    if "/.acme.sh/" in text:
        return "申请来源：acme.sh"
    if "/letsencrypt/live/" in text or "/letsencrypt/archive/" in text:
        return "申请来源：Certbot"
    if "/certificates/" in text and ("/.lego/" in text or path.with_suffix(".json").is_file()):
        return "申请来源：lego"
    return ""

def file_time(path):
    try:
        birth = subprocess.check_output(["stat", "-c", "%W", str(path)], stderr=subprocess.DEVNULL, timeout=3).strip()
        if int(birth) > 0:
            return int(birth)
    except (ValueError, OSError, subprocess.SubprocessError):
        pass
    return path.stat().st_mtime

roots = ["/root", "/home", "/etc", "/usr/local", "/opt", "/var/lib", "/var/www"]
roots += [part for part in sys.argv[2].split(":") if part]
files = set()
for root in roots:
    for directory, dirs, names in os.walk(root, followlinks=False):
        dirs[:] = [name for name in dirs if name not in (".git", "node_modules", ".cache")]
        for name in names:
            if Path(name).suffix.lower() in (".pem", ".cer", ".crt", ".key"):
                path = Path(directory) / name
                if path.is_file():
                    files.add(path)
keys = {}
certificates = []
for path in sorted(files):
    try:
        head = path.open("rb").read(4096)
    except OSError:
        continue
    if b"PRIVATE KEY-----" in head:
        pub = public_key(path)
        if pub:
            keys.setdefault(pub, []).append(path)
    if b"BEGIN CERTIFICATE" in head:
        certificates.append(path)
groups = {}
for cert in certificates:
    pub = public_key(cert, True)
    candidates = keys.get(pub, [])
    if not candidates:
        continue
    key = min(candidates, key=lambda p: (p.parent != cert.parent, str(p)))
    metadata = run(["x509", "-in", str(cert), "-noout", "-subject", "-issuer", "-startdate", "-enddate", "-fingerprint", "-sha256", "-ext", "subjectAltName"])
    if not metadata:
        continue
    text = metadata.decode(errors="replace")
    cn = re.search(r"\bCN\s*=\s*([^,\n]+)", text)
    sans = re.findall(r"DNS:([^,\s]+)", text)
    domain = cn.group(1).strip() if cn else (sans[0] if sans else "")
    if not domain:
        continue
    def field(prefix):
        return next((line.split("=", 1)[1] for line in text.splitlines() if line.startswith(prefix + "=")), "")
    fingerprint = next((line for line in text.splitlines() if "Fingerprint=" in line), "")
    if not fingerprint:
        continue
    row = [domain, ",".join(sans), str(cert), str(key), field("issuer"), field("notBefore"), field("notAfter")]
    groups.setdefault(fingerprint, []).append(row)
selected, locations = [], []
for index, rows in enumerate(groups.values(), 1):
    # 识别工具目录；同目录优先完整证书链，未知目录按文件时间排序。
    rows.sort(key=lambda r: ({"申请来源：acme.sh": 0, "申请来源：Certbot": 1, "申请来源：lego": 2}.get(source(Path(r[2])), 3),
                             0 if "/letsencrypt/live/" in r[2] else 1,
                             0 if Path(r[2]).name.startswith("fullchain") else 1,
                             file_time(Path(r[2])), r[2]))
    # 同目录同私钥的单证书/完整链只显示优先完整链的一项。
    unique_rows = []
    seen_locations = set()
    for row in rows:
        location = (str(Path(row[2]).parent), row[3])
        if location not in seen_locations:
            seen_locations.add(location)
            unique_rows.append(row)
    rows = unique_rows
    selected.append(rows[0])
    for position, row in enumerate(rows):
        label = source(Path(row[2])) if position == 0 else ""
        if not label:
            label = "可能来源（时间辅助）" if position == 0 else f"保存位置 {position}"
        locations.append([str(index), row[2], row[3], label])
path = Path(sys.argv[1])
with path.open("w") as stream:
    csv.writer(stream, delimiter="\t", lineterminator="\n").writerows(selected)
with Path(str(path) + ".locations").open("w") as stream:
    csv.writer(stream, delimiter="\t", lineterminator="\n").writerows(locations)
PY_SCAN
    local count
    count="$(wc -l < "$CERT_LIST" | tr -d ' ')"
    [[ "$count" -gt 0 ]] || die "没有找到证书和匹配私钥。"
    success "发现 ${count} 个可用证书（相同证书已合并）。"
}

# ============================================================
# 选择证书
# ============================================================

select_certificate() {

    echo
    printf '\033[0;90m%s\033[0m\n' "============================================================"
    printf '\033[1;36m%s\033[0m\n' "                    可用 SSL 证书"
    printf '\033[0;90m%s\033[0m\n' "============================================================"

    local terminal_width
    terminal_width="${COLUMNS:-$(tput cols 2>/dev/null || printf '80')}"
    python3 - "$CERT_LIST" "$terminal_width" <<'PY_DISPLAY'
import csv
import sys
import unicodedata
from pathlib import Path
path = Path(sys.argv[1])
try:
    terminal_width = int(sys.argv[2])
except ValueError:
    terminal_width = 80
rows = list(csv.reader(path.read_text().splitlines(), delimiter="\t"))
locations = list(csv.reader(Path(str(path) + ".locations").read_text().splitlines(), delimiter="\t"))
def colored(text, code):
    return f"\033[{code}m{text}\033[0m"
for index, row in enumerate(rows, 1):
    cn, san, cert, key, issuer, start, end = row
    print()
    print(colored(f"[{index}] {cn}", "1;36"))
    print(f"    SAN      : {san}")
    print(f"    Issuer   : {issuer}")
    print(f"    有效期   : {start} -> {end}")
    paths = [(entry[1], entry[2]) for entry in locations if entry[0] == str(index)]
    headings = [entry[3] for entry in locations if entry[0] == str(index)]
    def cells(text):
        return sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in text)
    def wrap_cells(text, limit):
        parts, current, used = [], "", 0
        for char in text:
            size = cells(char)
            if current and used + size > limit:
                parts.append(current)
                current, used = "", 0
            current += char
            used += size
        parts.append(current)
        return parts
    # 两列分组，长路径在各自列内折行，避免整体退回纵排。
    column_width = max(24, (terminal_width - 7) // 2)
    for offset in range(0, len(paths), 2):
        group = paths[offset:offset + 2]
        titles = headings[offset:offset + 2]
        print()
        for values, color in [(titles, "1;36"),
                              (["Cert : " + pair[0] for pair in group], "0;37"),
                              (["Key  : " + pair[1] for pair in group], "0;37")]:
            wrapped = [wrap_cells(value, column_width) for value in values]
            for line in range(max(map(len, wrapped))):
                columns = [parts[line] if line < len(parts) else "" for parts in wrapped]
                print("    " + "   ".join(colored(value + " " * (column_width - cells(value)), color)
                                         for value in columns).rstrip())

PY_DISPLAY

    echo
    printf '\033[0;90m%s\033[0m\n' "============================================================"
    printf '\033[38;5;120m%s\033[0m\n' "请输入编号，或者直接输入域名。"
    printf '\033[38;5;120m%s\033[0m\n' "例如：1"
    printf '\033[38;5;120m%s\033[0m\n' "或者：sys.nl8.eu"
    printf '\033[0;90m%s\033[0m\n' "============================================================"

    local choice
    local selected

    read -r -p $'\033[38;5;120m请选择证书: \033[0m' choice

    [[ -n "$choice" ]] ||
        die "没有输入选择。"

    if [[ "$choice" =~ ^[0-9]+$ ]]; then

        selected="$(sed -n "${choice}p" "$CERT_LIST")"

        [[ -n "$selected" ]] ||
            die "不存在证书编号：$choice"

    else

        selected="$(
            awk -F '\t' -v domain="$choice" '
                $1 == domain {
                    print
                    exit
                }

                $2 != "" {
                    n = split($2, a, ",")

                    for (i = 1; i <= n; i++) {
                        if (a[i] == domain) {
                            print
                            exit
                        }
                    }
                }
            ' "$CERT_LIST"
        )"

        [[ -n "$selected" ]] ||
            die "没有找到域名：$choice"
    fi

    IFS=$'\t' read -r \
        DOMAIN \
        SAN \
        CERT_SRC \
        KEY_SRC \
        ISSUER \
        NOT_BEFORE \
        NOT_AFTER \
        <<< "$selected"

    CERT_DST="${NGINX_SSL_ROOT}/${DOMAIN}/fullchain.pem"
    KEY_DST="${NGINX_SSL_ROOT}/${DOMAIN}/privkey.pem"

    echo
    printf '\033[0;90m%s\033[0m\n' "============================================================"
    printf '\033[1;36m%s\033[0m\n' "                    已选择证书"
    printf '\033[0;90m%s\033[0m\n' "============================================================"
    printf '\033[0;37m%s\033[0m\n' "域名       : ${DOMAIN}"
    printf '\033[0;90m%s\033[0m\n' "证书来源   : ${CERT_SRC}"
    printf '\033[0;90m%s\033[0m\n' "私钥来源   : ${KEY_SRC}"
    printf '\033[0;90m%s\033[0m\n' "Nginx证书  : ${CERT_DST}"
    printf '\033[0;90m%s\033[0m\n' "Nginx私钥  : ${KEY_DST}"
    printf '\033[0;90m%s\033[0m\n' "============================================================"
    echo
}

# ============================================================
# 复制证书
# ============================================================

install_certificate() {

    info "复制证书给 Nginx 使用..."

    mkdir -p "${NGINX_SSL_ROOT}/${DOMAIN}"

    [[ "$(readlink -f "$CERT_SRC")" == "$(readlink -f "$CERT_DST" 2>/dev/null || true)" ]] || cp -f "$CERT_SRC" "$CERT_DST"
    [[ "$(readlink -f "$KEY_SRC")" == "$(readlink -f "$KEY_DST" 2>/dev/null || true)" ]] || cp -f "$KEY_SRC" "$KEY_DST"

    chmod 644 "$CERT_DST"
    chmod 600 "$KEY_DST"

    openssl x509 \
        -in "$CERT_DST" \
        -noout >/dev/null

    openssl pkey \
        -in "$KEY_DST" \
        -noout >/dev/null

    success "证书复制完成。"
}

# ============================================================
# 节点文件
# ============================================================

prepare_node_file() {

    mkdir -p "$(dirname "$NODE_FILE")"
    chmod 700 "$(dirname "$NODE_FILE")"

    if [[ ! -f "$NODE_FILE" ]]; then

        warn "未找到 ${NODE_FILE}"

        python3 - "$NODE_FILE" <<'NODE_CREATE_PY'
import os,sys
try: os.close(os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600))
except FileExistsError: pass
NODE_CREATE_PY

        chmod 600 "$NODE_FILE"

        warn "已经创建空的节点文件。"

    else

        chmod 600 "$NODE_FILE"

        success "节点文件存在：${NODE_FILE}"
    fi
}

# ============================================================
# Python API
# ============================================================

install_api() {

    info "安装 Python Subscription API..."

    cat > "$API_SCRIPT" <<'PY_EOF'
#!/usr/bin/env python3

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import base64

NODE_FILE = Path("/etc/nodes/subscription.txt")
HOST = "127.0.0.1"
PORT = 8765


class SubscriptionHandler(BaseHTTPRequestHandler):

    def do_GET(self):

        if self.path != "/subs":
            self.send_response(404)
            self.end_headers()
            return

        try:

            if not NODE_FILE.exists():
                raise FileNotFoundError(
                    str(NODE_FILE)
                )

            lines = NODE_FILE.read_text(
                encoding="utf-8"
            ).splitlines()

            nodes = []

            for line in lines:

                line = line.strip()

                if not line:
                    continue

                if line.startswith("#"):
                    continue

                nodes.append(line)

            content = "\n".join(nodes)

            if content:
                content += "\n"

            body = base64.b64encode(
                content.encode("utf-8")
            )

            self.send_response(200)

            self.send_header(
                "Content-Type",
                "text/plain; charset=utf-8"
            )

            self.send_header(
                "Content-Length",
                str(len(body))
            )

            self.send_header(
                "Cache-Control",
                "no-cache, no-store, must-revalidate"
            )

            self.send_header(
                "Pragma",
                "no-cache"
            )

            self.end_headers()

            self.wfile.write(body)

        except Exception as exc:

            body = (
                f"Subscription error: {exc}\n"
            ).encode("utf-8")

            self.send_response(500)

            self.send_header(
                "Content-Type",
                "text/plain; charset=utf-8"
            )

            self.send_header(
                "Content-Length",
                str(len(body))
            )

            self.end_headers()

            self.wfile.write(body)

    def log_message(self, format, *args):
        return


if __name__ == "__main__":

    server = ThreadingHTTPServer(
        (HOST, PORT),
        SubscriptionHandler
    )

    print(
        "Subscription API listening on "
        "http://127.0.0.1:8765/subs",
        flush=True
    )

    server.serve_forever()
PY_EOF

    chmod 700 "$API_SCRIPT"

    success "Python API 创建完成。"
}

# ============================================================
# systemd
# ============================================================

install_systemd() {

    if ! command -v systemctl >/dev/null 2>&1; then
        die "当前系统没有 systemd。"
    fi

    info "创建 systemd 服务..."

    cat > "/etc/systemd/system/${APP_NAME}.service" <<SERVICE_EOF
[Unit]
Description=VPS Node Subscription API
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /root/subscription_api.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    systemctl daemon-reload

    systemctl enable "$APP_NAME.service" >/dev/null

    systemctl restart "$APP_NAME.service"

    sleep 1

    systemctl is-active \
        --quiet "$APP_NAME.service" ||
        die "Subscription API 启动失败。"

    success "Subscription API 服务运行正常。"
}

# ============================================================
# API 测试
# ============================================================

test_api() {

    info "测试本地 API..."

    local result

    result="$(
        curl \
            -fsS \
            --max-time 5 \
            "http://127.0.0.1:${API_PORT}/subs"
    )" || die "本地 API 测试失败。"

    if [[ -n "$result" ]]; then
        success "API 返回 Base64 订阅内容。"
    else
        warn "API 正常，但当前节点文件为空。"
    fi
}

# ============================================================
# Nginx
# ============================================================

configure_nginx() {

    info "配置 Nginx..."

    mkdir -p "$NGINX_CONF_DIR"

    local nginx_conf="${NGINX_CONF_DIR}/${DOMAIN}.conf"

    cat > "$nginx_conf" <<NGINX_EOF
# VPSKit subscription
server {
    listen 80;
    listen [::]:80;

    server_name ${DOMAIN};

    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name ${DOMAIN};

    ssl_certificate     ${CERT_DST};
    ssl_certificate_key ${KEY_DST};

    ssl_protocols TLSv1.2 TLSv1.3;

    location = /subs {

        proxy_pass http://127.0.0.1:${API_PORT}/subs;

        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_no_cache 1;
        proxy_cache_bypass 1;

        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
    }
}
NGINX_EOF



    nginx -t

    systemctl enable nginx >/dev/null 2>&1 || true

    systemctl restart nginx

    success "Nginx 配置完成。"
}

# ============================================================
# HTTPS 测试
# ============================================================

test_https() {

    info "测试 HTTPS /subs..."

    local url="https://${DOMAIN}/subs"

    if curl \
        -kfsS \
        --max-time 10 \
        "$url" \
        >/tmp/subscription_https_test.txt
    then

        if [[ -s /tmp/subscription_https_test.txt ]]; then
            success "HTTPS /subs 工作正常。"
        else
            warn "HTTPS /subs 正常，但节点文件为空。"
        fi

    else

        die "HTTPS /subs 测试失败：${url}"
    fi
}

# ============================================================
# 证书同步脚本
# ============================================================

install_certificate_sync() {

    info "安装证书自动同步..."

    install -d -m 700 /usr/local/lib/subscription-api
    install -m 700 "$VPSKIT_ROOT/lib/subscription-cert-sync.py" /usr/local/lib/subscription-api/cert-sync.py
    cat > /usr/local/sbin/sync-subscription-cert.sh <<'CERT_SYNC_RUN'
#!/bin/sh
exec /usr/bin/python3 /usr/local/lib/subscription-api/cert-sync.py
CERT_SYNC_RUN
    python3 - "$DOMAIN" "$CERT_SRC" "$KEY_SRC" "$CERT_DST" "$KEY_DST" <<'CERT_SYNC_META'
import json,os,sys,tempfile
path='/etc/nodes/subscription-cert.json'
fd,tmp=tempfile.mkstemp(dir=os.path.dirname(path));os.fchmod(fd,0o600)
with os.fdopen(fd,'w') as f:json.dump(dict(zip(('domain','cert_src','key_src','cert_dst','key_dst'),sys.argv[1:])),f)
os.replace(tmp,path)
CERT_SYNC_META

    chmod 700 /usr/local/sbin/sync-subscription-cert.sh

    cat > /etc/systemd/system/subscription-cert-sync.service <<SERVICE_EOF
[Unit]
Description=Sync subscription SSL certificate

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sync-subscription-cert.sh
SERVICE_EOF

    cat > /etc/systemd/system/subscription-cert-sync.timer <<TIMER_EOF
[Unit]
Description=Check subscription SSL certificate

[Timer]
OnBootSec=5min
OnUnitActiveSec=6h
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF

    systemctl daemon-reload

    systemctl enable \
        --now \
        subscription-cert-sync.timer

    success "证书自动同步已启用，每 6 小时检查一次。"
}

# ============================================================
# 完成
# ============================================================

show_result() {

    echo
    printf '\033[0;90m%s\033[0m\n' '  ──────────────────────────────────────────'
    printf '\033[1;32m%s\033[0m\n' '  ✓ 订阅服务部署完成'
    printf '\033[0;90m%s\033[0m\n' '  ──────────────────────────────────────────'
    echo
    printf '  \033[1;36m系统       \033[0;37m%s\033[0m\n' "${OS_NAME}"
    printf '  \033[1;36m域名       \033[0;37m%s\033[0m\n' "${DOMAIN}"
    printf '  \033[1;36m节点文件   \033[0;37m%s\033[0m\n' "${NODE_FILE}"
    printf '  \033[1;36m本地 API   \033[1;34m%s\033[0m\n' "http://127.0.0.1:${API_PORT}/subs"
    echo
    printf '  \033[1;36m证书来源   \033[0;37m%s\033[0m\n' "${CERT_SRC}"
    printf '  \033[1;36mNginx 证书 \033[0;37m%s\033[0m\n' "${CERT_DST}"
    echo
    printf '\033[0;90m%s\033[0m\n' '  ──────────────────────────────────────────'
    printf '\033[1;36m%s\033[0m\n' '  v2rayN 订阅地址 · 可直接复制'
    echo
    printf '  \033[38;5;120m%s\033[0m\n' "https://${DOMAIN}/subs"
    echo
    printf '\033[0;90m%s\033[0m\n' '  ──────────────────────────────────────────'
    printf '\033[38;5;120m%s\033[0m\n' '  以后修改节点文件：'
    printf '  \033[0;37m%s\033[0m\n' "${NODE_FILE}"
    printf '\033[38;5;120m%s\033[0m\n' '  保存后，在 v2rayN 中刷新订阅即可。'
    echo
}

# ============================================================
# 主程序
# ============================================================

main() {

    echo
    printf '\033[0;90m%s\033[0m\n' "============================================================"
    printf '\033[1;36m%s\033[0m\n' "       VPS Node Subscription API Installer V2"
    printf '\033[0;90m%s\033[0m\n' "============================================================"
    echo

    check_root

    detect_system

    command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || die "订阅服务目前需要 systemd，请使用 Debian / Ubuntu。"
    [[ -n "${VPSKIT_ROOT:-}" ]] || VPSKIT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
    [[ -f "$VPSKIT_ROOT/lib/subscription-manager.py" ]] || die "请通过完整 VPSKit 安装包运行。"
    install_dependencies

    search_certificates

    select_certificate

    [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ && "$DOMAIN" != *..* ]] || die "请选择一个具体域名，不能使用通配符。"
    if [[ -f "$NGINX_CONF_DIR/$DOMAIN.conf" ]] && ! grep -Fq 'proxy_pass http://127.0.0.1:8765/subs;' "$NGINX_CONF_DIR/$DOMAIN.conf"; then
        die "该域名已有其他 Nginx 配置，未覆盖它。"
    fi
    if [[ -f /etc/nodes/subscription.json ]]; then
        previous_domain=$(python3 -c 'import json;print(json.load(open("/etc/nodes/subscription.json"))["domain"])')
        if [[ "$previous_domain" != "$DOMAIN" ]]; then
            [[ "$previous_domain" =~ ^[A-Za-z0-9.-]+$ && "$previous_domain" != *..* ]] || die "原订阅域名无效。"
            old_conf="$NGINX_CONF_DIR/$previous_domain.conf"
            [[ ! -f "$old_conf" ]] || grep -Fq '# VPSKit subscription' "$old_conf" || die "旧 Nginx 配置已改变，未覆盖它。"
        fi
    fi
    mkdir -p /var/lib/vpskit/subscription-backups
    chmod 700 /var/lib/vpskit/subscription-backups
    SUB_BACKUP=$(mktemp -d /var/lib/vpskit/subscription-backups/transaction.XXXXXX)
    python3 "$VPSKIT_ROOT/lib/subscription-manager.py" capture "$SUB_BACKUP" "$DOMAIN"
    install_certificate

    prepare_node_file

    install_api

    install_systemd

    test_api

    if [[ -n "${old_conf:-}" ]]; then rm -f -- "$old_conf"; fi
    configure_nginx

    test_https

    install_certificate_sync

    python3 "$VPSKIT_ROOT/lib/subscription-manager.py" save "$DOMAIN"
    SUB_SUCCESS=1
    show_result
}

main "$@"
