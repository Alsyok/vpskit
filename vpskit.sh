#!/usr/bin/env bash
set -Eeuo pipefail
# Upload this entire directory to Alsyok/vpskit, branch main.
VPSKIT_BASE_URL=${VPSKIT_BASE_URL:-https://raw.githubusercontent.com/Alsyok/vpskit/main}
source_file=${BASH_SOURCE[0]}
source_file=$(readlink -f -- "$source_file" 2>/dev/null || printf '%s' "$source_file")
VPSKIT_ROOT=$(cd -- "$(dirname -- "$source_file")" 2>/dev/null && pwd || true)
if [[ ! -f "$VPSKIT_ROOT/lib/common.sh" ]]; then
    [[ $EUID -eq 0 ]] || { echo '请使用 root 运行。' >&2; exit 1; }
    if ! command -v curl >/dev/null; then
        if command -v apk >/dev/null; then apk add --no-cache curl ca-certificates;
        elif command -v apt-get >/dev/null; then apt-get update; apt-get install -y curl ca-certificates;
        else echo '仅支持 Alpine、Debian 和 Ubuntu。' >&2; exit 1; fi
    fi
    command -v sha256sum >/dev/null || { echo '缺少 sha256sum。' >&2; exit 1; }
    mkdir -p /usr/local/lib
    stage=$(mktemp -d /usr/local/lib/.vpskit-download.XXXXXX)
    trap 'rm -rf -- "$stage"' EXIT
    curl -fLsS --connect-timeout 15 --max-time 120 "$VPSKIT_BASE_URL/manifest.sha256" -o "$stage/manifest.sha256"
    while read -r digest file extra; do
        [[ $digest =~ ^[a-f0-9]{64}$ && -z ${extra:-} ]] || { echo '下载清单无效。' >&2; exit 1; }
        case "$file" in
            vpskit.sh|VERSION|README.md|lib/*.sh|lib/*.py|modules/*.sh|installers/*.sh) ;;
            *) echo '下载清单包含未知路径。' >&2; exit 1;;
        esac
        [[ $file != *..* && $file != /* ]] || exit 1
        mkdir -p "$stage/$(dirname -- "$file")"
        curl -fLsS --connect-timeout 15 --max-time 120 "$VPSKIT_BASE_URL/$file" -o "$stage/$file"
    done < "$stage/manifest.sha256"
    (cd "$stage" && sha256sum -c manifest.sha256 >/dev/null)
    for required in vpskit.sh lib/common.sh lib/bbr.sh lib/node-services.sh lib/standalone.sh lib/node-manager.py lib/subscription-manager.py lib/subscription-cert-sync.py lib/node-files.py lib/sync-publication.py modules/CFtunnel.sh modules/singbox-manager.sh modules/xray-manager.sh modules/subscription-manager.sh modules/cert-manager.sh modules/tools.sh installers/singbox.sh installers/Encrypt.sh installers/musl-Xray.sh installers/install-Xray-core.sh installers/install_subscription.sh; do
        [[ -s "$stage/$required" ]] || { echo '下载包缺少必要文件。' >&2; exit 1; }
    done
    bash -n "$stage/vpskit.sh"
    for file in "$stage"/modules/*.sh "$stage"/lib/*.sh; do sh -n "$file"; done
    for file in "$stage"/installers/*.sh; do bash -n "$file"; done
    chmod -R go-rwx "$stage"
    chmod 700 "$stage/vpskit.sh"
    destination=/usr/local/lib/vpskit
    backup=$(mktemp -d /usr/local/lib/.vpskit-backup.XXXXXX); rmdir "$backup"
    [[ ! -e $destination ]] || mv "$destination" "$backup"
    if ! mv "$stage" "$destination"; then [[ ! -d $backup ]] || mv "$backup" "$destination"; exit 1; fi
    rm -rf -- "$backup"
    trap - EXIT
    mkdir -p /usr/local/bin
    ln -sfn "$destination/vpskit.sh" /usr/local/bin/vpskit
    exec bash "$destination/vpskit.sh" "$@"
fi
export VPSKIT_ROOT
if [[ ${1:-menu} != menu ]]; then
    case "${1:-}" in
        argo|singbox|xray|subscription|tools)
            case "$1" in argo) module=CFtunnel;; singbox) module=singbox-manager;; xray) module=xray-manager;; subscription) module=subscription-manager;; tools) module=tools;; esac
            shift; exec sh "$VPSKIT_ROOT/modules/$module.sh" "${@:-menu}";;
        *) echo '用法：bash vpskit.sh [menu | argo/singbox/xray/subscription/tools 操作]' >&2; exit 1;;
    esac
fi
# Run POSIX modules as separate processes so "返回" always returns here.
. "$VPSKIT_ROOT/lib/common.sh"
detect
. "$VPSKIT_ROOT/lib/node-services.sh"
upgrade_node_publication
while :; do
    printf '\n%s  【 VPSKit · 服务器工具箱 】%s\n' "$C_CYAN" "$C_RESET"; rule
    menu_item "$C_CYAN" '1.' 'ARGO · 隧道与节点管理'
    menu_item "$C_INSTALL" '2.' 'Singbox 一键安装'
    menu_item "$C_BLUE" '3.' 'Xray 一键安装'
    menu_item "$C_PURPLE" '4.' '订阅链接安装'
    menu_item "$C_YELLOW" '5.' 'Tools · BBR / VPS 清理'
    menu_item "$C_DIM" '6.' '退出'
    ask '请选择 [1–6]：'
    case "$REPLY" in
        1) module=CFtunnel;; 2) module=singbox-manager;; 3) module=xray-manager;;
        4) module=subscription-manager;; 5) module=tools;; 6|0) exit 0;;
        *) retry_input '请输入 1–6。'; continue;;
    esac
    set +e
    sh "$VPSKIT_ROOT/modules/$module.sh" menu
    module_result=$?
    set -e
    [[ $module_result != 130 && $module_result != 143 ]] || exit "$module_result"
    [[ $module_result -eq 0 ]] || warn '模块未完成，请查看上面的错误提示。' 
done
