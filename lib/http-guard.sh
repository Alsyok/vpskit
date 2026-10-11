#!/bin/sh
# Execute HTTP-01 without silently stopping an unrelated service.
vpskit_http_run() (
    http_paused=
    http_restore() {
        for http_name in $http_paused; do
            if command -v rc-service >/dev/null 2>&1; then rc-service "$http_name" start;
            else systemctl start "$http_name"; fi || printf '恢复 %s 失败，请手动启动。\n' "$http_name" >&2
        done
    }
    trap http_restore EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    while ss -lnt | grep -qE ':[[:space:]]*80[[:space:]]'; do
        printf 'HTTP 验证需要 TCP 80：1 重试 / 2 临时停止已知 Web 服务 / 0 返回（也可先到证书菜单使用 DNS 验证）：' >&2
        IFS= read -r http_choice || exit 20
        case "$http_choice" in
            1) continue;;
            2)
                http_found=
                for http_name in nginx caddy apache2 httpd; do
                    if command -v rc-service >/dev/null 2>&1; then
                        rc-service "$http_name" status >/dev/null 2>&1 || continue
                    else systemctl is-active --quiet "$http_name" || continue; fi
                    printf '临时停止 %s，并在申请结束后恢复？输入 y：' "$http_name" >&2
                    IFS= read -r http_answer || exit 20
                    case "$http_answer" in y|Y|yes|YES)
                        http_paused="$http_paused $http_name"
                        if command -v rc-service >/dev/null 2>&1; then rc-service "$http_name" stop;
                        else systemctl stop "$http_name"; fi || exit 1
                        http_found=1;;
                    esac
                done
                [ -n "$http_found" ] || printf '没有选择可暂停的服务；请选择重试或返回。\n' >&2;;
            0) exit 20;;
            *) printf '请输入 0、1 或 2。\n' >&2;;
        esac
    done
    "$@"
)
