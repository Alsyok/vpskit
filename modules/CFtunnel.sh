#!/bin/sh
set -eu
VPSKIT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$VPSKIT_ROOT/lib/common.sh"
. "$VPSKIT_ROOT/lib/node-services.sh"
download() {
    dependencies
    TMP=$(mktemp -d)
    url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH"
    curl -fL --retry 3 --connect-timeout 15 --max-time 300 "$url" -o "$TMP/cloudflared"
    chmod 755 "$TMP/cloudflared"
    "$TMP/cloudflared" --version || die '下载的程序无法运行。'
    mkdir -p /usr/local/lib/vps-tunnel
    mv "$TMP/cloudflared" "$BIN"
    cleanup; TMP=
}
exists() { [ -f "$BASE/mode" ]; }
control() {
    if [ "$MANAGER" = openrc ]; then rc-service "$SERVICE" "$1"
    else systemctl "$1" "$SERVICE.service"; fi
}
confirm_replace() {
    if exists; then
        ask '已有本脚本管理的隧道。替换配置？输入 “YES/y” 继续，“NO/n” 取消：'
        confirmed || return 1
    fi
}
write_runner() {
    cat > "$BASE/run" <<'RUN'
#!/bin/sh
set -eu
BASE=/etc/vps-tunnel
BIN=/usr/local/lib/vps-tunnel/cloudflared
cd "$BASE"
export HOME="$BASE/home"
mode=$(cat "$BASE/mode")
protocol=$(cat "$BASE/protocol" 2>/dev/null || printf auto)
metrics=$(cat "$BASE/metrics-port")
run_core() {
    if [ "$mode" = quick ]; then
        rm -f "$BASE/domain-cache"
        : > /var/log/vps-tunnel/cloudflared.log
        port=$(cat "$BASE/port")
        exec "$BIN" tunnel --no-autoupdate --protocol "$1" --edge-ip-version auto --grace-period 2s --metrics "127.0.0.1:$metrics" --loglevel info --log-directory /var/log/vps-tunnel --url "http://127.0.0.1:$port"
    else
        exec "$BIN" tunnel --no-autoupdate --protocol "$1" --edge-ip-version auto --grace-period 2s --metrics "127.0.0.1:$metrics" --loglevel info --log-directory /var/log/vps-tunnel run --token-file "$BASE/token"
    fi
}
if [ "$protocol" != auto ]; then
    printf '%s\n' "$protocol" > "$BASE/effective-protocol"
    run_core "$protocol"
fi
# Automatic mode actively checks readiness; it does not rely solely on cloudflared's fallback.
active=$(cat "$BASE/effective-protocol" 2>/dev/null || printf quic)
case "$active" in quic|http2) :;; *) active=quic;; esac
CHILD=
stop_child() {
    if [ -n "$CHILD" ]; then
        kill "$CHILD" 2>/dev/null || true
        wait "$CHILD" 2>/dev/null || true
        CHILD=
    fi
}
trap 'stop_child; exit 0' INT TERM
trap stop_child EXIT
while :; do
    printf '%s\n' "$active" > "$BASE/effective-protocol"
    run_core "$active" &
    CHILD=$!
    failures=0
    while kill -0 "$CHILD" 2>/dev/null; do
        if curl --noproxy '*' -fsS --connect-timeout 1 --max-time 1 "http://127.0.0.1:$metrics/ready" >/dev/null 2>&1; then
            failures=0
        else
            failures=$((failures + 1))
        fi
        [ "$failures" -lt 10 ] || break
        sleep 2
    done
    stop_child
    if [ "$active" = quic ]; then active=http2; else active=quic; fi
    printf 'Automatic transport: retrying with %s\n' "$active" >&2
    sleep 2
done
RUN
    chmod 700 "$BASE/run"
    printf '%s\n' '2.1.0' > "$BASE/runner-version"
}
write_service() {
    if [ "$MANAGER" = openrc ]; then
        cat > /etc/init.d/vps-tunnel <<'RC'
#!/sbin/openrc-run
name="Cloudflare Tunnel (VPS toolbox)"
description="Managed Cloudflare Tunnel with automatic restart"
supervisor="supervise-daemon"
command="/etc/vps-tunnel/run"
respawn_delay=5
respawn_max=0
respawn_period=60
output_log="/var/log/vps-tunnel-service.log"
error_log="/var/log/vps-tunnel-service.log"
depend() { need net; after firewall; }
RC
        chmod 755 /etc/init.d/vps-tunnel
        rc-update add "$SERVICE" default
    else
        cat > /etc/systemd/system/vps-tunnel.service <<'UNIT'
[Unit]
Description=Cloudflare Tunnel (VPS toolbox)
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/etc/vps-tunnel/run
Restart=always
RestartSec=5
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
        systemctl enable "$SERVICE.service"
    fi
}
setup() {
    mode=$1
    confirm_replace || return 0
    if [ "$mode" = quick ]; then
        read_port 8080
        read_path
    else
        printf '%s  请先在 CF 后台 → 配置域名 → http://127.0.0.1:本地端口。%s\n' "$C_ERROR" "$C_RESET"
        read_domain
        read_port 8080
        read_path
        while :; do
            ask_form '粘贴 Tunnel Token（只粘贴 Token，不要整条命令）：'
            token=$REPLY
            case "$token" in
                ''|*[!A-Za-z0-9_+/=-]*) retry_input 'Token 为空或字符格式错误，请重新输入。';;
                *) break;;
            esac
        done
    fi
    read_protocol
    [ -x "$BIN" ] || download
    sync_disable
    if exists; then stop_if_running; fi
    umask 077
    mkdir -p "$BASE/home"
    chmod 700 "$BASE" "$BASE/home"
    printf '%s\n' "$mode" > "$BASE/mode"
    rm -f "$BASE/token" "$BASE/domain"
    printf '%s\n' "$ws_path" > "$BASE/ws-path"
    rm -f "$BASE/effective-protocol"
    printf '%s\n' "$protocol" > "$BASE/protocol"
    printf '%s\n' "$port" > "$BASE/port"
    choose_metrics
    if [ "$mode" = quick ]; then printf '%s\n' "$port" > "$BASE/port"
    else printf '%s\n' "$token" > "$BASE/token"; printf '%s\n' "$domain" > "$BASE/domain"; unset token REPLY; fi
    mkdir -p /var/log/vps-tunnel
    : > "$LOG"
    write_runner
    write_service
    control start
    printf '已启用后台运行、进程退出自动重启、开机自启。\n'
    if wait_connected; then
        good '隧道已连接 Cloudflare。'
        address
        ask '继续安装节点？1 sing-box / 2 Xray / 0 暂不安装：'
        case "$REPLY" in 1) install_node sing-box;; 2) install_node xray;; *) :;; esac
    else
        warn '暂未确认连接，请查看日志；禁 UDP 的服务器可在菜单 15 切换 HTTP/2。'
    fi
}
address() {
    if current_domain; then printf '隧道域名：%s\n' "$domain"; fi
}
status() {
    exists || { printf '尚未安装本脚本管理的隧道。\n'; return; }
    printf '模式：%s\n' "$(cat "$BASE/mode")"
    control status || true
    if [ "$(cat "$BASE/mode")" = quick ]; then
        address
        printf '临时域名在重新启动后可能变化；停止时日志地址不可用。\n'
    else address; fi
    if connected; then good '已连接 Cloudflare。'; else warn '连接尚未确认。'; fi
}
logs() {
    [ ! -f "$LOG" ] || tail -n 80 "$LOG"
    if [ "$MANAGER" = systemd ]; then journalctl -u "$SERVICE.service" -n 30 --no-pager
    elif [ -f /var/log/vps-tunnel-service.log ]; then tail -n 30 /var/log/vps-tunnel-service.log; fi
}
stop_if_running() {
    if control status >/dev/null 2>&1; then control stop; fi
}
uninstall() {
    exists || { printf '尚未安装。\n'; return; }
    ask '卸载本脚本的隧道、配置和日志？输入 “YES/y” 继续，“NO/n” 取消：'
    confirmed || return 0
    sync_remove
    stop_if_running
    if [ "$MANAGER" = openrc ]; then
        rc-update del "$SERVICE" default
        rm -f /etc/init.d/vps-tunnel
    else
        systemctl disable "$SERVICE.service"
        rm -f /etc/systemd/system/vps-tunnel.service
        systemctl daemon-reload
    fi
    /usr/local/lib/argo-node-files/run --remove argo
    rm -rf "$BASE" /usr/local/lib/vps-tunnel
    rm -rf /var/log/vps-tunnel
    rm -f /var/log/vps-tunnel-service.log /var/log/vps-tunnel-service.log.[123]
    remove_unused_log_maintenance
    printf '已卸载。Cloudflare 后台的隧道和 DNS 记录需自行删除。\n'
}

read_port() {
    while :; do
        ask_form "本地 WS 端口 [$1]："
        port=${REPLY:-$1}
        case "$port" in ''|*[!0-9]*|??????*) retry_input '请输入 1–65535。'; continue;; esac
        port=$(printf '%s' "$port" | sed 's/^0*//'); port=${port:-0}
        if [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then return; fi
        retry_input '请输入 1–65535。'
    done
}
valid_domain() {
    [ "${#1}" -le 253 ] && printf '%s\n' "$1" | grep -Eq '^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'
}
read_domain() {
    while :; do
        ask_form '固定隧道域名（不含 https:// 和路径）：'
        domain=$REPLY
        if valid_domain "$domain"; then return; fi
        retry_input '请输入完整域名，例如 node.example.com。'
    done
}
read_path() {
    while :; do
        ask_form "本地 WebSocket 路径 [${path_default:-/argo}]："
        ws_path=${REPLY:-${path_default:-/argo}}
        if [ "${#ws_path}" -le 128 ] && printf '%s\n' "$ws_path" | grep -Eq '^/[A-Za-z0-9/._~-]*$'; then return; fi
        retry_input '路径需以 / 开头，使用字母、数字或 / . _ ~ -，请重新输入。'
    done
}
read_protocol() {
    while :; do
        ask_form '隧道传输：1 自动 / 2 HTTP2（禁 UDP 时选） / 3 QUIC [1]：'
        case "${REPLY:-1}" in 1) protocol=auto; return;; 2) protocol=http2; return;; 3) protocol=quic; return;; *) retry_input '请输入 1、2 或 3。';; esac
    done
}
port_busy() {
    target_hex=$(printf '%04X' "$1")
    awk -v p="$target_hex" '$4 == "0A" {split($2,a,":"); if (toupper(a[length(a)]) == p) found=1} END {exit !found}' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}
