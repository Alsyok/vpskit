#!/bin/sh
set -eu
VPSKIT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$VPSKIT_ROOT/lib/common.sh"
. "$VPSKIT_ROOT/lib/node-services.sh"
. "$VPSKIT_ROOT/lib/standalone.sh"
detect
prepare_node_publication
install_log_maintenance
xray_install() {
    [ "$MANAGER" = openrc ] || die '现有 Xray 安装脚本仅支持 Alpine。'
    standalone_tools
    command -v bash >/dev/null 2>&1 || apk add --no-cache bash
    while :; do
        ask '选择安装方式：1 64M内存Xray / 2 Xray / 0 返回：'
        case "$REPLY" in
            1) xray_source=musl-Xray.sh; break;;
            2) xray_source=install-Xray-core.sh; break;;
            0) return;;
            *) retry_input '请输入 0、1 或 2。';;
        esac
    done
    bash -n "$VPSKIT_ROOT/installers/$xray_source"
    python3 /usr/local/lib/argo-standalone/manager.py xray-install "$VPSKIT_ROOT/installers/$xray_source"
}
case "${1:-menu}" in
    install) xray_install;;
    info) standalone_action xray-info;;
    edit) standalone_action xray-edit;;
    restart) standalone_action xray-restart;;
    uninstall) standalone_action xray-uninstall;;
    certificates) standalone_action cert-list;;
    menu)
        while :; do
            printf '\n%s  【 Xray 一键安装 · Alpine 】%s\n' "$C_CYAN" "$C_RESET"; rule
            menu_item "$C_INSTALL" '1.' '安装 Xray'
            menu_item "$C_BLUE" '2.' '查询节点 / 订阅地址'
            menu_item "$C_BLUE" '3.' '查看证书信息'
            menu_item "$C_YELLOW" '4.' '修改节点配置'
            menu_item "$C_INSTALL" '5.' '重启并同步节点'
            menu_item "$C_WARNING" '6.' '卸载独立 Xray'
            menu_item "$C_INSTALL" '7.' '证书申请与续签'
            menu_item "$C_DIM" '0.' '返回首页'
            ask '请选择 [0–7]：'
            case "$REPLY" in
                1) run_action xray_install;;
                2) run_action standalone_action xray-info;;
                3) run_action standalone_action cert-list;;
                4) run_action standalone_action xray-edit;;
                5) run_action standalone_action xray-restart;;
                6) run_action standalone_action xray-uninstall;;
                7) run_action standalone_action cert-menu;;
                0) exit 0;;
                *) retry_input '请输入 0–7。';;
            esac
        done;;
    *) die '支持 menu / install / info / edit / restart / uninstall / certificates。';;
esac
