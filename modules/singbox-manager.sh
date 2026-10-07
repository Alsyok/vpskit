#!/bin/sh
set -eu
VPSKIT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$VPSKIT_ROOT/lib/common.sh"
. "$VPSKIT_ROOT/lib/node-services.sh"
. "$VPSKIT_ROOT/lib/standalone.sh"
detect
install_node_files
install_log_maintenance
case "${1:-menu}" in
    menu)
        while :; do
            printf '\n%s  【 Singbox 一键安装 】%s\n' "$C_CYAN" "$C_RESET"; rule
            menu_item "$C_INSTALL" '1.' 'Ubuntu / Debian'
            menu_item "$C_INSTALL" '2.' 'Alpine'
            menu_item "$C_INSTALL" '3.' '证书申请与续签'
            menu_item "$C_DIM" '0.' '返回首页'
            ask '请选择 [0–3]：'
            case "$REPLY" in
                1) if [ "$MANAGER" = systemd ]; then singbox_system_menu debian; else retry_input '当前系统请选择 Alpine。'; fi;;
                2) if [ "$MANAGER" = openrc ]; then singbox_system_menu alpine; else retry_input '当前系统请选择 Ubuntu / Debian。'; fi;;
                3) run_action standalone_action cert-menu;;
                0) exit 0;;
                *) retry_input '请输入 0–3。';;
            esac
        done;;
    install)
        if [ "$MANAGER" = openrc ]; then singbox_standalone_install alpine; else singbox_standalone_install debian; fi
        standalone_action post-install;;
    info) standalone_action info;;
    edit) standalone_action edit-menu;;
    uninstall) standalone_action sb-uninstall;;
    certificates) standalone_action cert-list;;
    *) die '支持 menu / install / info / edit / uninstall / certificates。';;
esac
