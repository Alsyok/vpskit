#!/bin/sh
# Cloudflare Tunnel manager: Alpine/OpenRC and Debian/systemd
set -eu
VERSION=2.4.9
BASE=/etc/vps-tunnel
BIN=/usr/local/lib/vps-tunnel/cloudflared
SERVICE=vps-tunnel
LOG=/var/log/vps-tunnel/cloudflared.log
TMP=
NBASE=/etc/vps-node
NBIN=/usr/local/lib/vps-node/core
NSERVICE=vps-node
NLOG=/var/log/vps-node.log
RAW=https://raw.githubusercontent.com/Alsyok/argo/cores
SCREEN_ACTIVE=0
C_STATUS_LINE= C_ERROR= C_WARNING= C_RETRY= C_LINE= C_LINK= C_INSTALL= C_PROMPT= C_BLUE= C_PURPLE= C_RESET= C_CYAN= C_GREEN= C_YELLOW= C_RED= C_DIM= C_WHITE=
if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$(printf '\033[0m')
    C_CYAN=$(printf '\033[38;2;129;206;214m')
    C_BLUE=$(printf '\033[38;2;136;179;223m')
    C_PURPLE=$(printf '\033[38;2;181;161;223m')
    C_GREEN=$(printf '\033[38;2;151;203;168m')
    C_YELLOW=$(printf '\033[38;2;223;197;138m')
    C_RED=$(printf '\033[38;2;144;238;144m')
    C_DIM=$(printf '\033[38;2;164;175;190m')
    C_WHITE=$(printf '\033[38;2;220;227;235m')
    C_ERROR=$(printf '\033[38;2;144;238;144m')
    C_WARNING=$(printf '\033[38;2;144;238;144m')
    C_RETRY=$(printf '\033[38;2;192;132;252m')
    C_LINE=$(printf '\033[38;2;82;103;124m')
    C_STATUS_LINE=$(printf '\033[38;2;97;175;239m')
    C_LINK=$(printf '\033[38;2;144;238;144m')
    C_INSTALL=$(printf '\033[38;2;144;238;144m')
    C_PROMPT=$(printf '\033[38;2;154;205;50m')