choose_metrics() {
    # Retain the existing port; otherwise select an unused local port.
    if [ -s "$BASE/metrics-port" ] && [ "$(cat "$BASE/metrics-port")" != "$port" ]; then return; fi
    metrics=20241
    while port_busy "$metrics" || [ "$metrics" = "$port" ]; do
        metrics=$((metrics + 1))
        [ "$metrics" -le 20260 ] || die '找不到可用的本地监控端口。'
    done
    printf '%s\n' "$metrics" > "$BASE/metrics-port"
}
connected() {
    control status >/dev/null 2>&1 || return 1
    [ -s "$BASE/metrics-port" ] || return 1
    curl --noproxy '*' -fsS --connect-timeout 1 --max-time 2 "http://127.0.0.1:$(cat "$BASE/metrics-port")/ready" >/dev/null 2>&1
}
wait_connected() {
    printf '  正在确认 Cloudflare 连接（自动模式会切换传输，最长约 90 秒）…\n'
    count=0
    while [ "$count" -lt 30 ]; do
        if connected; then return; fi
        sleep 1; count=$((count + 1))
    done
    return 1
}
prepare_tunnel() {
    exists || die '请先安装隧道。'
    mode=$(cat "$BASE/mode")
    case "$mode" in quick|fixed) :;; *) die '未知隧道模式。';; esac
    if [ ! -s "$BASE/port" ]; then
        read_port 8080; printf '%s\n' "$port" > "$BASE/port"
    else port=$(cat "$BASE/port"); fi
    if [ "$mode" = fixed ] && [ ! -s "$BASE/domain" ]; then
        read_domain; printf '%s\n' "$domain" > "$BASE/domain"
        warn "请确认 CF 后台的服务地址为 http://127.0.0.1:$port。"
    fi
    if [ ! -s "$BASE/protocol" ]; then
        protocol=auto
        if grep -q -- '--protocol http2' "$BASE/run"; then protocol=http2; fi
        if grep -q -- '--protocol quic' "$BASE/run"; then protocol=quic; fi
        printf '%s\n' "$protocol" > "$BASE/protocol"
    fi
    if [ ! -s "$BASE/metrics-port" ] || [ "$(cat "$BASE/runner-version" 2>/dev/null || true)" != '2.1.0' ]; then
        choose_metrics
        write_runner
        control restart
    fi
    connected || wait_connected || die '隧道尚未连接，请先查看日志或切换传输。'
}
set_transport() {
    exists || die '尚未安装隧道。'
    read_protocol
    rm -f "$BASE/effective-protocol"
    printf '%s\n' "$protocol" > "$BASE/protocol"
    port=$(cat "$BASE/port" 2>/dev/null || printf 8080)
    choose_metrics
    write_runner
    control restart
    if wait_connected; then good '隧道已连接。'; address; else warn '尚未连接，请查看日志。'; fi
}
node_exists() { [ -s "$NBASE/core" ] && [ -x "$NBIN" ]; }
node_control() {
    if [ "$MANAGER" = openrc ]; then
        rc-service "$NSERVICE" "$1" || return $?
    else systemctl "$1" "$NSERVICE.service" || return $?; fi
    case "$1" in start|restart) sync_stamp;; esac
}
node_stop() { if node_control status >/dev/null 2>&1; then node_control stop; fi; }
node_service() {
    cat > "$NBASE/run" <<'NODE'
#!/bin/sh
set -eu
cd /etc/vps-node
case "$(cat core)" in
    sing-box) exec /usr/local/lib/vps-node/core run -c /etc/vps-node/config.json;;
    xray) exec /usr/local/lib/vps-node/core run -config /etc/vps-node/config.json;;
    *) exit 1;;
esac
NODE
    chmod 700 "$NBASE/run"
    if [ "$MANAGER" = openrc ]; then
        cat > /etc/init.d/vps-node <<'RC'
#!/sbin/openrc-run
name="VLESS WebSocket node"
supervisor="supervise-daemon"
command="/etc/vps-node/run"
respawn_delay=5
respawn_max=0
respawn_period=60
output_log="/var/log/vps-node.log"
error_log="/var/log/vps-node.log"
depend() { need net; after firewall; }
RC
        chmod 755 /etc/init.d/vps-node
        rc-update add "$NSERVICE" default
    else
        cat > /etc/systemd/system/vps-node.service <<'UNIT'
