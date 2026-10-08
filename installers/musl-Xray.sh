#!/usr/bin/env bash
set -eu
[ -x /usr/local/lib/argo-node-files/run ] || { echo "请通过完整 VPSKit 安装入口运行。" >&2; exit 1; }
umask 077
# =========================================
# Alpine NAT 小内存机用途（64M / 128M；实际内存需求需实测）
# 一键安装 Xray-core (musl)
# 生成 VLESS + 自签 TLS
# 默认端口 443，可自选
# =========================================

CONFIG_DIR="/etc/xray"
CERT_DIR="$CONFIG_DIR/cert"
XRAY_BIN="/usr/local/bin/xray"

# 默认端口
DEFAULT_PORT=443

# 证书 / SNI 用的域名
DOMAIN="kyn.com"

# 客户端实际连接用的公网 IP（请改成你的真实 IP）
command -v curl >/dev/null 2>&1 || apk add --no-cache curl ca-certificates
CONNECT_ADDR=$(curl -fLsS --connect-timeout 5 --max-time 10 https://api.ipify.org || curl -fLsS --connect-timeout 5 --max-time 10 https://ipv4.icanhazip.com)
CONNECT_ADDR=$(printf '%s' "$CONNECT_ADDR" | tr -d ' \r\n')

# 检查 root
if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 执行"
    exit 1
fi

# 选择端口；显示提示前丢弃前一层菜单残留的终端输入。
echo "===================================="
echo "VLESS 端口设置"
if [ -t 0 ]; then
    python3 -c 'import termios; termios.tcflush(0, termios.TCIFLUSH)'
fi
while :; do
    read -r -p "请输入 VLESS 端口 [默认 ${DEFAULT_PORT}]： " VLESS_PORT
    VLESS_PORT=$(printf '%s' "$VLESS_PORT" | tr -d ' \t\r')
    VLESS_PORT=${VLESS_PORT:-$DEFAULT_PORT}
    if ! [[ "$VLESS_PORT" =~ ^[0-9]{1,5}$ ]] || [ "$VLESS_PORT" -lt 1 ] || [ "$VLESS_PORT" -gt 65535 ]; then
        echo "端口必须是 1–65535 的数字，请重新输入。"
        continue
    fi
    VLESS_PORT=$((10#$VLESS_PORT))
    break
done
echo "使用端口：$VLESS_PORT"
echo "===================================="

# 创建目录
mkdir -p "$CONFIG_DIR" "$CERT_DIR"

# 安装依赖（补上 unzip）
apk update
apk add -q curl openssl jq tar unzip python3 ca-certificates

# 生成自签 TLS（用域名 kyn.com）
echo "生成自签 TLS..."
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt" \
  -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN" -addext "basicConstraints=critical,CA:FALSE" -addext "extendedKeyUsage=serverAuth"

# Download the release asset matching this machine into a private directory.
DOWNLOAD_STAGE=$(mktemp -d)
trap 'rm -rf -- "$DOWNLOAD_STAGE"' EXIT
case "$(uname -m)" in
    x86_64) ASSET="Xray-linux-64.zip";;
    aarch64|arm64) ASSET="Xray-linux-arm64-v8a.zip";;
    *) echo "不支持的架构" >&2; exit 1;;
esac
curl -fLsS --connect-timeout 15 --max-time 60 https://api.github.com/repos/XTLS/Xray-core/releases/latest -o "$DOWNLOAD_STAGE/release.json"
DOWNLOAD_URL=$(jq -er --arg name "$ASSET" '.assets[] | select(.name==$name) | .browser_download_url' "$DOWNLOAD_STAGE/release.json")
case "$DOWNLOAD_URL" in https://github.com/XTLS/Xray-core/releases/download/*) :;; *) echo "下载地址无效" >&2; exit 1;; esac
curl -fLsS --connect-timeout 15 --max-time 300 "$DOWNLOAD_URL" -o "$DOWNLOAD_STAGE/xray.zip"
unzip -q "$DOWNLOAD_STAGE/xray.zip" -d "$DOWNLOAD_STAGE/core"
"$DOWNLOAD_STAGE/core/xray" version
install -m 755 "$DOWNLOAD_STAGE/core/xray" "$XRAY_BIN"

# 生成 UUID
VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)

