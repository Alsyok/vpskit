# ============================================================
# 独立日志维护：5 MiB / 最多 3 份 / 轮转后保留 15 天
# ============================================================
install_log_maintenance() {
    mkdir -p /usr/local/lib/argo-log-maintenance
    cat > /usr/local/lib/argo-log-maintenance/run <<'LOGWORKER'
#!/bin/sh
set -eu
umask 077
LOCK=/run/argo-log-maintenance.lock
# flock 随进程退出释放锁；BusyBox 和 util-linux 均支持。
exec 9>"$LOCK"
flock -n 9 || exit 0
NOW=$(date +%s)
LIMIT=5242880
AGE=1296000
rotate_log() {
    file=$1
    [ ! -L "$file" ] || return 0
    # 只处理本模块生成的数字后缀旧日志。
    for number in 1 2 3; do
        old="$file.$number"
        [ -f "$old" ] && [ ! -L "$old" ] || continue
        stamp=$(stat -c %Y "$old")
        if [ "$((NOW - stamp))" -gt "$AGE" ]; then rm -f "$old"; fi
    done
    [ -f "$file" ] || return 0
    size=$(stat -c %s "$file")
    [ "$size" -ge "$LIMIT" ] || return 0
    # 临时域名首次缓存通常由查询功能写入；轮转前补存，避免丢失。
    if [ "$file" = /var/log/vps-tunnel/cloudflared.log ] &&
       [ "$(cat /etc/vps-tunnel/mode 2>/dev/null || true)" = quick ]; then
        domain=$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$file" | tail -n 1 || true)
        if [ -n "$domain" ]; then
            printf '%s\n' "${domain#https://}" > /etc/vps-tunnel/domain-cache
        fi
    fi
    # 复制成功再截断；保持当前日志的 inode 和服务文件描述符。
    # 新旧文件间存在极短窗口，可能丢失少量并发写入日志。
    [ ! -L "$file.1" ] && [ ! -L "$file.2" ] && [ ! -L "$file.3" ] || return 0
    rm -f "$file.3"
    [ ! -f "$file.2" ] || mv -f "$file.2" "$file.3"
    [ ! -f "$file.1" ] || mv -f "$file.1" "$file.2"
    cp "$file" "$file.1"
    chmod 600 "$file.1"
    touch "$file.1"
    : > "$file"
}
for file in /var/log/vps-tunnel/*.log \
    /var/log/vps-tunnel-service.log /var/log/vps-node.log \
    /var/log/vps-cf-sync.log /var/log/xray.log /var/log/xray-node-sync.log /var/log/sing-box/*.log \
    /var/log/sing-box/sing-box.stdout /var/log/sing-box/sing-box.err /etc/argo-certificates/renew.log \
    /etc/argo-certificates/logs/*.log; do
    rotate_log "$file"
done
LOGWORKER
    chmod 700 /usr/local/lib/argo-log-maintenance/run
    if ! command -v flock >/dev/null 2>&1; then
        if [ "$MANAGER" = openrc ]; then apk add --no-cache util-linux
        else apt-get install -y util-linux; fi
    fi
    if [ "$MANAGER" = openrc ]; then
        command -v crond >/dev/null 2>&1 || apk add --no-cache busybox
        mkdir -p /etc/crontabs
        # 只替换本模块的条目，保留用户其它 cron 任务。
        log_cron_tmp=$(mktemp)
        if [ -f /etc/crontabs/root ]; then
            sed '\|# argo-log-maintenance$|d' /etc/crontabs/root > "$log_cron_tmp"
        fi
        printf '%s\n' '* * * * * /usr/local/lib/argo-log-maintenance/run # argo-log-maintenance' >> "$log_cron_tmp"
        cat "$log_cron_tmp" > /etc/crontabs/root
        chmod 600 /etc/crontabs/root
        rm -f "$log_cron_tmp"
        rc-update add crond default
        rc-service crond start
    else
        cat > /etc/systemd/system/argo-log-maintenance.service <<'LOGUNIT'
[Unit]
Description=Rotate ARGO managed file logs
[Service]
Type=oneshot
ExecStart=/usr/local/lib/argo-log-maintenance/run
UMask=0077
LOGUNIT
        cat > /etc/systemd/system/argo-log-maintenance.timer <<'LOGTIMER'
[Unit]
Description=Check ARGO managed log files every minute
[Timer]
OnBootSec=60s
OnUnitActiveSec=60s
AccuracySec=5s
[Install]
WantedBy=timers.target
LOGTIMER
        systemctl daemon-reload
        systemctl enable --now argo-log-maintenance.timer
    fi
}
remove_unused_log_maintenance() {
    # 仍有独立节点、同步或证书功能时保留共用维护任务。
    [ ! -d /etc/vps-tunnel ] && [ ! -d /etc/vps-node ] &&
    [ ! -f /etc/sing-box/config.json ] && [ ! -f /etc/xray/config.json ] && [ ! -d /etc/argo-certificates ] &&
    [ ! -f /etc/init.d/vps-cf-sync ] &&
    [ ! -f /etc/systemd/system/vps-cf-sync.service ] || return 0
    if [ "$MANAGER" = openrc ]; then
        if [ -f /etc/crontabs/root ]; then
            log_cron_tmp=$(mktemp)
            sed '\|# argo-log-maintenance$|d' /etc/crontabs/root > "$log_cron_tmp"
            cat "$log_cron_tmp" > /etc/crontabs/root
            rm -f "$log_cron_tmp"
        fi
    else
        systemctl disable --now argo-log-maintenance.timer >/dev/null 2>&1 || true
        systemctl stop argo-log-maintenance.service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/argo-log-maintenance.timer /etc/systemd/system/argo-log-maintenance.service
        systemctl daemon-reload
    fi
    rm -rf /usr/local/lib/argo-log-maintenance
}

# Unified node TXT storage; core configurations retain their original paths.
install_node_files() {
    if ! command -v python3 >/dev/null 2>&1; then
        if [ "$MANAGER" = openrc ]; then apk add --no-cache python3
        else apt-get update && apt-get install -y python3; fi
    fi
    mkdir -p /usr/local/lib/argo-node-files
    chmod 700 /usr/local/lib/argo-node-files
    cat > /usr/local/lib/argo-node-files/run.new <<'NODE_FILES_PY'
#!/usr/bin/env python3
import fcntl,os,pathlib,re,sys,tempfile
ROOT=pathlib.Path('/etc/nodes')
LOCK=pathlib.Path('/run/nodes-publication')
def atomic(p,data):
    p=pathlib.Path(p);p.parent.mkdir(parents=True,exist_ok=True)
    fd,name=tempfile.mkstemp(prefix='.'+p.name+'-',dir=p.parent)
    try:
        os.fchmod(fd,0o600)
        with os.fdopen(fd,'wb') as f:f.write(data.encode() if isinstance(data,str) else data);f.flush();os.fsync(f.fileno())
        os.replace(name,p)
    finally:
        if os.path.exists(name):os.unlink(name)
def lines(text):
    result=[]
    for line in text.splitlines():
        line=line.strip()
        if not line or line.startswith('#'):continue
        if not re.match(r'^[a-zA-Z][a-zA-Z0-9+.-]*://\S+$',line):raise RuntimeError('链接文件含无效行')
        if line not in result:result.append(line)
    return result
def publish(group,content=None,info=None,remove=False):
    if group not in ('argo','sing-box','xray'):raise RuntimeError('未知节点组')
    ROOT.mkdir(parents=True,exist_ok=True);os.chmod(ROOT,0o700)
    LOCK.mkdir(parents=True,exist_ok=True);os.chmod(LOCK,0o700)
    with open(LOCK/'lock','a') as lock:
        os.chmod(LOCK/'lock',0o600);fcntl.flock(lock,fcntl.LOCK_EX)
        target=ROOT/group/'links.txt'
        entries=[] if remove else lines(content)
        if not remove and not entries:raise RuntimeError('没有有效节点')
        merged=[]
        for source in ('argo','sing-box','xray'):
            p=ROOT/source/'links.txt'
            for line in (entries if source==group else (lines(p.read_text()) if p.exists() else [])):
                if line not in merged:merged.append(line)
        changes=[(target,None if remove else '\n'.join(entries)+'\n')]
        if info is not None or remove:changes.append((ROOT/group/'info.txt',None if remove else info))
        changes.append((ROOT/'subscription.txt','\n'.join(merged)+('\n' if merged else '')))
        previous={p:p.read_bytes() if p.exists() else None for p,_ in changes};touched=[]
        try:
            for p,text in changes:
                if text is None:
                    if p.exists():touched.append(p);p.unlink()
                elif previous[p]!=text.encode():touched.append(p);atomic(p,text)
                elif p.exists():os.chmod(p,0o600)
            if target.parent.exists():os.chmod(target.parent,0o700)
        except BaseException:
            for p in reversed(touched):
                if previous[p] is None:
                    if p.exists():p.unlink()
                else:atomic(p,previous[p])
            raise
if __name__=='__main__':
    try:
        mode,group=sys.argv[1:3]
        if mode=='--remove':publish(group,remove=True)
        elif mode=='--publish':
            content=pathlib.Path(sys.argv[3]).read_text() if len(sys.argv)>3 else sys.stdin.read()
            info=pathlib.Path(sys.argv[4]).read_text() if len(sys.argv)>4 else None
            publish(group,content,info)
        else:raise RuntimeError('未知操作')
    except Exception as e:
        print('节点文件更新失败，保留旧文件：'+type(e).__name__,file=sys.stderr);sys.exit(1)
NODE_FILES_PY
    chmod 700 /usr/local/lib/argo-node-files/run.new
    mv /usr/local/lib/argo-node-files/run.new /usr/local/lib/argo-node-files/run
}