[Unit]
Description=VLESS WebSocket node
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStart=/etc/vps-node/run
Restart=always
RestartSec=5
UMask=0077
[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
        systemctl enable "$NSERVICE.service"
    fi
}
fetch_core() {
    curl -fLsS --retry 3 --connect-timeout 15 --max-time 60 "$RAW/manifest.json?t=$(date +%s)" -o "$TMP/manifest.json"
    jq -e '.schema_version == 2 and .distribution == "github-raw"' "$TMP/manifest.json" >/dev/null || die 'Raw 版本清单格式错误，请确认工作流已经成功。'
    asset_url=$(jq -er --arg c "$core" --arg a "$ARCH" '.cores[$c].assets[$a].download_url' "$TMP/manifest.json")
    digest=$(jq -er --arg c "$core" --arg a "$ARCH" '.cores[$c].assets[$a].sha256' "$TMP/manifest.json")
    core_version=$(jq -er --arg c "$core" '.cores[$c].version' "$TMP/manifest.json")
    case "$asset_url" in "$RAW"/versions/*) :;; *) die '安装包地址不属于你的 Raw 仓库。';; esac
    printf '%s' "$digest" | grep -Eq '^[a-f0-9]{64}$' || die '校验值格式错误。'
    good "下载 $core $core_version / $ARCH"
    curl -fL --retry 3 --connect-timeout 15 --max-time 300 "$asset_url" -o "$TMP/archive"
    printf '%s  %s\n' "$digest" "$TMP/archive" | sha256sum -c - || die '安装包校验失败。'
    if [ "$core" = sing-box ]; then
        member=$(tar -tzf "$TMP/archive" | awk '/(^|\/)sing-box$/ {print}')
        [ "$(printf '%s\n' "$member" | wc -l)" -eq 1 ] && [ -n "$member" ] || die '安装包结构错误。'
        tar -xOzf "$TMP/archive" "$member" > "$TMP/core"
    else
        unzip -p "$TMP/archive" xray > "$TMP/core"
    fi
    chmod 755 "$TMP/core"
    "$TMP/core" version
}
build_config() {
    if [ "$core" = sing-box ]; then
        jq -n --arg uuid "$uuid" --arg path "$ws_path" --argjson port "$port" '{log:{level:"info",timestamp:true},inbounds:[{type:"vless",tag:"vless-ws",listen:"127.0.0.1",listen_port:$port,users:[{uuid:$uuid}],transport:{type:"ws",path:$path}}],outbounds:[{type:"direct",tag:"direct"}]}' > "$TMP/config.json"
        "$TMP/core" check -c "$TMP/config.json"
    else
        jq -n --arg uuid "$uuid" --arg path "$ws_path" --argjson port "$port" '{log:{loglevel:"warning"},inbounds:[{tag:"vless-ws",listen:"127.0.0.1",port:$port,protocol:"vless",settings:{clients:[{id:$uuid}],decryption:"none"},streamSettings:{network:"ws",security:"none",wsSettings:{path:$path}}}],outbounds:[{protocol:"freedom",tag:"direct"}]}' > "$TMP/config.json"
        "$TMP/core" run -test -config "$TMP/config.json"
    fi
}
rollback_node() {
    if [ "${deploying:-0}" = 1 ]; then
        warn '部署未完成，正在恢复原节点。'
        node_stop || true
        rm -rf "$NBASE"
        rm -f "$NBIN"
        if [ -d "$TMP/old-node" ]; then
            cp -a "$TMP/old-node" "$NBASE"
            cp "$TMP/old-core" "$NBIN"; chmod 755 "$NBIN"
            if [ "$was_running" = 1 ]; then node_control start || true; fi
        else
            if [ "$MANAGER" = openrc ]; then
                rc-update del "$NSERVICE" default >/dev/null 2>&1 || true
                rm -f /etc/init.d/vps-node
            else
                systemctl disable "$NSERVICE.service" >/dev/null 2>&1 || true
                rm -f /etc/systemd/system/vps-node.service
                systemctl daemon-reload
            fi
        fi
    fi
    cleanup
}
install_node() {
    core=$1
    edit_node=0
    if node_exists; then
        printf '\n'
        menu_item "$C_GREEN" '1.' '保留 UUID、WS 路径和端口'
        menu_item "$C_YELLOW" '2.' '修改 UUID、WS 路径和端口（留空沿用）'
        menu_item "$C_DIM" '0.' '取消'
        while :; do
            ask '请选择 [0–2]：'
            case "$REPLY" in 1) break;; 2) edit_node=1; break;; 0) return;; *) retry_input '请输入 0、1 或 2。';; esac
        done
    fi
    dependencies
    prepare_tunnel
    if node_exists; then
        uuid=$(cat "$NBASE/uuid"); ws_path=$(cat "$NBASE/path"); port=$(cat "$NBASE/port")
        if [ "$edit_node" = 1 ]; then
            original_uuid=$uuid
            while :; do
                ask_form "UUID [$original_uuid]："
                uuid=${REPLY:-$original_uuid}
                if printf '%s\n' "$uuid" | grep -Eq '^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$'; then break; fi
                retry_input 'UUID 格式错误，请重新输入。'
            done
            path_default=$ws_path
            read_path
            read_port "$port"
        fi
    else
        uuid=$(cat /proc/sys/kernel/random/uuid)
        ws_path=$(cat "$BASE/ws-path" 2>/dev/null || printf '/argo')
    fi
    if port_busy "$port" && ! node_control status >/dev/null 2>&1; then
        die "端口 $port 被其他程序占用，请先处理；本脚本不会停止其他服务。"
    fi
    TMP=$(mktemp -d)
    deploying=0; was_running=0
    trap rollback_node EXIT
    fetch_core
    if node_exists; then
        cp -a "$NBASE" "$TMP/old-node"; cp "$NBIN" "$TMP/old-core"
        if node_control status >/dev/null 2>&1; then was_running=1; fi
    fi
    build_config
    deploying=1
    if node_exists; then node_stop; fi
    port_busy "$port" && die "端口 $port 仍被占用，已取消部署。"
    umask 077
    mkdir -p "$NBASE" /usr/local/lib/vps-node
    chmod 700 "$NBASE" /usr/local/lib/vps-node
    cp "$TMP/core" "$NBIN"; chmod 755 "$NBIN"
    cp "$TMP/config.json" "$NBASE/config.json"
    printf '%s\n' "$core" > "$NBASE/core"
    printf '%s\n' "$core_version" > "$NBASE/version"
    printf '%s\n' "$port" > "$NBASE/port"
    printf '%s\n' "$uuid" > "$NBASE/uuid"
    printf '%s\n' "$ws_path" > "$NBASE/path"
    node_service
    node_control start
    count=0
    while [ "$count" -lt 10 ]; do
        if node_control status >/dev/null 2>&1 && port_busy "$port"; then break; fi
        sleep 1; count=$((count + 1))
    done
    [ "$count" -lt 10 ] || die '节点未成功监听，请检查日志。'
    deploying=0
    previous_port=$(cat "$BASE/port")
    printf '%s\n' "$port" > "$BASE/port"
    printf '%s\n' "$ws_path" > "$BASE/ws-path"
    if [ "$previous_port" != "$port" ]; then
        if [ "$(cat "$BASE/mode")" = quick ]; then
            control restart
            if ! wait_connected; then warn '节点端口已更新，但隧道连接尚未恢复。'; fi
        else
            warn "请在 CF 后台把服务地址改为 http://127.0.0.1:$port。"
        fi
    fi
    good '节点已启动，保活和开机自启已启用。'
    sync_stamp
    node_info
    sync_install
}
node_menu() {
    printf '\n%s  选择节点核心%s\n' "$C_CYAN" "$C_RESET"; rule
    menu_item "$C_GREEN" '1.' 'sing-box'
    menu_item "$C_GREEN" '2.' 'Xray'
    menu_item "$C_DIM" '0.' '返回'
    while :; do
        ask '请选择 [0–2]：'
        case "$REPLY" in 1) install_node sing-box; return;; 2) install_node xray; return;; 0) return;; *) retry_input '请选择 0、1 或 2。';; esac
    done
}
current_domain() {
    [ -s "$BASE/mode" ] || return 1
    if [ "$(cat "$BASE/mode")" = fixed ]; then
        [ -s "$BASE/domain" ] || return 1
        domain=$(cat "$BASE/domain")
    else
        control status >/dev/null 2>&1 || return 1
        domain=$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG" 2>/dev/null | tail -n 1 || true)
        domain=${domain#https://}
        if [ -n "$domain" ]; then
            (umask 077; printf '%s\n' "$domain" > "$BASE/domain-cache")
        elif [ -s "$BASE/domain-cache" ]; then domain=$(cat "$BASE/domain-cache"); fi
    fi
    valid_domain "$domain"
}
print_node_info() {
    while IFS= read -r info_line || [ -n "$info_line" ]; do
        info_color=
        case "$info_line" in
            域名：*|'SNI / WS Host：'*) info_color=$C_CYAN;;
            UUID：*) info_color=$C_PURPLE;;
            'WS 路径：'*) info_color=$C_YELLOW;;
            vless://*) info_color=$C_LINK;;
        esac
        printf '%s%s%s\n' "$info_color" "$info_line" "$C_RESET"
    done < "/etc/nodes/argo/info.txt"
}
node_info() {
    node_exists || die '尚未安装节点核心。'
    if [ -x "$SYNCBIN" ] && [ "${api_local_changed:-0}" != 1 ]; then
        if ! "$SYNCBIN" --once foreground; then
            warn '自动同步未完成，保留上次有效节点信息。'
            [ ! -s "/etc/nodes/argo/info.txt" ] || print_node_info
            return 0
        fi
    fi
    command -v jq >/dev/null || dependencies
    core=$(cat "$NBASE/core"); uuid=$(cat "$NBASE/uuid")
    ws_path=$(cat "$NBASE/path"); port=$(cat "$NBASE/port")
    if ! current_domain; then
        warn '当前域名无法获取；上次保存的信息仅供参考。'
        [ ! -s "/etc/nodes/argo/info.txt" ] || print_node_info
        return 0
    fi
    locate_country
    case "$core" in sing-box) node_label="Argo-singbox-$country_flag";; *) node_label="Argo-Xray-$country_flag";; esac
    label_encoded=$(jq -nr --arg s "$node_label" '$s|@uri')
    path_encoded=$(jq -nr --arg s "$ws_path" '$s|@uri')
    link="vless://$uuid@$domain:443?encryption=none&security=tls&sni=$domain&type=ws&host=$domain&path=$path_encoded#$label_encoded"
    umask 077
    mkdir -p /etc/nodes/argo
    {
        printf '节点名称：%s\n出口地区：%s\n\n' "$node_label" "$country_name"
        printf '核心：%s %s\n' "$core" "$(cat "$NBASE/version")"
        printf '域名：%s\n客户端端口：443\n本地监听：127.0.0.1:%s\n' "$domain" "$port"
        printf '协议：VLESS\nUUID：%s\n传输：WebSocket\nWS 路径：%s\n' "$uuid" "$ws_path"
        printf '客户端 TLS：开启\nSNI / WS Host：%s\n本地 TLS：关闭\n\n%s\n' "$domain" "$link"
    } > "/etc/nodes/argo/info.txt.new"
    printf '%s\n' "$link" | /usr/local/lib/argo-node-files/run --publish argo /dev/stdin /etc/nodes/argo/info.txt.new
    rm -f /etc/nodes/argo/info.txt.new
    rule; printf '%s  NODE · 节点信息%s\n' "$C_PURPLE" "$C_RESET"; rule
    print_node_info
    rule
    good "已保存至 /etc/nodes/argo/info.txt"
    connection_report
    show_subscription
    if [ -s "$BASE/port" ] && [ "$(cat "$BASE/port")" != "$port" ]; then
        warn '隧道端口与节点监听端口不一致，请重新配置节点。'
    fi
    if [ "$(cat "$BASE/mode")" = quick ]; then warn '临时域名变化后请重新查询并更新客户端。'; fi
}
node_logs() {
    if [ "$MANAGER" = systemd ]; then journalctl -u "$NSERVICE.service" -n 60 --no-pager
    elif [ -f "$NLOG" ]; then tail -n 60 "$NLOG"
    else warn '暂无节点日志。'; fi
}
locate_country() {
    country_flag=🌐; country_name=未知
    # Query this VPS directly, with bounded retries across providers and IP families.
    code=; geo=
    for family in -4 -6; do
        for endpoint in https://ipapi.co/json/ https://api.ip.sb/geoip https://ipwho.is/; do
            geo=$(curl "$family" --noproxy '*' -fsS --connect-timeout 2 --max-time 4 "$endpoint" 2>/dev/null || true)
            code=$(printf '%s' "$geo" | jq -er '
                select(type == "object" and .success != false and .error != true)
                | .country_code | select(type == "string") | ascii_upcase
                | select(test("^[A-Z]{2}$") and . != "XX" and . != "ZZ")
            ' 2>/dev/null || true)
            [ -n "$code" ] && break
        done
        [ -n "$code" ] && break
    done
    if [ -n "$code" ]; then
        country_name=$(printf '%s' "$geo" | jq -r '
            (.country_name // .country // empty)
            | select(type == "string" and length > 0)
        ' 2>/dev/null || true)
        [ -n "$country_name" ] || country_name=$code
        # A failed cache write must not interrupt node installation or querying.
        (umask 077; mkdir -p "$NBASE" && printf '%s\n' "$code" > "$NBASE/country-code" && printf '%s\n' "$country_name" > "$NBASE/country-name") 2>/dev/null || true
    else
        code=$(cat "$NBASE/country-code" 2>/dev/null || true)
        if ! printf '%s' "$code" | grep -Eq '^[A-Z]{2}$'; then
            return 0
        fi
        country_name=$(cat "$NBASE/country-name" 2>/dev/null || true)
        [ -n "$country_name" ] || country_name=$code
    fi
    country_flag=$(jq -nr --arg c "$code" '$c|explode|map(.+127397)|implode' 2>/dev/null || printf '🌐')
}
connection_report() {
    printf '\n'; rule
    if connected; then good '隧道：已连接 Cloudflare'; else warn '隧道：未确认连接'; fi
    if node_control status >/dev/null 2>&1 && port_busy "$port"; then
        good "节点：运行中，监听 127.0.0.1:$port"
        # Verify TLS and the end-to-end WebSocket upgrade, without claiming a VLESS traffic test.
        check_headers=$(mktemp)
        curl --noproxy '*' -sS --http1.1 --connect-timeout 3 --max-time 5 \
            -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
            -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
            -D "$check_headers" -o /dev/null "https://$domain$ws_path" 2>/dev/null || true
        if grep -Eq '^HTTP/[^ ]+ 101([[:space:]]|$)' "$check_headers"; then
            good 'WS 链路：TLS → CF 隧道 → 节点握手成功'
        else
            warn 'WS 链路：尚未验证成功，请检查 CF 域名、端口和路径。'
        fi
        rm -f "$check_headers"
    else warn '节点：未运行或未监听'; fi
    printf '%s  VLESS 实际代理流量请在客户端测试。%s\n' "$C_DIM" "$C_RESET"
    rule
}
update_node() {
    node_exists || die '尚未安装节点。'
    install_node "$(cat "$NBASE/core")"
}
remove_node() {
    node_exists || die '尚未安装节点。'
    ask '删除节点核心、配置和保存的节点信息？输入 “YES/y” 继续，“NO/n” 取消：'
    confirmed || return 0
    sync_disable
    node_stop
    if [ "$MANAGER" = openrc ]; then
        rc-update del "$NSERVICE" default
        rm -f /etc/init.d/vps-node
    else
        systemctl disable "$NSERVICE.service"
        rm -f /etc/systemd/system/vps-node.service
        systemctl daemon-reload
    fi
    /usr/local/lib/argo-node-files/run --remove argo
    rm -rf "$NBASE" /usr/local/lib/vps-node
    rm -f "$NLOG" "$NLOG".[123]
    remove_unused_log_maintenance
    good '节点核心已卸载。'
}
header() {
    printf '%s  【 ARGO · 隧道与节点管理 】%s\n' "$C_CYAN" "$C_RESET"; status_rule
    printf '  系统  %s%s%s / %s  ·  %sv%s%s\n' "$C_WHITE" "$ID" "$C_RESET" "$MANAGER" "$C_PURPLE" "$VERSION" "$C_RESET"
    if exists; then
        case "$(cat "$BASE/mode")" in quick) label=临时隧道;; *) label=固定隧道;; esac
        if connected; then state=已连接; color=$C_GREEN
        elif control status >/dev/null 2>&1; then state='运行中 · 连接待确认'; color=$C_WARNING
        else state=已停止; color=$C_DIM; fi
        printf '  隧道  %s · %s%s%s\n' "$label" "$color" "$state" "$C_RESET"
    else printf '  隧道  %s未安装%s\n' "$C_DIM" "$C_RESET"; fi
    if node_exists; then
        if node_control status >/dev/null 2>&1; then state=运行中; color=$C_GREEN; else state=已停止; color=$C_DIM; fi
        printf '  核心  %s · %s%s%s\n' "$(cat "$NBASE/core")" "$color" "$state" "$C_RESET"
    else printf '  核心  %s未安装%s\n' "$C_DIM" "$C_RESET"; fi
    status_rule
}
# API features are isolated from the original manual deployment functions.
APIBASE=/etc/vps-cf-api
SYNCBIN=/usr/local/lib/vps-cf-sync/run
SYNCSERVICE=vps-cf-sync
valid_uuid() { printf '%s\n' "$1" | grep -Eq '^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$'; }
valid_id() { printf '%s\n' "$1" | grep -Eq '^[a-fA-F0-9]{32}$'; }
api_request() {
    # Keep the credential out of process arguments and error output.
    api_method=$1; api_path=$2; api_output=$3; api_body=${4:-}
    api_headers=$(mktemp "$TMP/headers.XXXXXX")
    chmod 600 "$api_headers"
    printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$api_token" > "$api_headers"
    if [ -n "$api_body" ]; then
        api_http=$(curl -sS --connect-timeout 10 --max-time 30 -X "$api_method" -H "@$api_headers" --data-binary "@$api_body" -o "$api_output" -w '%{http_code}' "https://api.cloudflare.com/client/v4$api_path" 2>/dev/null) || api_http=000
    else
        api_http=$(curl -sS --connect-timeout 10 --max-time 30 -X "$api_method" -H "@$api_headers" -o "$api_output" -w '%{http_code}' "https://api.cloudflare.com/client/v4$api_path" 2>/dev/null) || api_http=000
    fi
    rm -f "$api_headers"
    case "$api_http" in 2??) if jq -e '.success == true' "$api_output" >/dev/null 2>&1; then return 0; fi;; esac
    api_codes=$(jq -r '[.errors[]?.code|tostring]|join(",")' "$api_output" 2>/dev/null || true)
    warn "CF API 请求失败：HTTP $api_http${api_codes:+ / 错误码 $api_codes}。请检查网络、权限与参数。"
    return 1
}
api_collect() {
    # Pagination must not silently omit tunnels or zones.
    list_path=$1; list_out=$2; list_page=1
    printf '[]\n' > "$list_out"
    while :; do
        case "$list_path" in *\?*) list_sep='&';; *) list_sep='?';; esac
        api_request GET "$list_path${list_sep}page=$list_page&per_page=50" "$TMP/list-page.json" || return 1
        jq -e '.result|type == "array"' "$TMP/list-page.json" >/dev/null || return 1
        jq -s '.[0] + .[1].result' "$list_out" "$TMP/list-page.json" > "$TMP/list-next.json"
        mv "$TMP/list-next.json" "$list_out"
        list_pages=$(jq -r '.result_info.total_pages // 1' "$TMP/list-page.json")
        [ "$list_page" -lt "$list_pages" ] || break
        list_page=$((list_page + 1))
        [ "$list_page" -le 100 ] || { warn '列表超过 100 页，请限制 Token 的资源范围。'; return 1; }
    done
}
api_load_auth() {
    [ -s "$APIBASE/auth.json" ] || die '请先选择 1 · API 接入。'
    api_token=$(jq -er '.token' "$APIBASE/auth.json")
    account_id=$(jq -er '.account_id' "$APIBASE/auth.json")
    zone_id=$(jq -er '.zone_id' "$APIBASE/auth.json")
    zone_name=$(jq -er '.zone_name' "$APIBASE/auth.json")
    valid_id "$account_id" && valid_id "$zone_id" || die '保存的 API 参数格式错误，请重新接入。'
}
api_read_id() {
    while :; do
        ask_form "$1"
        id_value=${REPLY:-${2:-}}
        if valid_id "$id_value"; then return; fi
        retry_input '请输入 32 位账户或区域 ID。'
    done
}
api_select_number() {
    while :; do
        ask "$1"
        case "$REPLY" in ''|*[!0-9]*|??????*) retry_input '请输入列表中的序号。'; continue;; esac
        selection=$(printf '%s' "$REPLY" | sed 's/^0*//'); selection=${selection:-0}
        if [ "$selection" -ge 0 ] && [ "$selection" -le "$2" ]; then return; fi
        retry_input '请输入列表中的序号。'
    done
}
api_connect() {
    dependencies
    TMP=$(mktemp -d); chmod 700 "$TMP"
    printf '\n%s  【 CF API 接入 】%s\n' "$C_CYAN" "$C_RESET"; rule
    printf '  %sToken 权限：%s账户 %sCloudflare Tunnel 编辑%s；区域 %sDNS 编辑、Zone 读取%s。\n' "$C_CYAN" "$C_RESET" "$C_PURPLE" "$C_RESET" "$C_PURPLE" "$C_RESET"
    printf '  %sAPI Token 与 Tunnel Token 不同；凭据只保存在本机，不上传仓库。%s\n' "$C_DIM" "$C_RESET"
    old_account=$(jq -r '.account_id // empty' "$APIBASE/auth.json" 2>/dev/null || true)
    while :; do
        ask_form 'API Token（留空沿用已保存值）：'
        api_token=$REPLY
        if [ -z "$api_token" ]; then api_token=$(jq -r '.token // empty' "$APIBASE/auth.json" 2>/dev/null || true); fi
        case "$api_token" in ''|*[!A-Za-z0-9_-]*) retry_input 'Token 为空或格式错误，请重新输入。'; continue;; esac
        api_read_id "Account ID${old_account:+ [$old_account]}：" "$old_account"; account_id=$id_value
        if api_collect "/accounts/$account_id/cfd_tunnel?is_deleted=false" "$TMP/tunnels.json"; then break; fi
        retry_input '账户或隧道读取验证失败，请重新输入。'
    done
    while :; do
        if api_collect "/zones?account.id=$account_id&status=active" "$TMP/zones.json"; then
            jq -r 'to_entries[]|"  \(.key+1). \(.value.name)"' "$TMP/zones.json"
            zone_count=$(jq 'length' "$TMP/zones.json")
            if [ "$zone_count" -gt 0 ]; then
                printf '  0. 手动输入 Zone ID\n'
                api_select_number '选择域名区域：' "$zone_count"
                if [ "$selection" -gt 0 ]; then zone_id=$(jq -r --argjson n "$selection" '.[$n-1].id' "$TMP/zones.json")
                else api_read_id 'Zone ID：'; zone_id=$id_value; fi
            else api_read_id '未找到可用区域，请输入 Zone ID：'; zone_id=$id_value; fi
        else api_read_id '无法列出区域，请输入 Zone ID：'; zone_id=$id_value; fi
        if api_request GET "/zones/$zone_id" "$TMP/zone.json" && jq -e --arg a "$account_id" '.result.account.id == $a and .result.status == "active"' "$TMP/zone.json" >/dev/null; then
            zone_name=$(jq -er '.result.name' "$TMP/zone.json"); break
        fi
        retry_input '区域读取验证失败，或该区域不属于此账户，请重新选择。'
    done
    umask 077; mkdir -p "$APIBASE"; chmod 700 "$APIBASE"
    jq -n --arg t "$api_token" --arg a "$account_id" --arg z "$zone_id" --arg n "$zone_name" '{token:$t,account_id:$a,zone_id:$z,zone_name:$n}' > "$APIBASE/auth.json.new"
    mv "$APIBASE/auth.json.new" "$APIBASE/auth.json"
    unset api_token REPLY
    good "已保存凭据，账户与 $zone_name 的读取验证通过。"
    printf '  写入权限将在实际部署时检查；权限不足会报错并尝试恢复。\n'
}
api_choose_tunnel() {
    api_collect "/accounts/$account_id/cfd_tunnel?is_deleted=false" "$TMP/tunnels.json" || die '无法读取隧道列表。'
    jq '[.[]|select(.config_src == "cloudflare" and .deleted_at == null)]' "$TMP/tunnels.json" > "$TMP/select-tunnels.json"
    printf '\n'; jq -r 'to_entries[]|"  \(.key+1). \(.value.name) · \(.value.id)"' "$TMP/select-tunnels.json"
    printf '  0. 新建隧道\n'
    tunnel_count=$(jq 'length' "$TMP/select-tunnels.json")
    api_select_number '选择已有隧道 / 0 新建：' "$tunnel_count"
    if [ "$selection" -eq 0 ]; then
        tunnel_id=; tunnel_name=
        while :; do
            ask_form '新隧道名称 [argo-node]：'; tunnel_name=${REPLY:-argo-node}
            if [ "${#tunnel_name}" -le 100 ] && printf '%s' "$tunnel_name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]*$'; then break; fi
            retry_input '名称请使用字母、数字、点、下划线或短横线。'
        done
    else tunnel_id=$(jq -r --argjson n "$selection" '.[$n-1].id' "$TMP/select-tunnels.json"); fi
}
api_read_parameters() {
    previous_domain=${domain:-}
    while :; do
        ask_form "固定隧道子域名${previous_domain:+ [$previous_domain]}："
        domain=$(printf '%s' "${REPLY:-$previous_domain}" | tr 'A-Z' 'a-z')
        if valid_domain "$domain"; then
            case "$domain" in *."$zone_name") break;; esac
        fi
        retry_input "请输入 $zone_name 下的完整子域名，例如 node.$zone_name。"
    done
    read_port "${port:-8080}"
    path_default=${ws_path:-/argo}; read_path
    uuid_default=${uuid:-$(cat /proc/sys/kernel/random/uuid)}
    while :; do
        ask_form "UUID [$uuid_default]："; uuid=${REPLY:-$uuid_default}
        valid_uuid "$uuid" && break
        retry_input 'UUID 格式错误，请重新输入。'
    done
    core_default=${core:-sing-box}
    while :; do
        ask_form "节点核心：1 sing-box / 2 Xray [当前 $core_default，留空保留]："
        case "$REPLY" in '') core=$core_default; break;; 1) core=sing-box; break;; 2) core=xray; break;; *) retry_input '请输入 1 或 2。';; esac
    done
    protocol_default=$(cat "$BASE/protocol" 2>/dev/null || printf auto)
    case "$protocol_default" in http2) protocol_choice=2;; quic) protocol_choice=3;; *) protocol_choice=1;; esac
    while :; do
        ask_form "隧道传输：1 自动 / 2 HTTP2 / 3 QUIC [$protocol_choice]："
        case "${REPLY:-$protocol_choice}" in
            1) protocol=auto; break;; 2) protocol=http2; break;; 3) protocol=quic; break;;
            *) retry_input '请输入 1、2 或 3。';;
        esac
    done
}
api_config_body() {
    # Preserve unrelated ingress and all origin settings. Refuse ambiguous path routes.
    jq -e --arg h "$domain" --arg old "$old_hostname" '
      [(.config.ingress // [])[]|select(.hostname == $h or ($old != "" and .hostname == $old))]
      | length <= 1 and all(.[]; (.path // "") == "")
    ' "$TMP/remote-before.json" >/dev/null || die '此域名存在多个路由或路径匹配规则，请先在 CF 后台整理后再部署。'
    jq --arg h "$domain" --arg old "$old_hostname" --arg s "http://127.0.0.1:$port" '
      (.config // {ingress:[{service:"http_status:404"}]}) as $c
      | ($c.ingress // []) as $rules
      | [$rules[]|select(.hostname == $h or ($old != "" and .hostname == $old))][0] as $existing
      | ($rules | map(select(.hostname != $h and ($old == "" or .hostname != $old)))) as $other
      | ($existing // {}) + {hostname:$h,service:$s} | del(.path) as $route
      | {config:($c + {ingress:([$route] + $other)})}
      | if (.config.ingress|any(.[]; (.hostname // "") == "" and (.path // "") == "")) then .
        else .config.ingress += [{service:"http_status:404"}] end
    ' "$TMP/remote-before.json" > "$TMP/remote-after.json"
}
api_service_path() {
    if [ "$MANAGER" = openrc ]; then printf '/etc/init.d/%s' "$1"
    else printf '/etc/systemd/system/%s.service' "$1"; fi
}
api_snapshot() {
    mkdir -p "$TMP/old-argo-files"
    [ ! -f /etc/nodes/argo/links.txt ] || cp /etc/nodes/argo/links.txt "$TMP/old-argo-files/links.txt"
    [ ! -f /etc/nodes/argo/info.txt ] || cp /etc/nodes/argo/info.txt "$TMP/old-argo-files/info.txt"
    [ ! -d "$BASE" ] || cp -a "$BASE" "$TMP/old-tunnel"
    [ ! -d "$NBASE" ] || cp -a "$NBASE" "$TMP/old-node"
    [ ! -f "$NBIN" ] || cp "$NBIN" "$TMP/old-core"
    [ ! -f "$APIBASE/target.json" ] || cp "$APIBASE/target.json" "$TMP/old-target.json"
    old_tunnel_running=0; old_node_running=0
    control status >/dev/null 2>&1 && old_tunnel_running=1
    node_control status >/dev/null 2>&1 && old_node_running=1
    for snap_service in "$SERVICE" "$NSERVICE"; do
        snap_path=$(api_service_path "$snap_service")
        [ ! -f "$snap_path" ] || cp "$snap_path" "$TMP/$snap_service.service"
        snap_enabled=0
        if [ "$MANAGER" = systemd ]; then
            systemctl is-enabled "$snap_service.service" >/dev/null 2>&1 && snap_enabled=1
        elif rc-update show default 2>/dev/null | grep -q "^[[:space:]]*$snap_service[[:space:]]"; then snap_enabled=1; fi
        printf '%s\n' "$snap_enabled" > "$TMP/$snap_service.enabled"
    done
}
api_rollback() {
    saved_status=$?
    trap - EXIT INT TERM
    set +e
    if [ "${api_committed:-0}" != 1 ]; then
        if [ "${api_local_changed:-0}" = 1 ]; then
            warn '部署未完成，正在恢复本地隧道和节点。'
            control stop >/dev/null 2>&1; node_control stop >/dev/null 2>&1
            rm -rf "$BASE" "$NBASE"; rm -f "$NBIN"
            [ ! -d "$TMP/old-tunnel" ] || cp -a "$TMP/old-tunnel" "$BASE"
            [ ! -d "$TMP/old-node" ] || cp -a "$TMP/old-node" "$NBASE"
            [ ! -f "$TMP/old-core" ] || { cp "$TMP/old-core" "$NBIN"; chmod 755 "$NBIN"; }
            for restore_service in "$SERVICE" "$NSERVICE"; do
                restore_path=$(api_service_path "$restore_service")
                if [ -f "$TMP/$restore_service.service" ]; then cp "$TMP/$restore_service.service" "$restore_path"
                else rm -f "$restore_path"; fi
                restore_enabled=$(cat "$TMP/$restore_service.enabled")
                if [ "$MANAGER" = openrc ]; then
                    if [ "$restore_enabled" = 1 ]; then rc-update add "$restore_service" default >/dev/null 2>&1
                    else rc-update del "$restore_service" default >/dev/null 2>&1; fi
                fi
            done
            if [ "$MANAGER" = systemd ]; then
                systemctl daemon-reload
                for restore_service in "$SERVICE" "$NSERVICE"; do
                    if [ "$(cat "$TMP/$restore_service.enabled")" = 1 ]; then systemctl enable "$restore_service.service" >/dev/null 2>&1
                    else systemctl disable "$restore_service.service" >/dev/null 2>&1; fi
                done
            fi
            [ "$old_tunnel_running" != 1 ] || control start >/dev/null 2>&1
            [ "$old_node_running" != 1 ] || node_control start >/dev/null 2>&1
            rm -f "$APIBASE/target.json"
            [ ! -f "$TMP/old-target.json" ] || cp "$TMP/old-target.json" "$APIBASE/target.json"
            if [ -s "$TMP/old-argo-files/links.txt" ]; then
                if [ -f "$TMP/old-argo-files/info.txt" ]; then
                    /usr/local/lib/argo-node-files/run --publish argo "$TMP/old-argo-files/links.txt" "$TMP/old-argo-files/info.txt" || warn '旧节点链接恢复失败。'
                else
                    /usr/local/lib/argo-node-files/run --publish argo "$TMP/old-argo-files/links.txt" || warn '旧节点链接恢复失败。'
                fi
            else
                /usr/local/lib/argo-node-files/run --remove argo || warn '新节点链接清理失败。'
            fi
        fi
        if [ "${api_remote_changed:-0}" = 1 ] && [ "${api_new_tunnel:-0}" != 1 ]; then
            expected_remote="$TMP/remote-after.json"
            [ ! -s "$TMP/remote-applied.json" ] || expected_remote="$TMP/remote-applied.json"
            if api_request GET "/accounts/$account_id/cfd_tunnel/$tunnel_id/configurations" "$TMP/rollback-current.json" &&
               [ "$(jq -cS '.result.config' "$TMP/rollback-current.json")" = "$(jq -cS '.config' "$expected_remote")" ]; then
                jq '{config:.config}' "$TMP/remote-before.json" > "$TMP/rollback-body.json"
                api_request PUT "/accounts/$account_id/cfd_tunnel/$tunnel_id/configurations" "$TMP/rollback-result.json" "$TMP/rollback-body.json" || warn 'CF 路由恢复失败，请在后台检查。'
            else warn 'CF 配置已被其它操作修改或无法读取，未覆盖它；请检查后台路由。'; fi
        fi
        if [ "${api_name_changed:-0}" = 1 ]; then
            if api_request GET "/accounts/$account_id/cfd_tunnel/$tunnel_id" "$TMP/name-rollback-current.json"; then
                rollback_name=$(jq -r '.result.name' "$TMP/name-rollback-current.json")
                if [ "$rollback_name" = "$new_tunnel_name" ]; then
                    jq -n --arg n "$old_tunnel_name" '{name:$n}' > "$TMP/name-rollback-body.json"
                    api_request PATCH "/accounts/$account_id/cfd_tunnel/$tunnel_id" "$TMP/name-rollback-result.json" "$TMP/name-rollback-body.json" || warn '隧道名称恢复失败，请检查 CF 后台。'
                elif [ "$rollback_name" != "$old_tunnel_name" ]; then warn '隧道名称已被其它操作修改，未覆盖它。'; fi
            else warn '无法确认隧道名称，请检查 CF 后台。'; fi
        fi
        if [ "${api_dns_created:-}" != '' ]; then
            if api_request GET "/zones/$zone_id/dns_records/$api_dns_created" "$TMP/rollback-dns.json" &&
               jq -e --arg h "$domain" --arg t "$tunnel_id.cfargotunnel.com" '.result.name == $h and .result.type == "CNAME" and .result.content == $t' "$TMP/rollback-dns.json" >/dev/null; then
                api_request DELETE "/zones/$zone_id/dns_records/$api_dns_created" "$TMP/delete-dns.json" || warn '新建 DNS 清理失败，请在后台检查。'
            fi
        fi
        if [ "${api_new_tunnel:-0}" = 1 ]; then
            api_request DELETE "/accounts/$account_id/cfd_tunnel/$tunnel_id" "$TMP/delete-tunnel.json" || warn "新建隧道清理失败，请检查 $tunnel_id。"
        fi
    fi
    cleanup
    exit "$saved_status"
}
api_deploy() {
    api_edit=$1
    api_load_auth
    dependencies
    [ -x "$BIN" ] || download
    TMP=$(mktemp -d); chmod 700 "$TMP"
    old_hostname=; domain=; port=8080; ws_path=/argo; uuid=; core=sing-box
    if node_exists; then
        core=$(cat "$NBASE/core"); uuid=$(cat "$NBASE/uuid"); port=$(cat "$NBASE/port"); ws_path=$(cat "$NBASE/path")
    fi
    if [ "$api_edit" = edit ]; then
        [ -s "$APIBASE/target.json" ] || die '尚无 API 部署记录，请先自动部署。'
        jq -e --arg a "$account_id" '.account_id == $a' "$APIBASE/target.json" >/dev/null || die '保存的部署属于其它账户，请切换 API 凭据。'
        tunnel_id=$(jq -er '.tunnel_id' "$APIBASE/target.json")
        domain=$(cat "$BASE/domain"); old_hostname=$domain
        zone_id=$(jq -er '.zone_id' "$APIBASE/target.json")
        zone_name=$(jq -er '.zone_name' "$APIBASE/target.json")
        printf '  修改当前部署：%s\n' "$domain"
    else
        api_choose_tunnel
        if [ -s "$BASE/domain" ]; then domain=$(cat "$BASE/domain"); fi
    fi
    old_tunnel_name=; new_tunnel_name=
    if [ "$api_edit" = edit ]; then
        api_request GET "/accounts/$account_id/cfd_tunnel/$tunnel_id" "$TMP/name-before.json" || die '读取隧道名称失败。'
        old_tunnel_name=$(jq -er '.result.name | select(type == "string" and length > 0)' "$TMP/name-before.json")
        while :; do
            ask_form "隧道名称 [$old_tunnel_name，留空保留]："
            new_tunnel_name=${REPLY:-$old_tunnel_name}
            [ -n "$REPLY" ] || break
            if [ "${#new_tunnel_name}" -le 100 ] && printf '%s' "$new_tunnel_name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]*$'; then break; fi
            retry_input '名称请使用字母、数字、点、下划线或短横线（最多 100 字符）。'
        done
    fi
    api_read_parameters
    # A display-name-only edit never fetches a token or changes routes/local services.
    if [ "$api_edit" = edit ] && node_exists &&
       [ "$domain" = "$(cat "$BASE/domain")" ] && [ "$port" = "$(cat "$NBASE/port")" ] &&
       [ "$uuid" = "$(cat "$NBASE/uuid")" ] && [ "$ws_path" = "$(cat "$NBASE/path")" ] &&
       [ "$core" = "$(cat "$NBASE/core")" ] && [ "$protocol" = "$(cat "$BASE/protocol")" ]; then
        if [ "$new_tunnel_name" != "$old_tunnel_name" ]; then
            ask '应用隧道名称修改？输入 “YES/y” 继续，“NO/n” 取消：'; confirmed || return 0
            jq -n --arg n "$new_tunnel_name" '{name:$n}' > "$TMP/name-body.json"
            api_request PATCH "/accounts/$account_id/cfd_tunnel/$tunnel_id" "$TMP/name-result.json" "$TMP/name-body.json" || die '修改隧道名称失败，请重新查看 CF 中的名称。'
            good "隧道名称已更新：$new_tunnel_name"
        else good '配置未变化。'; fi
        return 0
    fi
    if [ -s "$BASE/metrics-port" ] && [ "$(cat "$BASE/metrics-port")" = "$port" ]; then die '节点端口与隧道监控端口冲突，请换一个端口。'; fi
    if port_busy "$port"; then
        node_exists && node_control status >/dev/null 2>&1 && [ "$(cat "$NBASE/port")" = "$port" ] || die "端口 $port 被其它服务占用。"
    fi
    if node_exists && [ "$(cat "$NBASE/core")" = "$core" ]; then
        cp "$NBIN" "$TMP/core"; chmod 755 "$TMP/core"; core_version=$(cat "$NBASE/version")
    else fetch_core; fi
    # Preserve unrelated local inbounds if the core is unchanged.
    build_config
    if node_exists && [ "$(cat "$NBASE/core")" = "$core" ]; then
        jq -e '[.inbounds[]?|select(.tag == "vless-ws")]|length == 1' "$NBASE/config.json" >/dev/null || die '找不到唯一的 vless-ws 入站，未覆盖手动配置。'
        jq -s '.[0] as $old | .[1].inbounds[0] as $new | $old | .inbounds |= map(if .tag == "vless-ws" then $new else . end)' "$NBASE/config.json" "$TMP/config.json" > "$TMP/merged.json"
        mv "$TMP/merged.json" "$TMP/config.json"
        if [ "$core" = sing-box ]; then "$TMP/core" check -c "$TMP/config.json"; else "$TMP/core" run -test -config "$TMP/config.json"; fi
    elif node_exists && [ "$(jq '.inbounds|length' "$NBASE/config.json")" -gt 1 ]; then
        die '原配置有多个入站，切换核心需先手动迁移其它入站；已取消。'
    fi
    rule; printf '  将部署：%s → http://127.0.0.1:%s\n  核心：%s · WS 路径：%s\n' "$domain" "$port" "$core" "$ws_path"
    ask '应用以上配置？输入 “YES/y” 继续，“NO/n” 取消：'; confirmed || return 0
    api_committed=0; api_local_changed=0; api_remote_changed=0; api_new_tunnel=0; api_dns_created=; api_name_changed=0
    api_snapshot
    trap api_rollback EXIT
    trap 'exit 130' INT; trap 'exit 143' TERM
    if [ -z "$tunnel_id" ]; then
        jq -n --arg n "$tunnel_name" '{name:$n,config_src:"cloudflare"}' > "$TMP/create.json"
        api_request POST "/accounts/$account_id/cfd_tunnel" "$TMP/created.json" "$TMP/create.json" || die '创建隧道失败。'
        tunnel_id=$(jq -er '.result.id' "$TMP/created.json"); api_new_tunnel=1
    fi
    valid_uuid "$tunnel_id" || die 'Tunnel ID 格式错误。'
    api_request GET "/accounts/$account_id/cfd_tunnel/$tunnel_id" "$TMP/tunnel.json" || die '读取隧道失败。'
    jq -e '.result.config_src == "cloudflare"' "$TMP/tunnel.json" >/dev/null || die '只支持 CF 后台管理的隧道。'
    api_request GET "/accounts/$account_id/cfd_tunnel/$tunnel_id/token" "$TMP/token.json" || die '无法获取 Tunnel Token，请检查隧道编辑权限。'
    token=$(jq -er '.result | select(type == "string" and length > 0)' "$TMP/token.json")
    if [ "$api_new_tunnel" = 1 ]; then
        printf '{"config":null}\n' > "$TMP/remote-before.json"
    else
        api_request GET "/accounts/$account_id/cfd_tunnel/$tunnel_id/configurations" "$TMP/remote.json" || die '读取路由失败。'
        jq '.result' "$TMP/remote.json" > "$TMP/remote-before.json"
    fi
    api_config_body
    api_request GET "/zones/$zone_id/dns_records?name=$domain&per_page=100" "$TMP/dns.json" || die '读取 DNS 失败。'
    dns_count=$(jq '.result|length' "$TMP/dns.json")
    if [ "$dns_count" -gt 0 ]; then
        jq -e --arg t "$tunnel_id.cfargotunnel.com" '.result|length == 1 and .[0].type == "CNAME" and .[0].content == $t and .[0].proxied == true' "$TMP/dns.json" >/dev/null || die '域名已有其它 DNS 记录或未开启代理；为避免覆盖，请先处理冲突。'
        dns_id=$(jq -er '.result[0].id' "$TMP/dns.json")
    else
        jq -n --arg h "$domain" --arg t "$tunnel_id.cfargotunnel.com" '{type:"CNAME",name:$h,content:$t,proxied:true,ttl:1}' > "$TMP/dns-body.json"
        api_request POST "/zones/$zone_id/dns_records" "$TMP/dns-new.json" "$TMP/dns-body.json" || die '创建 DNS 失败，请检查 DNS 编辑权限。'
        dns_id=$(jq -er '.result.id' "$TMP/dns-new.json"); api_dns_created=$dns_id
    fi
    # Fetch again before PUT to avoid knowingly overwriting concurrent dashboard edits.
    if [ "$api_new_tunnel" != 1 ]; then
        api_request GET "/accounts/$account_id/cfd_tunnel/$tunnel_id/configurations" "$TMP/remote-check.json" || die '提交前读取路由失败。'
        [ "$(jq -cS '.result.config' "$TMP/remote-check.json")" = "$(jq -cS '.config' "$TMP/remote-before.json")" ] || die 'CF 路由刚被修改，请重新操作。'
    fi
    if [ "$api_edit" = edit ] && [ "$new_tunnel_name" != "$old_tunnel_name" ]; then
        api_request GET "/accounts/$account_id/cfd_tunnel/$tunnel_id" "$TMP/name-check.json" || die '提交前读取隧道名称失败。'
        [ "$(jq -r '.result.name' "$TMP/name-check.json")" = "$old_tunnel_name" ] || die '隧道名称刚被修改，请重新操作。'
        jq -n --arg n "$new_tunnel_name" '{name:$n}' > "$TMP/name-body.json"
        api_name_changed=1
        api_request PATCH "/accounts/$account_id/cfd_tunnel/$tunnel_id" "$TMP/name-result.json" "$TMP/name-body.json" || die '修改隧道名称失败。'
    fi
    api_remote_changed=1
    api_request PUT "/accounts/$account_id/cfd_tunnel/$tunnel_id/configurations" "$TMP/remote-result.json" "$TMP/remote-after.json" || die '更新路由失败。'
    # Use CF's normalized response when deciding whether rollback is still safe.
    if jq -e '.result.config|type == "object"' "$TMP/remote-result.json" >/dev/null; then
        jq '{config:.result.config}' "$TMP/remote-result.json" > "$TMP/remote-applied.json"
    fi
    api_local_changed=1
    stop_if_running; node_stop
    umask 077; mkdir -p "$BASE/home" "$NBASE" /usr/local/lib/vps-node /var/log/vps-tunnel "$APIBASE"
    chmod 700 "$BASE" "$BASE/home" "$NBASE" /usr/local/lib/vps-node "$APIBASE"
    printf '%s\n' fixed > "$BASE/mode"; printf '%s\n' "$domain" > "$BASE/domain"
    printf '%s\n' "$token" > "$BASE/token"; unset token REPLY
    printf '%s\n' "$port" > "$BASE/port"; printf '%s\n' "$ws_path" > "$BASE/ws-path"
    printf '%s\n' "$protocol" > "$BASE/protocol"; rm -f "$BASE/effective-protocol" "$BASE/domain-cache"
    choose_metrics; write_runner; write_service
    cp "$TMP/core" "$NBIN"; chmod 755 "$NBIN"
    cp "$TMP/config.json" "$NBASE/config.json"
    printf '%s\n' "$core" > "$NBASE/core"; printf '%s\n' "$core_version" > "$NBASE/version"
    printf '%s\n' "$uuid" > "$NBASE/uuid"; printf '%s\n' "$ws_path" > "$NBASE/path"; printf '%s\n' "$port" > "$NBASE/port"
    node_service; node_control start; control start
    count=0
    while [ "$count" -lt 10 ]; do
        if node_control status >/dev/null 2>&1 && port_busy "$port"; then break; fi
        sleep 1; count=$((count + 1))
    done
    [ "$count" -lt 10 ] || die '节点未成功监听。'
    wait_connected || die '隧道连接未成功，正在恢复旧配置。'
    jq -n --arg a "$account_id" --arg t "$tunnel_id" --arg z "$zone_id" --arg zn "$zone_name" --arg h "$domain" --arg s "http://127.0.0.1:$port" --arg d "$dns_id" '{account_id:$a,tunnel_id:$t,zone_id:$z,zone_name:$zn,hostname:$h,service:$s,dns_id:$d}' > "$APIBASE/target.json.new"
    mv "$APIBASE/target.json.new" "$APIBASE/target.json"
    sync_stamp
    node_info
    api_committed=1
    sync_install
    good 'API 配置已应用；节点信息后台同步已启用（每 60 秒）。'
    if [ -n "$old_hostname" ] && [ "$old_hostname" != "$domain" ]; then
        printf '  旧域名 %s 的 DNS 保留，确认不再需要后可在 CF 后台删除。\n' "$old_hostname"
    fi
}

api_current_tunnel() {
    local_tunnel_id=
    if [ -s "$APIBASE/target.json" ] && jq -e --arg a "$account_id" '.account_id == $a' "$APIBASE/target.json" >/dev/null; then
        local_tunnel_id=$(jq -r '.tunnel_id // ""' "$APIBASE/target.json")
    elif [ -s "$BASE/token" ]; then
        local_tunnel_id=$(jq -Rr 'try (fromjson) catch .' "$BASE/token" | jq -Rr 'try (@base64d|fromjson|.t // "") catch ""' 2>/dev/null || true)
    fi
}
api_delete_selected() {
    printf '\n  将删除以下 CF 隧道：\n'
    jq -r '.[]|"  · \(.name) · \(.id)"' "$TMP/delete-selected.json"
    printf '  以下关联 DNS 来自当前 API 有权限读取的账户域名区域：\n'
    # Discover all authorized zones, not merely the enrollment zone.
    api_collect "/zones?account.id=$account_id&status=active" "$TMP/delete-zones.json" || die '读取域名区域失败，未执行删除。'
    printf '[]\n' > "$TMP/delete-dns.json"
    jq -r '.[].id' "$TMP/delete-zones.json" > "$TMP/delete-zone-ids"
    while IFS= read -r delete_zone; do
        valid_id "$delete_zone" || die 'Zone ID 格式错误。'
        api_collect "/zones/$delete_zone/dns_records?type=CNAME" "$TMP/zone-dns.json" || die '读取关联 DNS 失败，未执行删除。'
        jq --arg z "$delete_zone" --slurpfile t "$TMP/delete-selected.json" '[.[]|select(.type == "CNAME")|. as $d|$t[0][]|select(($d.content|ascii_downcase|rtrimstr(".")) == ((.id|ascii_downcase)+".cfargotunnel.com"))|$d+{zone_id:$z,tunnel_id:.id}]' "$TMP/zone-dns.json" > "$TMP/matched-dns.json"
        jq -s '.[0]+.[1]' "$TMP/delete-dns.json" "$TMP/matched-dns.json" > "$TMP/delete-dns-next.json"
        mv "$TMP/delete-dns-next.json" "$TMP/delete-dns.json"
    done < "$TMP/delete-zone-ids"
    jq -r '.[]|"  · \(.name) → \(.content)"' "$TMP/delete-dns.json"
    [ "$(jq length "$TMP/delete-dns.json")" != 0 ] || printf '  （未找到关联 DNS）\n'
    warn '将删除选中的 CF 隧道和上述 DNS；权限范围外的 DNS 需自行检查。其它 VPS 若共用隧道也会受影响。'
    ask '确认删除选中的隧道和上述 DNS？输入 “YES/y” 继续，“NO/n” 取消：'; confirmed || return 0
    jq -r '.[].id' "$TMP/delete-selected.json" > "$TMP/delete-tunnel-ids"
    while IFS= read -r delete_id; do
        valid_uuid "$delete_id" || die 'Tunnel ID 格式错误。'
        was_running=0
        if [ "$delete_id" = "$local_tunnel_id" ]; then
            control status >/dev/null 2>&1 && was_running=1
            stop_if_running
        fi
        if ! api_request DELETE "/accounts/$account_id/cfd_tunnel/$delete_id" "$TMP/delete-result.json"; then
            warn "隧道 $delete_id 删除失败，保留它的 DNS。若仍有连接器运行，请先停止后重试。"
            [ "$was_running" != 1 ] || control start || true
            continue
        fi
        if [ "$delete_id" = "$local_tunnel_id" ]; then sync_disable; fi
        good "已删除 CF 隧道：$delete_id"
        jq -r --arg t "$delete_id" '.[]|select(.tunnel_id == $t)|[.zone_id,.id]|@tsv' "$TMP/delete-dns.json" > "$TMP/delete-record-ids"
        while IFS="$(printf '\t')" read -r delete_zone delete_record; do
            # Recheck identity immediately before deleting DNS; never delete a reassigned record.
            if api_request GET "/zones/$delete_zone/dns_records/$delete_record" "$TMP/dns-current.json" &&
               jq -e --arg t "$delete_id.cfargotunnel.com" --arg z "$delete_zone" --arg d "$delete_record" --slurpfile before "$TMP/delete-dns.json" '.result as $r | $r.type == "CNAME" and ($r.content|ascii_downcase|rtrimstr(".")) == $t and any($before[0][]; .zone_id == $z and .id == $d and .name == $r.name)' "$TMP/dns-current.json" >/dev/null; then
                api_request DELETE "/zones/$delete_zone/dns_records/$delete_record" "$TMP/dns-deleted.json" || warn "DNS $delete_record 删除失败，请手动检查。"
            else warn "DNS $delete_record 已变化或无法读取，未删除。"; fi
        done < "$TMP/delete-record-ids"
    done < "$TMP/delete-tunnel-ids"
}
uninstall_menu() {
    if [ -s "$APIBASE/auth.json" ]; then
        dependencies; api_load_auth
        TMP=$(mktemp -d); chmod 700 "$TMP"
        api_current_tunnel
        if api_collect "/accounts/$account_id/cfd_tunnel?is_deleted=false" "$TMP/delete-list.json"; then
            jq '[.[]|select(.deleted_at == null)]' "$TMP/delete-list.json" > "$TMP/delete-active.json"
        else
            warn '无法读取 CF 隧道列表，仍可仅卸载本机隧道。'
            printf '[]\n' > "$TMP/delete-active.json"
        fi
    else
        TMP=$(mktemp -d); chmod 700 "$TMP"; local_tunnel_id=
        printf '[]\n' > "$TMP/delete-active.json"
        warn '尚未接入 API；只能卸载本机隧道。'
    fi
    printf '\n%s  【 卸载隧道 】%s\n' "$C_RED" "$C_RESET"; rule
    # jq is not required for the original local-only uninstall.
    delete_count=0
    if [ -s "$APIBASE/auth.json" ]; then
        delete_count=$(jq length "$TMP/delete-active.json")
        jq -r --arg t "$local_tunnel_id" 'to_entries[]|"  \(.key+1). \(.value.name) · \(.value.id)" + (if .value.id == $t then " · 当前 VPS 使用" else "" end)' "$TMP/delete-active.json"
    fi
    printf '  输入编号删除；多个编号用空格分隔，后回车。例如 2 3。\n'
    menu_item "$C_RED" 'A.' '删除上面列出的所有 CF 隧道'
    menu_item "$C_RED" 'L.' '保留 CF 后台配置，仅卸载本机隧道'
    menu_item "$C_DIM" '0.' '返回首页'
    while :; do
        ask '请输入隧道编号（可多个），或 A / L / 0：'
        case "$REPLY" in
            0) return;; L|l) uninstall; return;;
            A|a) [ "$delete_count" -gt 0 ] || { warn '没有可删除的 CF 隧道。'; continue; }; cp "$TMP/delete-active.json" "$TMP/delete-selected.json"; break;;
            *)
                if ! printf '%s' "$REPLY" | grep -Eq '^[0-9]+( +[0-9]+)*$'; then retry_input '请输入列表中的编号，多个编号用空格分隔后回车，例如 1 2。'; continue; fi
                valid_selection=1
                for chosen in $REPLY; do
                    case "$chosen" in 0*|??????????*) valid_selection=0;; *) [ "$chosen" -ge 1 ] && [ "$chosen" -le "$delete_count" ] || valid_selection=0;; esac
                done
                [ "$valid_selection" = 1 ] || { retry_input '请输入列表中的有效编号。'; continue; }
                jq --arg choices "$REPLY" '($choices|split(" ")|map(select(length>0)|tonumber-1)|unique) as $n|[.[$n[]]]' "$TMP/delete-active.json" > "$TMP/delete-selected.json"
                break;;
        esac
    done
    api_delete_selected
}

api_check_access() {
    api_load_auth
    TMP=$(mktemp -d); chmod 700 "$TMP"
    api_request GET "/accounts/$account_id/cfd_tunnel?is_deleted=false&per_page=1" "$TMP/access-account.json" || die 'API 账户验证失败，请重新接入。'
    api_request GET "/zones/$zone_id" "$TMP/access-zone.json" || die 'API 域名区域验证失败，请重新接入。'
    jq -e --arg a "$account_id" '.result.account.id == $a and .result.status == "active"' "$TMP/access-zone.json" >/dev/null || die '域名区域与账户不匹配。'
}
api_menu() {
    if [ -s "$APIBASE/auth.json" ]; then
        run_action api_check_access
        if [ "$action_result" != 0 ]; then run_action api_connect; [ "$action_result" = 0 ] || return; fi
    else
        printf '  请先接入 CF API。\n'
        run_action api_connect; [ "$action_result" = 0 ] || return
    fi
    while :; do
        printf '\n%s  【 CF API 模式 】%s\n' "$C_CYAN" "$C_RESET"; rule
        printf '  账户：%s已接入%s · 域名区域：%s%s%s\n' "$C_GREEN" "$C_RESET" "$C_CYAN" "$(jq -r '.zone_name' "$APIBASE/auth.json")" "$C_RESET"
        menu_item "$C_GREEN" '1.' '自动部署'
        menu_item "$C_YELLOW" '2.' '修改配置'
        menu_item "$C_YELLOW" '3.' '更换 API 凭据 / 域名区域'
        menu_item "$C_DIM" '0.' '返回上一级'
        ask '请选择 [0–3]：'
        case "$REPLY" in
            1) run_action api_deploy deploy; API_DONE=1; return;;
            2) run_action api_deploy edit; API_DONE=1; return;;
            3) run_action api_connect;;
            0) return;; *) retry_input '请输入 0、1、2 或 3。';;
        esac
    done
}
fixed_menu() {
    while :; do
        printf '\n%s  【 固定隧道安装模式 】%s\n' "$C_CYAN" "$C_RESET"; rule
        menu_item "$C_GREEN" '1.' '手动模式'
        menu_item "$C_GREEN" '2.' 'API 接入模式'
        menu_item "$C_DIM" '0.' '返回首页'
        ask '请选择 [0–2]：'
        case "$REPLY" in 1) run_action setup fixed; return;; 2) API_DONE=0; api_menu; [ "$API_DONE" != 1 ] || return;; 0) return;; *) retry_input '请输入 0、1 或 2。';; esac
    done
}

