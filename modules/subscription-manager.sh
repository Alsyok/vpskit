#!/bin/sh
set -eu
VPSKIT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$VPSKIT_ROOT/lib/common.sh"
detect
subscription_action() {
    [ "$MANAGER" = systemd ] || die '订阅安装与管理目前支持 Debian / Ubuntu（systemd）。'
    ensure_shell_tools
    case "$1" in
        install|edit)
            export VPSKIT_ROOT
            bash "$VPSKIT_ROOT/installers/install_subscription.sh";;
        info|uninstall)
            command -v python3 >/dev/null 2>&1 || die '请先安装订阅服务。'
            python3 "$VPSKIT_ROOT/lib/subscription-manager.py" "$1";;
        restart) [ -f /etc/nodes/subscription.json ] || die '请先安装订阅服务。'; systemctl restart subscription-api.service; systemctl is-active --quiet subscription-api.service;;
        logs) journalctl -u subscription-api.service -n 60 --no-pager;;
    esac
}
case "${1:-menu}" in
    install|edit|info|uninstall|restart|logs) subscription_action "$1";;
    menu)
        while :; do
            printf '\n%s  【 订阅链接安装 · Debian / Ubuntu 】%s\n' "$C_CYAN" "$C_RESET"; rule
            menu_item "$C_INSTALL" '1.' '安装订阅服务'
            menu_item "$C_BLUE" '2.' '查询订阅地址 / 状态'
            menu_item "$C_YELLOW" '3.' '重新选择域名 / 证书'
            menu_item "$C_INSTALL" '4.' '重启订阅 API'
            menu_item "$C_BLUE" '5.' '查看最近日志'
            menu_item "$C_WARNING" '6.' '卸载订阅服务'
            menu_item "$C_DIM" '0.' '返回首页'
            ask '请选择 [0–6]：'
            case "$REPLY" in
                1) run_action subscription_action install;; 2) run_action subscription_action info;;
                3) run_action subscription_action edit;; 4) run_action subscription_action restart;;
                5) run_action subscription_action logs;; 6) run_action subscription_action uninstall;;
                0) exit 0;; *) retry_input '请输入 0–6。';;
            esac
        done;;
    *) die '支持 menu / install / info / edit / uninstall / restart / logs。';;
esac
