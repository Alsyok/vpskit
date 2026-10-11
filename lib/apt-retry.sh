#!/bin/sh
# Keep apt signature checks; disabling a source always requires an explicit choice.
vpskit_apt_update() {
    while :; do
        apt_log=$(mktemp) || return 1
        if apt-get update >"$apt_log" 2>&1; then cat "$apt_log"; rm -f "$apt_log"; return 0; fi
        cat "$apt_log"
        printf '\nAPT 更新失败：1 重试 / 2 选择并禁用报错源文件 / 0 返回：' >&2
        IFS= read -r apt_choice || { rm -f "$apt_log"; return 1; }
        case "$apt_choice" in
            1) rm -f "$apt_log"; continue;;
            2)
                # Only offer files containing a URL actually reported as an error.
                apt_urls=$(sed -nE '/^(Err:|E: Failed to fetch)/s@.*(https?://[^ /]+).*@\1@p' "$apt_log" | sort -u)
                apt_candidates=$(mktemp) || { rm -f "$apt_log"; return 1; }
                for apt_file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
                    [ -f "$apt_file" ] || continue
                    [ ! -L "$apt_file" ] || continue
                    for apt_url in $apt_urls; do
                        if grep -Fq "$apt_url" "$apt_file"; then printf '%s\n' "$apt_file" >>"$apt_candidates"; break; fi
                    done
                done
                if [ ! -s "$apt_candidates" ]; then
                    printf '未定位到报错源文件，请修复网络或源后选择重试。\n' >&2
                else
                    cat -n "$apt_candidates" >&2
                    printf '输入文件编号（0 返回）；会禁用整个文件中的源：' >&2
                    IFS= read -r apt_number || apt_number=0
                    case "$apt_number" in ''|*[!0-9]*|0) apt_selected=;; *) apt_selected=$(sed -n "${apt_number}p" "$apt_candidates");; esac
                    if [ -n "$apt_selected" ]; then
                        printf '确认禁用 %s？输入 YES：' "$apt_selected" >&2
                        IFS= read -r apt_confirm || apt_confirm=
                        case "$apt_confirm" in YES|yes)
                            apt_backup="${apt_selected}.vpskit-disabled-$(date +%s)"
                            if [ ! -e "$apt_backup" ]; then mv -- "$apt_selected" "$apt_backup" || { rm -f "$apt_candidates" "$apt_log"; return 1; }; printf '已保存至 %s；恢复时移回原路径。\n' "$apt_backup" >&2; fi;;
                        esac
                    fi
                fi
                rm -f "$apt_candidates";;
            0) rm -f "$apt_log"; return 1;;
            *) printf '请输入 0、1 或 2。\n' >&2;;
        esac
        rm -f "$apt_log"
    done
}