write_sync_program() {
    cat > "$SYNCBIN.new" <<'SYNC_WORKER'
#!/bin/sh
# Read-only synchronizer. It never writes CF or restarts node/tunnel services.
set -eu
BASE=/etc/vps-tunnel
NBASE=/etc/vps-node
NBIN=/usr/local/lib/vps-node/core
APIBASE=/etc/vps-cf-api
LOG=/var/log/vps-tunnel/cloudflared.log
WORK=
LOCK=/run/vps-cf-sync.lock
cleanup_sync() {
    [ -z "$WORK" ] || rm -rf "$WORK"
    if [ -d "$LOCK" ] && [ "$(cat "$LOCK/pid" 2>/dev/null || true)" = "$$" ]; then rm -rf "$LOCK"; fi
}
trap cleanup_sync EXIT
trap 'exit 0' INT TERM
fail() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; exit 1; }
atomic_text() { printf '%s\n' "$2" > "$1.new"; mv "$1.new" "$1"; }
valid_domain() { [ "${#1}" -le 253 ] && printf '%s\n' "$1" | grep -Eq '^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'; }
api_get() {
    curl -fsS --connect-timeout 5 --max-time 15 -H "@$WORK/headers" "https://api.cloudflare.com/client/v4$1" -o "$2" 2>/dev/null || return 1
    jq -e '.success == true' "$2" >/dev/null 2>&1
}
running() {
    if command -v rc-service >/dev/null 2>&1; then rc-service "$1" status >/dev/null 2>&1
    else systemctl is-active --quiet "$1.service"; fi
}
listen_port() {
    hex=$(printf '%04X' "$1")
    awk -v p="$hex" '$4 == "0A" {split($2,a,":"); if (toupper(a[length(a)]) == p) ok=1} END {exit !ok}' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}
