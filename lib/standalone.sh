singbox_standalone_install() {
    case "$1" in
        debian) standalone_url="$VPSKIT_ROOT/installers/singbox.sh";;
        alpine) standalone_url="$VPSKIT_ROOT/installers/Encrypt.sh";;
        *) die '未知安装选项。';;
    esac
    if ! command -v bash >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        if [ "$MANAGER" = openrc ]; then
            apk add --no-cache bash curl ca-certificates
        else
            apt-get update
            apt-get install -y bash curl ca-certificates
        fi
    fi
    TMP=$(mktemp -d); chmod 700 "$TMP"
    printf '\n  %s正在准备 sing-box 安装脚本…%s\n' "$C_CYAN" "$C_RESET"
    cp "$standalone_url" "$TMP/install.sh" || die '安装脚本不存在。'
    [ -s "$TMP/install.sh" ] || die '安装脚本为空。'
    bash -n "$TMP/install.sh" || die '安装脚本语法检查失败，未执行。'
    bash "$TMP/install.sh"
}
standalone_tools() {
    if ! command -v python3 >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v socat >/dev/null 2>&1; then
        if [ "$MANAGER" = openrc ]; then apk add --no-cache python3 openssl curl ca-certificates socat;
        else apt-get update; apt-get install -y python3 openssl curl ca-certificates socat; fi
    fi
    mkdir -p /usr/local/lib/argo-standalone
    chmod 700 /usr/local/lib/argo-standalone
    standalone_helper_tmp=$(mktemp /usr/local/lib/argo-standalone/.manager.XXXXXX)
    cp "$VPSKIT_ROOT/lib/node-manager.py" "$standalone_helper_tmp"
    chmod 700 "$standalone_helper_tmp"
    mv -f "$standalone_helper_tmp" /usr/local/lib/argo-standalone/manager.py
}
standalone_action() {
    standalone_tools
    python3 /usr/local/lib/argo-standalone/manager.py "$1"
}
singbox_system_menu() {
    standalone_platform=$1
    while :; do
        printf '\n%s  【 sing-box 管理 】%s\n' "$C_CYAN" "$C_RESET"; rule
        menu_item "$C_INSTALL" '1.' '安装 sing-box'
        menu_item "$C_BLUE" '2.' '查看节点信息 / 分享链接'
        menu_item "$C_BLUE" '3.' '查看证书信息'
        menu_item "$C_YELLOW" '4.' '更改节点配置'
        menu_item "$C_WARNING" '5.' '卸载独立 sing-box'
        menu_item "$C_DIM" '0.' '返回上一级'
        ask '请选择 [0–5]：'
        case "$REPLY" in
            1)
                run_action singbox_standalone_install "$standalone_platform"
                if [ "$action_result" = 0 ]; then run_action standalone_action post-install; fi;;
            2) run_action standalone_action info;;
            3) run_action standalone_action cert-list;;
            4) run_action standalone_action edit-menu;;
            5) run_action standalone_action sb-uninstall;;
            0) return;;
            *) retry_input '请输入 0–5。'; continue;;
        esac
        ask '按回车返回 sing-box 管理菜单：'
    done
}
singbox_standalone_menu() {
    while :; do
        printf '\n%s  【 singbox一键安装 】%s\n' "$C_CYAN" "$C_RESET"; rule
        printf '  系统  %s%s / %s%s\n\n' "$C_WHITE" "$ID" "$MANAGER" "$C_RESET"
        menu_item "$C_INSTALL" '1.' 'Ubuntu / Debian'
        menu_item "$C_INSTALL" '2.' 'Alpine'
        menu_item "$C_DIM" '0.' '返回首页'
        rule
        ask '请选择 [0–2]：'
        case "$REPLY" in
            1)
                if [ "$MANAGER" != systemd ]; then retry_input '当前是 Alpine，请选择 2。'; continue; fi
                singbox_system_menu debian;;
            2)
                if [ "$MANAGER" != openrc ]; then retry_input '当前是 Ubuntu / Debian，请选择 1。'; continue; fi
                singbox_system_menu alpine;;
            0) return;;
            *) retry_input '请输入 0、1 或 2。';;
        esac
    done
}