fi
cleanup() { [ -z "$TMP" ] || rm -rf "$TMP"; }
trap 'cleanup; terminal_restore' EXIT
die() { printf '  %s错误：%s%s\n' "$C_ERROR" "$*" "$C_RESET" >&2; exit 1; }
ask_form() { printf '\n' >&2; ask "$1"; }
print_prompt_defaults() {
    prompt_rest=$1
    prompt_color=${2:-$C_CYAN}
    printf '%s' "$prompt_color" >&2
    while :; do
        case "$prompt_rest" in
            *'['*']'*)
                prompt_before=${prompt_rest%%\[*}
                prompt_after=${prompt_rest#*\[}
                prompt_default=${prompt_after%%\]*}
                printf '%s%s[%s]%s' "$prompt_before" "$C_PURPLE" "$prompt_default" "$prompt_color" >&2
                prompt_rest=${prompt_after#*\]};;
            *) printf '%s%s' "$prompt_rest" "$C_RESET" >&2; break;;
        esac
    done
}
ask() {
    ask_base_color=$C_CYAN
    case "${1#  }" in
        '请选择 [0–18]：'|'已有本脚本管理的隧道。替换配置？'*|'本地 WS 端口 '*|'本地 WebSocket 路径 '*) ask_base_color=$C_PROMPT;;
    esac
    case "$1" in
        *'输入 “YES/y” 继续，“NO/n” 取消：'*)
            ask_prefix=${1%%输入 “YES/y” 继续，“NO/n” 取消：*}
            printf '  %s%s%s%s%s' "$ask_base_color" "${ask_prefix#  }" "$C_PURPLE" '输入 “YES/y” 继续，“NO/n” 取消：' "$C_RESET" >&2;;
        *) printf '  ' >&2; print_prompt_defaults "${1#  }" "$ask_base_color";;
    esac
    while :; do
        IFS= read -r REPLY || exit 0
        REPLY=$(printf '%s' "$REPLY" | tr -d '\r')
        case "$1" in
            '请选择 ['*|'选择安装方式：'*)
                REPLY=$(printf '%s' "$REPLY" | tr -d ' \t')
                [ -n "$REPLY" ] || continue;;
        esac
        break
    done
    REPLY=$(printf '%s' "$REPLY" | tr -d '\r')
}
menu_item() { printf '  %s%3s%s  %s%s%s\n' "$C_WHITE" "$2" "$C_RESET" "$1" "$3" "$C_RESET"; }
detect() {
    [ "$(id -u)" = 0 ] || die '请使用 root 运行。'
    [ -f /etc/os-release ] || die '无法识别系统。'
    . /etc/os-release
    case "$ID" in
        alpine) MANAGER=openrc; command -v rc-service >/dev/null || die '需要 OpenRC。';;
        debian|ubuntu) MANAGER=systemd; [ -d /run/systemd/system ] || die '需要运行中的 systemd；不支持无 init 的容器。';;
        *) die '仅支持 Alpine、Debian 和 Ubuntu。';;
    esac
    case "$(uname -m)" in
        x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;;
        *) die '仅支持 AMD64 / ARM64。';;
    esac
}
dependencies() {
    if [ "$MANAGER" = openrc ]; then
        apk add --no-cache curl ca-certificates jq tar unzip gcompat
    else
        apt-get update
        apt-get install -y curl ca-certificates jq tar unzip
    fi
}
confirmed() {
    while :; do
        confirm_reply=$(printf '%s' "$REPLY" | tr -d ' \t\r' | tr 'a-z' 'A-Z')
        case "$confirm_reply" in
            YES|Y) return 0;;
            NO|N) return 1;;
            *) retry_input '请输入 “YES/y” 继续，或 “NO/n” 取消。'
               ask '输入 “YES/y” 继续，“NO/n” 取消：';;
        esac
    done
}
good() { printf '%s  ✓ %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '%s  ⚠ %s%s\n' "$C_WARNING" "$*" "$C_RESET" >&2; }
retry_input() { printf '%s  ↻ %s%s\n' "$C_RETRY" "$*" "$C_RESET" >&2; }
rule() { printf '%s  ──────────────────────────────────────────%s\n' "$C_LINE" "$C_RESET"; }
status_rule() {
    printf '%s  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄\n  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄%s\n' "$C_STATUS_LINE" "$C_RESET"
}
terminal_enter() {
    if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then
        # Use the normal terminal so mobile SSH retains scrollback.
        trap 'exit 130' INT
        trap 'exit 143' TERM
    fi
}
terminal_restore() {
    : # Normal terminal: leave output available after exit.
}
clear_screen() {
    if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then printf '\033[2J\033[H'; fi
}
finish_screen() {
    printf '\n'
    menu_item "$C_CYAN" '1.' '返回当前菜单'
    menu_item "$C_DIM" '0.' '退出脚本'
    while :; do
        ask '请选择 [0–1]：'
        case "$REPLY" in 1) return;; 0) exit 0;; *) retry_input '请输入 0 或 1。';; esac
    done
}

APIBASE=/etc/vps-cf-api
SYNCBIN=/usr/local/lib/vps-cf-sync/run
SYNCSERVICE=vps-cf-sync
run_action() {
    # Keep operational failures inside a subshell, allowing return to the menu.
    pause_owner=0
    if [ -x "$SYNCBIN" ] && [ ! -f "$APIBASE/pause-pid" ]; then
        mkdir -p "$APIBASE"; (umask 077; printf '%s\n' "$$" > "$APIBASE/pause-pid"); pause_owner=1
    fi
    set +e
    (set -eu; trap cleanup EXIT; "$@")
    action_result=$?
    if [ "$pause_owner" = 1 ]; then rm -f "$APIBASE/pause-pid"; fi
    set -e
    [ "$action_result" != 130 ] && [ "$action_result" != 143 ] || exit "$action_result"
    if [ "$action_result" -ne 0 ]; then warn '操作未完成，请查看上面的错误提示。'; fi
}

show_subscription() {
    if [ -f /etc/nodes/subscription.json ] && command -v python3 >/dev/null 2>&1; then
        subscription_url=$(python3 -c 'import json,re; d=json.load(open("/etc/nodes/subscription.json")); u=d.get("url",""); print(u if re.fullmatch(r"https://[A-Za-z0-9.-]+/subs",u) else "")')
        [ -z "$subscription_url" ] || printf '\n  v2rayN 订阅地址：\n  %s%s%s\n' "$C_INSTALL" "$subscription_url" "$C_RESET"
    else printf '\n  可从首页 4 安装订阅服务。\n'; fi
}
ensure_shell_tools() {
    if ! command -v bash >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        if [ "$MANAGER" = openrc ]; then apk add --no-cache bash curl ca-certificates;
        else apt-get update; apt-get install -y bash curl ca-certificates; fi
    fi
}