read_node() {
    core=$(cat "$NBASE/core")
    cp "$NBASE/config.json" "$WORK/config.json"
    if [ "$core" = sing-box ]; then
        "$NBIN" check -c "$WORK/config.json" >/dev/null 2>&1 || fail '核心配置校验失败，保留旧链接。'
        jq -e '[.inbounds[]?|select(.tag == "vless-ws" and .type == "vless" and .listen == "127.0.0.1" and .transport.type == "ws" and (.tls.enabled // false) == false)]
          | select(length == 1) | .[0] | select(.users|length == 1)
          | {uuid:.users[0].uuid,path:.transport.path,port:.listen_port}' "$WORK/config.json" > "$WORK/node.json" || fail '无法识别唯一的 VLESS WS 入站，保留旧链接。'
    elif [ "$core" = xray ]; then
        "$NBIN" run -test -config "$WORK/config.json" >/dev/null 2>&1 || fail '核心配置校验失败，保留旧链接。'
        jq -e '[.inbounds[]?|select(.tag == "vless-ws" and .protocol == "vless" and .listen == "127.0.0.1" and .streamSettings.network == "ws" and (.streamSettings.security // "none") == "none")]
          | select(length == 1) | .[0] | select(.settings.clients|length == 1)
          | {uuid:.settings.clients[0].id,path:.streamSettings.wsSettings.path,port:.port}' "$WORK/config.json" > "$WORK/node.json" || fail '无法识别唯一的 VLESS WS 入站，保留旧链接。'
    else fail '未知节点核心，保留旧链接。'; fi
    jq -e '.uuid|type == "string"' "$WORK/node.json" >/dev/null || fail 'UUID 类型错误。'
    uuid=$(jq -r '.uuid' "$WORK/node.json"); ws_path=$(jq -r '.path' "$WORK/node.json"); port=$(jq -r '.port' "$WORK/node.json")
    printf '%s' "$uuid" | grep -Eq '^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$' || fail 'UUID 格式错误。'
    [ "${#ws_path}" -le 128 ] && printf '%s' "$ws_path" | grep -Eq '^/[A-Za-z0-9/._~-]*$' || fail 'WS 路径格式错误。'
    case "$port" in ''|*[!0-9]*|??????*) fail '端口格式错误。';; esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || fail '端口范围错误。'
    running vps-node && listen_port "$port" || fail '节点未运行或未监听新端口，保留旧链接。'
    # Restart through the manager after editing. A new hash cannot prove a live reload.
    config_sha=$(sha256sum "$WORK/config.json" | awk '{print $1}')
    if [ "$config_sha" != "$(cat "$NBASE/active-config-sha" 2>/dev/null || true)" ]; then
        fail '磁盘配置尚未确认已由核心加载；请选择 10 重启节点，再自动同步。'
    fi
}
read_domain() {
    mode=$(cat "$BASE/mode")
    running vps-tunnel || fail '隧道已停止，保留旧链接。'
    case "$mode" in
      quick)
        domain=$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG" 2>/dev/null | tail -n 1 || true)
        domain=${domain#https://}
        [ "$(cat "$BASE/port")" = "$port" ] || fail '临时隧道端口与核心不一致，保留旧链接。'
        ;;
      fixed)
        if [ -s "$APIBASE/target.json" ]; then
            cp "$APIBASE/target.json" "$WORK/target.json"
            a=$(jq -er '.account_id' "$WORK/target.json"); t=$(jq -er '.tunnel_id' "$WORK/target.json")
            z=$(jq -er '.zone_id' "$WORK/target.json"); old=$(jq -er '.hostname' "$WORK/target.json")
            svc=$(jq -er '.service' "$WORK/target.json")
            jq -e --arg a "$a" '.account_id == $a' "$APIBASE/auth.json" >/dev/null || fail 'API 凭据账户不匹配。'
            token=$(jq -er '.token' "$APIBASE/auth.json")
            printf 'Authorization: Bearer %s\n' "$token" > "$WORK/headers"; unset token
            api_get "/accounts/$a/cfd_tunnel/$t/configurations" "$WORK/remote.json" || fail 'CF API 读取失败，保留旧链接。'
            jq --arg h "$old" --arg s "$svc" '
              [.result.config.ingress[]?|select(.hostname != null and (.path // "") == "")] as $r
              | [$r[]|select(.hostname == $h)] as $same
              | if ($same|length) == 1 then $same
                elif ($same|length) == 0 then [$r[]|select(.service == $s)] else [] end
              | select(length == 1) | .[0]
            ' "$WORK/remote.json" > "$WORK/route.json"
            [ -s "$WORK/route.json" ] || fail '路由被删除或有多个候选域名，无法安全识别；请重新选择 API 部署。'
            domain=$(jq -er '.hostname' "$WORK/route.json")
            remote_service=$(jq -er '.service' "$WORK/route.json")
            case "$remote_service" in "http://127.0.0.1:$port"|"http://localhost:$port") :;; *) fail 'CF 服务地址与本地 WS 监听不一致，请通过修改配置处理。';; esac
            zn=$(jq -er '.zone_name' "$WORK/target.json")
            case "$domain" in *."$zn") :;; *) fail '新域名不属于选定区域，保留旧链接。';; esac
            api_get "/zones/$z/dns_records?name=$domain&per_page=100" "$WORK/dns.json" || fail '域名 DNS 读取失败。'
            jq -e --arg t "$t.cfargotunnel.com" '.result|length == 1 and .[0].type == "CNAME" and .[0].content == $t and .[0].proxied == true' "$WORK/dns.json" >/dev/null || fail '域名 DNS 未正确指向此隧道，保留旧链接。'
            dns=$(jq -er '.result[0].id' "$WORK/dns.json")
            jq --arg h "$domain" --arg s "$remote_service" --arg d "$dns" '.hostname=$h | .service=$s | .dns_id=$d' "$WORK/target.json" > "$WORK/new-target.json"
        else
            domain=$(cat "$BASE/domain")
            [ "$(cat "$BASE/port")" = "$port" ] || fail '手动固定隧道端口记录与核心不一致，请同步 CF 路由和本地记录。'
        fi
        ;;
      *) fail '未知隧道模式。';;
    esac
    valid_domain "$domain" || fail '未找到有效域名，保留旧链接。'
    [ -s "$BASE/metrics-port" ] || fail '缺少隧道就绪检查端口。'
    curl --noproxy '*' -fsS --connect-timeout 1 --max-time 2 "http://127.0.0.1:$(cat "$BASE/metrics-port")/ready" >/dev/null 2>&1 || fail '隧道尚未连接，保留旧链接。'
}
sync_once() {
    sync_foreground=${1:-}
    umask 077
    if [ -f "$APIBASE/pause-pid" ] && [ "${1:-}" != foreground ]; then
        pause_pid=$(cat "$APIBASE/pause-pid")
        if kill -0 "$pause_pid" 2>/dev/null; then exit 0; fi
        rm -f "$APIBASE/pause-pid"
    fi
    mkdir "$LOCK" 2>/dev/null || {
        lock_pid=$(cat "$LOCK/pid" 2>/dev/null || true)
        case "$lock_pid" in
          ''|*[!0-9]*)
            lock_time=$(stat -c %Y "$LOCK" 2>/dev/null || date +%s)
            [ "$(( $(date +%s) - lock_time ))" -ge 30 ] || exit 0
            ;;
          *) if kill -0 "$lock_pid" 2>/dev/null; then exit 0; fi;;
        esac
        rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 0
    }
    printf '%s\n' "$$" > "$LOCK/pid"
    [ -s "$NBASE/config.json" ] && [ -x "$NBIN" ] && [ -s "$BASE/mode" ] || exit 0
    WORK=$(mktemp -d)
    read_node; read_domain
    flag=🌐; name=未知
    code=$(cat "$NBASE/country-code" 2>/dev/null || true)
    if printf '%s' "$code" | grep -Eq '^[A-Z]{2}$'; then
        flag=$(jq -nr --arg c "$code" '$c|explode|map(.+127397)|implode')
        name=$(cat "$NBASE/country-name" 2>/dev/null || printf '%s' "$code")
    fi
    case "$core" in sing-box) label="Argo-singbox-$flag";; *) label="Argo-Xray-$flag";; esac
    encoded_label=$(jq -nr --arg s "$label" '$s|@uri'); encoded_path=$(jq -nr --arg s "$ws_path" '$s|@uri')
    link="vless://$uuid@$domain:443?encryption=none&security=tls&sni=$domain&type=ws&host=$domain&path=$encoded_path#$encoded_label"
    version=$(cat "$NBASE/version")
    printf '%s\n' "$link" > "$WORK/node-link.txt"
    {
      printf '节点名称：%s\n出口地区：%s\n\n' "$label" "$name"
      printf '核心：%s %s\n' "$core" "$version"
      printf '域名：%s\n客户端端口：443\n本地监听：127.0.0.1:%s\n' "$domain" "$port"
      printf '协议：VLESS\nUUID：%s\n传输：WebSocket\nWS 路径：%s\n' "$uuid" "$ws_path"
      printf '客户端 TLS：开启\nSNI / WS Host：%s\n本地 TLS：关闭\n\n%s\n' "$domain" "$link"
    } > "$WORK/node-info.txt"
    # Ensure the config did not change while network requests were in progress.
    [ "$config_sha" = "$(sha256sum "$NBASE/config.json" | awk '{print $1}')" ] || fail '检查期间核心配置变化，下次重试。'
    if [ -f "$APIBASE/pause-pid" ] && [ "$sync_foreground" != foreground ]; then
        pause_pid=$(cat "$APIBASE/pause-pid")
        if kill -0 "$pause_pid" 2>/dev/null; then exit 0; fi
    fi
    if [ -f "$WORK/target.json" ] && ! cmp -s "$WORK/target.json" "$APIBASE/target.json"; then
        fail '检查期间部署目标变化，下次重试。'
    fi
    changed=0
    if ! cmp -s "$WORK/node-link.txt" /etc/nodes/argo/links.txt || ! cmp -s "$WORK/node-info.txt" /etc/nodes/argo/info.txt; then changed=1; fi
    /usr/local/lib/argo-node-files/run --publish argo "$WORK/node-link.txt" "$WORK/node-info.txt" || fail '节点链接汇总失败，保留旧文件。'
    for field in uuid path port; do
        case "$field" in uuid) value=$uuid;; path) value=$ws_path;; port) value=$port;; esac
        if [ "$(cat "$NBASE/$field" 2>/dev/null || true)" != "$value" ]; then atomic_text "$NBASE/$field" "$value"; fi
    done
    if [ "$(cat "$BASE/port")" != "$port" ]; then atomic_text "$BASE/port" "$port"; fi
    if [ "$(cat "$BASE/ws-path" 2>/dev/null || true)" != "$ws_path" ]; then atomic_text "$BASE/ws-path" "$ws_path"; fi
    if [ "$mode" = fixed ] && [ -f "$WORK/new-target.json" ]; then
        if ! cmp -s "$WORK/new-target.json" "$APIBASE/target.json"; then cp "$WORK/new-target.json" "$APIBASE/target.json.new"; mv "$APIBASE/target.json.new" "$APIBASE/target.json"; fi
        if [ "$(cat "$BASE/domain")" != "$domain" ]; then atomic_text "$BASE/domain" "$domain"; fi
    fi
    if [ "$changed" = 1 ]; then
        printf '%s 已更新节点信息：%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$domain"
        atomic_text "$APIBASE/last-sync" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    fi
}
case "${1:-}" in
  --once) sync_once "${2:-}";;
  *)
    child=
    trap '[ -z "$child" ] || kill "$child" 2>/dev/null || true; exit 0' INT TERM
    while :; do
        "$0" --once & child=$!
        wait "$child" || true; child=
        sleep 60 & child=$!
        wait "$child" || true; child=
    done
    ;;
