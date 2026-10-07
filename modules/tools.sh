#!/bin/sh
set -eu
VPSKIT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$VPSKIT_ROOT/lib/common.sh"
. "$VPSKIT_ROOT/lib/bbr.sh"
detect
clean_vps() {
    ensure_shell_tools
    TMP=$(mktemp -d)
    if curl -fLsS --connect-timeout 15 --max-time 120 https://raw.githubusercontent.com/Alsyok/argo/main/VPSclean.sh -o "$TMP/VPSclean.sh" && bash -n "$TMP/VPSclean.sh"; then
        bash "$TMP/VPSclean.sh"
    else die '清理脚本下载或语法检查失败，未执行。'; fi
    cleanup; TMP=
}
case "${1:-menu}" in
    bbr) bbr_menu;;
    clean) clean_vps;;
    menu)
        while :; do
            printf '\n%s  【 Tools · 实用工具 】%s\n' "$C_CYAN" "$C_RESET"; rule
            menu_item "$C_YELLOW" '1.' 'BBR 管理'
            menu_item "$C_BLUE" '2.' 'VPS 清理'
            menu_item "$C_DIM" '0.' '返回首页'
            ask '请选择 [0–2]：'
            case "$REPLY" in
                1) bbr_menu;;
                2) run_action clean_vps;;
                0) exit 0;;
                *) retry_input '请输入 0–2。';;
            esac
        done;;
    *) die '支持 menu / bbr / clean。';;
esac