# 生成配置文件（serverName 仍然是域名 kyn.com）
cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": { "loglevel": "info" },
  "inbounds": [
    {
      "port": $VLESS_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$VLESS_UUID" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "$DOMAIN",
          "certificates": [
            {
              "certificateFile": "$CERT_DIR/server.crt",
              "keyFile": "$CERT_DIR/server.key"
            }
          ]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF

USE_DOMAIN=0
mkdir -p /usr/local/lib/xray-node-sync /var/lib/xray-node-sync
chmod 700 /usr/local/lib/xray-node-sync /var/lib/xray-node-sync
cat > /usr/local/lib/xray-node-sync/run <<'XRAY_SYNC_PY'
#!/usr/bin/env python3
import fcntl,hashlib,ipaddress,json,os,pathlib,re,subprocess,sys,tempfile,time,urllib.parse,uuid
STATE=pathlib.Path('/var/lib/xray-node-sync')
RUN=pathlib.Path('/run/xray-node-sync')
CONFIG=pathlib.Path('/etc/xray/config.json')
BINARY='/usr/local/bin/xray'
OUTPUT=pathlib.Path('/etc/nodes/xray/links.txt')
def run(args,**kw):
    return subprocess.run(args,check=True,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=20,**kw).stdout
def read(p):return json.loads(pathlib.Path(p).read_text())
def atomic(p,data):
    p=pathlib.Path(p);p.parent.mkdir(parents=True,exist_ok=True)
    fd,name=tempfile.mkstemp(prefix='.'+p.name+'-',dir=p.parent)
    try:
        os.fchmod(fd,0o600)
        with os.fdopen(fd,'wb') as f:f.write(data.encode() if isinstance(data,str) else data);f.flush();os.fsync(f.fileno())
        os.replace(name,p)
    finally:
        if os.path.exists(name):os.unlink(name)
def write(p,data):atomic(p,json.dumps(data,ensure_ascii=False))
def digest(data):return hashlib.sha256(data).hexdigest()
def country(ip):
    try:ip=str(ipaddress.ip_address(ip))
    except ValueError:return ''
    path=STATE/('country-'+digest(ip.encode())[:16]+'.json');now=time.time()
    cache={}
    try:cache=read(path)
    except (OSError,ValueError):pass
    if cache.get('expires',0)>now:return cache.get('label','')
    providers=[('https://ipwho.is/'+ip,'country_code','country'),('https://ipapi.co/'+ip+'/json/','country_code','country_name'),('https://ipinfo.io/'+ip+'/json','country',None)]
    for url,code_field,name_field in providers:
        try:
            raw=run(['curl','-fLsS','--connect-timeout','2','--max-time','3',url])
            obj=json.loads(raw);code=obj.get(code_field,'').upper()
            if obj.get('success') is False or obj.get('error') or not re.fullmatch('[A-Z]{2}',code):continue
            flag=''.join(chr(0x1f1e6+ord(c)-65) for c in code)
            name=obj.get(name_field) if name_field else code
            label=flag+(name if isinstance(name,str) and name else code)
            write(path,{'label':label,'expires':now+86400,'ip':ip});return label
        except (ValueError,OSError,subprocess.SubprocessError,AttributeError):continue
    # Keep an old valid country when providers are unavailable; retry failures after 10 minutes.
    label=cache.get('label','');write(path,{'label':label,'expires':now+600,'ip':ip});return label
# Unified TXT publication only; core configuration and readiness checks stay unchanged.
def publish_nodes(content):
    # VPSKIT_SHARED_PUBLICATION
    import runpy
    runpy.run_path('/usr/local/lib/argo-node-files/run',run_name='vpskit_publication')['publish']('xray',content)
def process(pid):
    proc=pathlib.Path('/proc')/str(pid)
    if os.path.realpath(proc/'exe')!=os.path.realpath(BINARY):raise RuntimeError('Xray 进程未运行')
    args=proc.joinpath('cmdline').read_bytes().split(b'\0')
    if str(CONFIG).encode() not in args:raise RuntimeError('运行配置路径不匹配')
    return proc.joinpath('stat').read_text().rsplit(')',1)[1].split()[19]
def listeners(pid,ports):
    sockets=set()
    for fd in pathlib.Path('/proc',str(pid),'fd').iterdir():
        try:
            target=os.readlink(fd)
            if target.startswith('socket:['):sockets.add(target[8:-1])
        except OSError:pass
    ready=set()
    for table in ('tcp','tcp6'):
        for line in pathlib.Path('/proc',str(pid),'net',table).read_text().splitlines()[1:]:
            fields=line.split()
            if fields[3]=='0A' and fields[9] in sockets:ready.add(int(fields[1].split(':')[1],16))
    if not set(ports)<=ready:raise RuntimeError('Xray 节点端口尚未监听')
def generate(cfg,meta):
    lines=[];ports=[];ip=str(ipaddress.ip_address(meta['ip']))
    location=country(ip);tag='V6PORT' if ':' in ip else 'V4PORT'
    for inbound in cfg.get('inbounds',[]):
        stream=inbound.get('streamSettings',{})
        if inbound.get('protocol')!='vless' or stream.get('security')!='tls' or stream.get('network','tcp') not in ('tcp','raw'):
            raise RuntimeError('仅支持这些安装脚本的 VLESS TCP TLS 配置')
        port=int(inbound['port']);sni=stream['tlsSettings']['serverName']
        if not 1<=port<=65535 or not sni:raise RuntimeError('端口或 SNI 无效')
        host=sni if meta['domain_mode'] else ip
        if re.search(r'[\s/@?#]',host):raise RuntimeError('节点地址无效')
        host_uri='['+host+']' if ':' in host else host
        params=dict(type='tcp',encryption='none',security='tls',sni=sni,allowInsecure='0')
        certificates=stream['tlsSettings'].get('certificates',[])
        if len(certificates)!=1 or not certificates[0].get('certificateFile'):
            raise RuntimeError('无法确定节点使用的证书，保留旧链接')
        # Hash the leaf certificate DER, not the PEM file or public key.
        der=run(['openssl','x509','-in',certificates[0]['certificateFile'],'-outform','DER'])
        if not der:raise RuntimeError('证书读取失败，保留旧链接')
        params['pcs']=hashlib.sha256(der).hexdigest()
        query=urllib.parse.urlencode(params,quote_via=urllib.parse.quote)
        name='VLESS-TLS-'+tag+'-'+host+('-'+location if location else '')
        for user in inbound['settings']['clients']:
            uid=str(uuid.UUID(user['id']))
            if user.get('flow'):raise RuntimeError('未知 flow，保留旧链接')
            lines.append('vless://'+uid+'@'+host_uri+':'+str(port)+'?'+query+'#'+urllib.parse.quote(name,safe=''))
        ports.append(port)
    if not lines:raise RuntimeError('没有有效节点')
    return '\n'.join(lines)+'\n',ports
def sync():
    active=read(RUN/'active.json');pid=active['pid']
    if process(pid)!=active['ticks']:raise RuntimeError('Xray 进程已改变，需通过同步启动器启动')
    data=CONFIG.read_bytes()
    if digest(data)!=active['sha']:raise RuntimeError('新配置未确认加载，保留旧链接')
    run([BINARY,'run','-test','-config',str(CONFIG)])
    content,ports=generate(json.loads(data),read(STATE/'deployment.json'))
    listeners(pid,ports)
    if process(pid)!=active['ticks'] or CONFIG.read_bytes()!=data:raise RuntimeError('生成期间配置或进程改变')
    publish_nodes(content)
def main():
    for p in (STATE,RUN):p.mkdir(parents=True,exist_ok=True);os.chmod(p,0o700)
    with open(RUN/'lock','a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        if len(sys.argv)>1 and sys.argv[1]=='--launch':
            data=CONFIG.read_bytes();run([BINARY,'run','-test','-config',str(CONFIG)])
            if CONFIG.read_bytes()!=data:raise RuntimeError('启动前配置改变')
            ticks=pathlib.Path('/proc',str(os.getpid()),'stat').read_text().rsplit(')',1)[1].split()[19]
            write(RUN/'active.json',dict(pid=os.getpid(),ticks=ticks,sha=digest(data)))
            fcntl.flock(lock,fcntl.LOCK_UN);lock.close()
            os.execv(BINARY,[BINARY,'run','-config',str(CONFIG)])
        else:sync()
if __name__=='__main__':
    try:main()
    except Exception as e:
        print('节点同步失败，保留旧链接：'+(str(e) if isinstance(e,RuntimeError) else type(e).__name__),file=sys.stderr)
        sys.exit(1)
XRAY_SYNC_PY
chmod 700 /usr/local/lib/xray-node-sync/run
python3 - "$CONNECT_ADDR" "$USE_DOMAIN" <<'XRAY_META_PY'
import json,os,tempfile,sys
path='/var/lib/xray-node-sync/deployment.json'
fd,name=tempfile.mkstemp(dir=os.path.dirname(path));os.fchmod(fd,0o600)
with os.fdopen(fd,'w') as f:json.dump(dict(ip=sys.argv[1].strip(),domain_mode=sys.argv[2]=='1'),f)
os.replace(name,path)
XRAY_META_PY
# 由启动器确认当前加载的配置，避免未生效的修改覆盖分享链接。
sed -i "\|^alias xray='/usr/local/bin/xray-info'$|d" /etc/profile
python3 /usr/local/lib/argo-standalone/manager.py xray-stop
nohup /usr/local/lib/xray-node-sync/run --launch >/var/log/xray.log 2>&1 &
sleep 2
if ! /usr/local/lib/xray-node-sync/run --once; then
    echo "Xray 节点校验失败，保留旧链接，请查看 /var/log/xray.log"
    exit 1
fi
# 每分钟同步；保留 acme.sh 等已有 cron 任务。
rc-update add crond default
rc-service crond start
CRON_STAGE=$(mktemp)
crontab -l 2>/dev/null | sed '\|# xray-node-sync$|d' > "$CRON_STAGE" || true
printf '%s\n' '* * * * * /usr/local/lib/xray-node-sync/run --once >> /var/log/xray-node-sync.log 2>&1 # xray-node-sync' >> "$CRON_STAGE"
crontab "$CRON_STAGE"
rm -f "$CRON_STAGE"
echo "========================="
echo "节点链接：/etc/nodes/xray/links.txt"
echo "合并订阅：/etc/nodes/subscription.txt"
echo "配置路径：/etc/xray/config.json"
echo "日志路径：/var/log/xray.log"
echo "已启用每 60 秒自动同步；未加载或校验失败的配置不会覆盖旧链接。"
echo "管理入口：VPSKit → Xray → 重启并同步节点"
echo "========================="
echo "安装完成！"