esac
SYNC_WORKER
    chmod 700 "$SYNCBIN.new"
    mv "$SYNCBIN.new" "$SYNCBIN"
}
sync_control() {
    if [ "$MANAGER" = openrc ]; then rc-service "$SYNCSERVICE" "$1"
    else systemctl "$1" "$SYNCSERVICE.service"; fi
}
sync_disable() {
    if [ -x "$SYNCBIN" ]; then
        sync_control stop >/dev/null 2>&1 || true
        if [ "$MANAGER" = openrc ]; then rc-update del "$SYNCSERVICE" default >/dev/null 2>&1 || true
        else systemctl disable "$SYNCSERVICE.service" >/dev/null 2>&1 || true; fi
    fi
    rm -f "$APIBASE/target.json"
}
sync_remove() {
    sync_disable
    if [ "$MANAGER" = openrc ]; then rm -f /etc/init.d/vps-cf-sync
    else rm -f /etc/systemd/system/vps-cf-sync.service; systemctl daemon-reload; fi
    rm -rf /usr/local/lib/vps-cf-sync "$APIBASE"
    rm -f /var/log/vps-cf-sync.log /var/log/vps-cf-sync.log.[123]
}
sync_install() {
    umask 077
    mkdir -p /usr/local/lib/vps-cf-sync "$APIBASE"
    chmod 700 /usr/local/lib/vps-cf-sync "$APIBASE"
    write_sync_program
    if [ "$MANAGER" = openrc ]; then
        cat > /etc/init.d/vps-cf-sync <<'RC'
#!/sbin/openrc-run
name="Argo node information synchronizer"
supervisor="supervise-daemon"
command="/usr/local/lib/vps-cf-sync/run"
respawn_delay=5
respawn_max=0
respawn_period=60
output_log="/var/log/vps-cf-sync.log"
error_log="/var/log/vps-cf-sync.log"
depend() { need net; after vps-tunnel vps-node; }
RC
        chmod 755 /etc/init.d/vps-cf-sync
        rc-update add "$SYNCSERVICE" default
    else
        cat > /etc/systemd/system/vps-cf-sync.service <<'UNIT'
[Unit]
Description=Argo node information synchronizer
Wants=network-online.target
After=network-online.target vps-tunnel.service vps-node.service
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStart=/usr/local/lib/vps-cf-sync/run
Restart=always
RestartSec=5
UMask=0077
StandardOutput=append:/var/log/vps-cf-sync.log
StandardError=append:/var/log/vps-cf-sync.log
[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
        systemctl enable "$SYNCSERVICE.service"
    fi
    sync_control restart || die '节点已部署，但后台同步服务启动失败，请查看 vps-cf-sync 日志。'
}
sync_stamp() {
    # Called only after the node manager successfully starts/restarts the core.
    if [ -s "$NBASE/config.json" ]; then
        (umask 077; sha256sum "$NBASE/config.json" | awk '{print $1}' > "$NBASE/active-config-sha.new"; mv "$NBASE/active-config-sha.new" "$NBASE/active-config-sha")
    fi
}


main() {
    detect
    upgrade_node_publication
    if [ -x "$SYNCBIN" ]; then
        write_sync_program
    fi
    install_log_maintenance
    terminal_enter
    clear_screen
    while :; do
        [ -x /usr/local/lib/argo-log-maintenance/run ] || install_log_maintenance
        header
        printf '\n%s  【 TUNNEL / 隧道管理 】%s\n' "$C_CYAN" "$C_RESET"
        menu_item "$C_INSTALL" '1.' '安装临时隧道（保活 + 开机自启）'
        menu_item "$C_INSTALL" '2.' '安装固定隧道（保活 + 开机自启）'
        menu_item "$C_BLUE" '3.' '查看隧道状态 / 域名'
        menu_item "$C_YELLOW" '4.' '重启隧道'
        menu_item "$C_YELLOW" '5.' '停止隧道'
        menu_item "$C_BLUE" '6.' '查看隧道日志'
        menu_item "$C_RED" '7.' '卸载隧道'
        printf '\n%s  【 NODE / 节点管理 】%s\n' "$C_CYAN" "$C_RESET"
        menu_item "$C_INSTALL" '8.' '安装 / 切换节点核心'
        menu_item "$C_BLUE" '9.' '查询节点信息 / 分享链接'
        menu_item "$C_YELLOW" '10.' '重启节点'
        menu_item "$C_YELLOW" '11.' '停止节点'
        menu_item "$C_BLUE" '12.' '查看节点日志'
        menu_item "$C_INSTALL" '13.' '更新节点核心'
        menu_item "$C_RED" '14.' '卸载节点核心'
        printf '\n%s  【 NETWORK / 网络设置 】%s\n' "$C_CYAN" "$C_RESET"
        menu_item "$C_YELLOW" '15.' '隧道传输（自动 / HTTP2 / QUIC）'
        menu_item "$C_DIM" '0.' '返回首页'
        rule
        while :; do
            ask '  请选择 [0–15]：'
            case "$REPLY" in 0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15) break;; *) retry_input '请输入 0–15，重新选择即可。';; esac
        done
        case "$REPLY" in
            1) run_action setup quick;; 2) fixed_menu;; 3) run_action status;;
            4) if exists; then run_action control restart; else warn '尚未安装。'; fi;;
            5) run_action stop_if_running;; 6) run_action logs;; 7) run_action uninstall_menu;;
            8) run_action node_menu;; 9) run_action node_info;;
            10) if node_exists; then run_action node_control restart; else warn '尚未安装节点。'; fi;;
            11) if node_exists; then run_action node_stop; else warn '尚未安装节点。'; fi;;
            12) run_action node_logs;; 13) run_action update_node;; 14) run_action remove_node;;
            15) run_action set_transport;; 0) exit 0;; *) retry_input '请输入正确选项。';;
        esac
        finish_screen
        clear_screen
    done
}
case "${1:-menu}" in
    menu) main;;
    install) detect; upgrade_node_publication; install_log_maintenance; setup quick;;
    info) detect; status; node_info;;
    edit) detect; fixed_menu;;
    uninstall) detect; uninstall_menu;;
    *) die '支持 menu / install / info / edit / uninstall。';;
esac
