bbr_read() { sysctl -n "$1" 2>/dev/null; }
bbr_supported() {
    bbr_available=$(bbr_read net.ipv4.tcp_available_congestion_control || true)
    case " $bbr_available " in *' bbr '*) return 0;; *) return 1;; esac
}
bbr_status() {
    printf '\n%s  【 BBR 管理 】%s\n' "$C_CYAN" "$C_RESET"; rule
    printf '  内核：%s\n' "$(uname -r)"
    bbr_current=$(bbr_read net.ipv4.tcp_congestion_control || printf 无法读取)
    printf '  当前拥塞控制：%s%s%s\n' "$C_PURPLE" "$bbr_current" "$C_RESET"
    if bbr_supported; then good '内核已提供 BBR。'
    else warn '当前未发现 BBR；开启时会尝试加载内核模块。'; fi
    printf '  默认队列规则：%s%s%s\n' "$C_PURPLE" "$(bbr_read net.core.default_qdisc || printf 无法读取)" "$C_RESET"
    if [ -s /etc/sysctl.d/99-zz-argo-bbr.conf ]; then
        printf '  %s已保存开机参数。%s\n' "$C_GREEN" "$C_RESET"
    fi
}
bbr_restore() {
    bbr_exit=$?
    trap - EXIT INT TERM
    set +e
    if [ "${bbr_committed:-0}" != 1 ]; then
        if [ "${bbr_runtime_changed:-0}" = 1 ]; then
            sysctl -w "net.ipv4.tcp_congestion_control=$bbr_old_cc" >/dev/null 2>&1 || warn '拥塞控制恢复失败，请检查系统参数。'
            [ -z "$bbr_old_qdisc" ] || sysctl -w "net.core.default_qdisc=$bbr_old_qdisc" >/dev/null 2>&1 || warn '默认队列恢复失败，请检查系统参数。'
        fi
        if [ "${bbr_files_changed:-0}" = 1 ]; then
            for bbr_file in "$bbr_sysfile" "$bbr_modfile"; do
                bbr_basename=$(basename "$bbr_file")
                if [ -f "$TMP/$bbr_basename.old" ]; then cp -p "$TMP/$bbr_basename.old" "$bbr_file"
                else rm -f "$bbr_file"; fi
            done
        fi
        if [ "$MANAGER" = openrc ]; then
            [ "${bbr_added_modules:-0}" != 1 ] || rc-update del modules boot >/dev/null 2>&1
            [ "${bbr_added_sysctl:-0}" != 1 ] || rc-update del sysctl boot >/dev/null 2>&1
        fi
    fi
    cleanup
    exit "$bbr_exit"
}
bbr_enable() {
    command -v sysctl >/dev/null 2>&1 || die '系统缺少 sysctl，无法设置 BBR。'
    bbr_old_cc=$(bbr_read net.ipv4.tcp_congestion_control) || die '无法读取 TCP 拥塞控制参数。'
    bbr_old_qdisc=$(bbr_read net.core.default_qdisc || true)
    ask '开启 BBR 并保存开机参数？输入 “YES/y” 继续，“NO/n” 取消：'
    confirmed || return 0
    if ! bbr_supported; then
        if command -v modprobe >/dev/null 2>&1; then modprobe tcp_bbr 2>/dev/null || true; fi
        bbr_supported || die '当前内核不支持 BBR，或容器不允许加载模块；未修改参数。请使用宿主机提供的内核支持。'
    fi
    [ -z "$bbr_old_qdisc" ] || { command -v modprobe >/dev/null 2>&1 && modprobe sch_fq 2>/dev/null || true; }
    bbr_sysfile=/etc/sysctl.d/99-zz-argo-bbr.conf
    if [ "$MANAGER" = openrc ]; then
        [ -f /etc/init.d/sysctl ] && [ -f /etc/init.d/modules ] || die '缺少 OpenRC sysctl/modules 服务，无法保证开机应用。'
        bbr_modfile=/etc/modules
    else bbr_modfile=/etc/modules-load.d/argo-bbr.conf; fi
    # Only these two owned/preserved files and the two sysctl keys are changed.
    TMP=$(mktemp -d); chmod 700 "$TMP"
    bbr_committed=0; bbr_runtime_changed=0; bbr_files_changed=0
    bbr_added_modules=0; bbr_added_sysctl=0
    for bbr_file in "$bbr_sysfile" "$bbr_modfile"; do
        [ ! -L "$bbr_file" ] || die 'BBR 参数文件是符号链接，未覆盖它。'
        [ ! -f "$bbr_file" ] || cp -p "$bbr_file" "$TMP/$(basename "$bbr_file").old"
    done
    trap bbr_restore EXIT
    trap 'exit 130' INT; trap 'exit 143' TERM
    bbr_runtime_changed=1
    # Test effective writes first; a restricted container must not receive a success message.
    if [ -n "$bbr_old_qdisc" ]; then
        sysctl -w net.core.default_qdisc=fq >/dev/null || die '默认队列写入被拒绝，正在恢复原设置。'
        [ "$(bbr_read net.core.default_qdisc)" = fq ] || die '默认队列验证失败，正在恢复原设置。'
    else warn '当前环境没有默认队列参数，将仅开启 TCP BBR。'; fi
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null || die 'BBR 写入被拒绝；容器可能没有权限，正在恢复原设置。'
    [ "$(bbr_read net.ipv4.tcp_congestion_control)" = bbr ] || die 'BBR 验证失败，正在恢复原设置。'
    {
        printf '# Managed by ARGO BBR menu\n'
        [ -z "$bbr_old_qdisc" ] || printf 'net.core.default_qdisc = fq\n'
        printf 'net.ipv4.tcp_congestion_control = bbr\n'
    } > "$TMP/sysctl.new"
    if [ "$MANAGER" = openrc ]; then
        if [ -f "$bbr_modfile" ]; then cp -p "$bbr_modfile" "$TMP/modules.new"
        else : > "$TMP/modules.new"; fi
        for bbr_module in tcp_bbr sch_fq; do
            [ "$bbr_module" != sch_fq ] || [ -n "$bbr_old_qdisc" ] || continue
            grep -Eq "^[[:space:]]*$bbr_module([[:space:]]|$)" "$TMP/modules.new" || printf '\n%s\n' "$bbr_module" >> "$TMP/modules.new"
        done
    else
        printf '# Managed by ARGO BBR menu\ntcp_bbr\n' > "$TMP/modules.new"
        [ -z "$bbr_old_qdisc" ] || printf 'sch_fq\n' >> "$TMP/modules.new"
    fi
    mkdir -p /etc/sysctl.d "$(dirname "$bbr_modfile")"
    bbr_files_changed=1
    # Stage in the destination directory so replacement is atomic on that filesystem.
    cp "$TMP/sysctl.new" "$bbr_sysfile.new"; chmod 644 "$bbr_sysfile.new"; mv "$bbr_sysfile.new" "$bbr_sysfile"
    cp "$TMP/modules.new" "$bbr_modfile.new"; chmod 644 "$bbr_modfile.new"; mv "$bbr_modfile.new" "$bbr_modfile"
    if [ "$MANAGER" = openrc ]; then
        for bbr_service in modules sysctl; do
            if ! rc-update show boot 2>/dev/null | grep -q "^[[:space:]]*$bbr_service[[:space:]]"; then
                case "$bbr_service" in modules) bbr_added_modules=1;; sysctl) bbr_added_sysctl=1;; esac
                rc-update add "$bbr_service" boot || die '开机服务设置失败，正在恢复原设置。'
            fi
        done
    fi
    bbr_committed=1
    good 'BBR 已开启，开机参数已保存。'
    printf '  %sBBR 作用于新建 TCP 连接；QUIC 使用 UDP，不受此设置控制。%s\n' "$C_DIM" "$C_RESET"
    if [ -n "$bbr_old_qdisc" ]; then
        printf '  %s默认队列已设置 fq；现有网卡队列未强制替换，不一定立即变化。%s\n' "$C_DIM" "$C_RESET"
    fi
}
bbr_current_status() {
    printf '\n%s  【 当前 BBR 状态 】%s\n' "$C_CYAN" "$C_RESET"; rule
    bbr_current=$(bbr_read net.ipv4.tcp_congestion_control || true)
    case "$bbr_current" in
        bbr) good '当前 TCP 拥塞控制：BBR（已开启）';;
        '') warn '当前 TCP 拥塞控制：无法读取（无法确认是否开启 BBR）';;
        *) warn "当前 TCP 拥塞控制：$bbr_current（未使用 BBR）";;
    esac
    bbr_queue=$(bbr_read net.core.default_qdisc || true)
    printf '  默认队列规则：%s%s%s\n' "$C_PURPLE" "${bbr_queue:-此环境无法读取}" "$C_RESET"
    if [ -s /etc/sysctl.d/99-zz-argo-bbr.conf ] &&
       grep -Eq '^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr([[:space:]]|$)' /etc/sysctl.d/99-zz-argo-bbr.conf; then
        printf '  开机参数：%s已保存%s\n' "$C_GREEN" "$C_RESET"
    else
        printf '  开机参数：%s本脚本未保存%s\n' "$C_DIM" "$C_RESET"
    fi
}

bbr_menu() {
    while :; do
        bbr_status
        menu_item "$C_INSTALL" '1.' '开启 BBR（保存开机参数）'
        menu_item "$C_BLUE" '2.' '查看状态'
        menu_item "$C_DIM" '0.' '返回首页'
        ask '请选择 [0–2]：'
        case "$REPLY" in
            1) run_action bbr_enable;;
            2) bbr_current_status; ask '按回车返回 BBR 菜单：';;
            0) return;;
            *) retry_input '请输入 0、1 或 2。';;
        esac
    done
}

