#!/usr/bin/env python3
"""Independent sing-box and certificate management; never manages vps-node."""
import threading,signal,textwrap,contextlib,functools,base64,copy,datetime,fcntl,getpass,hashlib,importlib.util,ipaddress,json,os,pathlib,re,secrets,shutil,socket,ssl,subprocess,sys,tarfile,tempfile,time,urllib.parse,urllib.request,uuid
ROOT=pathlib.Path('/etc/argo-certificates')
LIB=pathlib.Path('/usr/local/lib/argo-standalone')
CONFIG=pathlib.Path('/etc/sing-box/config.json')
META=pathlib.Path('/var/lib/singbox-node-sync/deployment.json')
RUN=pathlib.Path('/run/singbox-node-sync')
SELF=LIB/'manager.py'
SYNC=LIB/'node-sync.py'
LINKFILES=(pathlib.Path('/etc/nodes/sing-box/links.txt'),)
RC_CORE=pathlib.Path('/etc/init.d/sing-box')
RC_SYNC=pathlib.Path('/etc/init.d/argo-sb-sync')
COLORS={'title':'#81CED6','number':'#DCE3EB','install':'#90EE90','query':'#88B3DF','edit':'#DFC58A','default':'#B5A1DF','prompt':'#9ACD32','ok':'#97CBA8','warn':'#90EE90','error':'#90EE90','retry':'#C084FC','dim':'#A4AFBE','link':'#90EE90'}
def color(key,text):
    if not sys.stdout.isatty() or os.environ.get('TERM','dumb')=='dumb' or os.environ.get('NO_COLOR'):return str(text)
    rgb=COLORS[key].lstrip('#');r,g,b=(int(rgb[i:i+2],16) for i in (0,2,4))
    return f'\033[38;2;{r};{g};{b}m{text}\033[0m'
def say(text,key='title'):print('  '+color(key,text),flush=True)
def title(text):print();say('【 '+text+' 】');say('──────────────────────────────────────────','dim')
def item(n,text,key='query'):print('  '+color('number',str(n)+'.')+'  '+color(key,text))
def prompt(text,default='',secret=False):
    tail=' '+color('default','['+str(default)+']') if default!='' else ''
    label='  '+color('prompt',text)+tail+'：'
    try:
        value=(getpass.getpass(label) if secret and sys.stdin.isatty() else input(label)).strip().strip('\r')
    except EOFError:raise Cancel()
    return value if value else str(default)
def choose(text,options,default=''):
    while True:
        value=prompt(text,default)
        if value in options:return value
        say('↻ 请输入列表中的选项。','retry')
def confirm(text):
    while True:
        value=prompt(text+' '+color('default','输入 “YES/y” 继续，“NO/n” 取消')).lower()
        if value in ('yes','y'):return True
        if value in ('no','n'):return False
        say('↻ 请输入 “YES/y” 或 “NO/n”。','retry')
class Cancel(Exception):pass
class Error(Exception):pass
def atomic(path,data,mode=0o600):
    path=pathlib.Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(dir=path.parent)
    try:
        os.fchmod(fd,mode)
        with os.fdopen(fd,'wb') as f:f.write(data.encode() if isinstance(data,str) else data);f.flush();os.fsync(f.fileno())
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)
_lock_depth=0
@contextlib.contextmanager
def management_lock():
    global _lock_depth
    if _lock_depth:
        _lock_depth+=1
        try:yield
        finally:_lock_depth-=1
        return
    with open(ROOT/'manager.lock','a') as f:
        try:fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:raise Error('已有申请或配置修改正在进行，请先完成或取消原操作。')
        _lock_depth=1
        try:yield
        finally:
            _lock_depth=0;fcntl.flock(f,fcntl.LOCK_UN)
def locked(func):
    @functools.wraps(func)
    def wrapper(*args,**kwargs):
        with management_lock():return func(*args,**kwargs)
    return wrapper
def read(path):return json.loads(pathlib.Path(path).read_text())
def write(path,obj):atomic(path,json.dumps(obj,ensure_ascii=False,indent=2)+'\n')
def managed_run(args,input=None,timeout=None,stream_log=None,**kwargs):
    # Each command owns a process group so cancellation also stops its descendants.
    if input is not None:kwargs['stdin']=subprocess.PIPE
    if stream_log is not None:kwargs.update(stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    child=subprocess.Popen([str(a) for a in args],start_new_session=True,**kwargs)
    reader=None
    if stream_log is not None:
        def forward():
            env=kwargs.get('env') or {}
            private=[str(v) for k,v in env.items() if v and any(word in k.upper() for word in ('TOKEN','SECRET','PASSWORD','CF_KEY','API_KEY'))]
            for raw in iter(child.stdout.readline,b''):
                text=raw.decode(errors='replace')
                for value in private:text=text.replace(value,'[已隐藏]')
                stream_log.write(text.encode());stream_log.flush()
                try:sys.stdout.write(text);sys.stdout.flush()
                except (BrokenPipeError,OSError):pass
        reader=threading.Thread(target=forward,daemon=True);reader.start()
    try:
        if reader is not None:
            if input is not None:
                child.stdin.write(input);child.stdin.close()
            child.wait(timeout=timeout);reader.join(timeout=3);out=err=None
        else:out,err=child.communicate(input=input,timeout=timeout)
        return subprocess.CompletedProcess(args,child.returncode,out,err)
    except BaseException:
        try:os.killpg(child.pid,signal.SIGTERM)
        except ProcessLookupError:pass
        try:child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            try:os.killpg(child.pid,signal.SIGKILL)
            except ProcessLookupError:pass
            child.wait()
        # A child may exit before its descendants; remove any remaining group members.
        try:os.killpg(child.pid,signal.SIGKILL)
        except ProcessLookupError:pass
        if reader is not None:reader.join(timeout=3)
        raise

def call(args,timeout=30,input=None,env=None,log=None,allowed=(0,)):
    if log:
        pathlib.Path(log).parent.mkdir(parents=True,exist_ok=True)
        with open(log,'ab') as f:
            os.chmod(log,0o600)
            if sys.stdin.isatty():result=managed_run(args,input=input,timeout=timeout,env=env,stream_log=f)
            else:result=managed_run(args,input=input,stdout=f,stderr=f,timeout=timeout,env=env)
    else:result=managed_run([str(a) for a in args],input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout,env=env)
    if result.returncode not in allowed:raise Error('命令执行失败：'+str(args[0]).split('/')[-1]+('；日志：'+str(log) if log else '，请检查参数、服务或文件'))
    return result.stdout if not log else b''
def alpine():return pathlib.Path('/etc/alpine-release').exists()
def service(action):
    return call(['rc-service','sing-box',action] if alpine() else ['systemctl',action,'sing-box.service'],timeout=60)
def active():
    try:service('status' if alpine() else 'is-active');return True
    except Exception:return False
def binary():
    result=shutil.which('sing-box')
    if not result:raise Error('尚未安装独立 sing-box，请先选“安装 sing-box”。')
    return result
def config():
    if not CONFIG.exists():raise Error('没有 /etc/sing-box/config.json；此菜单仅管理独立 sing-box。')
    return read(CONFIG)
def domain(value,wildcard=False):
    value=value.strip().lower().rstrip('.')
    check=value[2:] if wildcard and value.startswith('*.') else value
    if len(check)>253 or not re.fullmatch(r'(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}',check):raise Error('请输入完整域名，不含 https://、端口和路径。')
    return value
def domain_input(text,default='',wildcard=False):
    while True:
        value=prompt(text,default)
        try:return domain(value,wildcard)
        except Error as e:say('↻ '+str(e),'retry')
def port_input(old,label="监听端口"):
    while True:
        v=prompt(label,old)
        if v.isdigit() and 1<=int(v)<=65535:return int(v)
        say('↻ 端口应为 1–65535。','retry')
def uuid_input(old):
    while True:
        value=prompt('UUID（输入 G 自动生成，留空保留）',old)
        if value.lower()=='g':return str(uuid.uuid4())
        try:return str(uuid.UUID(value))
        except ValueError:say('↻ UUID 格式不正确。','retry')
def registry():
    path=ROOT/'registry.json'
    return read(path) if path.exists() else {}
def save_registry(db):write(ROOT/'registry.json',db)
def decode_cert(path):
    try:return ssl._ssl._test_decode_cert(str(path))
    except Exception:raise Error('证书 PEM 无法解析。')
def names(cert):return [v for k,v in decode_cert(cert).get('subjectAltName',[]) if k=='DNS']
def check_certificate(cert,key,hostname,seconds=0,trust=False):
    call(['openssl','x509','-in',cert,'-noout','-checkend',str(seconds)])
    host=hostname.lower().rstrip('.')
    dns=names(cert)
    def covers(pattern):
        pattern=pattern.lower().rstrip('.')
        return pattern==host or (pattern.startswith('*.') and not host.startswith('*.') and host.endswith(pattern[1:]) and len(host.split('.'))==len(pattern.split('.')))
    if not any(covers(pattern) for pattern in dns):raise Error('证书未覆盖该 SNI / 域名。')
    a=call(['openssl','x509','-in',cert,'-noout','-pubkey'])
    b=call(['openssl','pkey','-in',key,'-pubout'])
    if a.strip()!=b.strip():raise Error('证书与私钥不匹配。')
    if trust:call(['openssl','verify','-untrusted',cert,cert])
def cert_kind(cert):
    db=registry()
    for row in db.values():
        if str(cert)==row['cert']:return row['kind']
    details=decode_cert(cert)
    if details.get('issuer')==details.get('subject'):
        try:call(['openssl','verify','-check_ss_sig','-CAfile',cert,cert]);return 'self'
        except Error:pass
    return 'formal'
def matching_rows(host):
    rows=[]
    for rid,row in registry().items():
        try:check_certificate(row['cert'],row['key'],host,trust=row['kind']=='formal');rows.append((rid,row))
        except Exception:continue
    return rows

def public_key(private):
    raw=base64.urlsafe_b64decode(private+'='*((4-len(private)%4)%4))
    if len(raw)!=32:raise Error('Reality 私钥无效。')
    der=bytes.fromhex('302e020100300506032b656e04220420')+raw
    pub=call(['openssl','pkey','-inform','DER','-pubout','-outform','DER'],input=der)
    return base64.urlsafe_b64encode(pub[-32:]).decode().rstrip('=')
def geo(ip):
    path=ROOT/('country-'+hashlib.sha256(ip.encode()).hexdigest()[:16]+'.json')
    cache=read(path) if path.exists() else {}
    if cache.get('expires',0)>time.time():return cache.get('label','')
    for url,c,n in [('https://ipwho.is/'+ip,'country_code','country'),('https://ipapi.co/'+ip+'/json/','country_code','country_name'),('https://ipinfo.io/'+ip+'/json','country',None)]:
        try:
            obj=json.loads(call(['curl','-fLsS','--connect-timeout','2','--max-time','3',url],timeout=6));code=obj.get(c,'').upper()
            if obj.get('error') or obj.get('success') is False or not re.fullmatch('[A-Z]{2}',code):continue
            flag=''.join(chr(0x1f1e6+ord(ch)-65) for ch in code);label=flag+(obj.get(n) if n and isinstance(obj.get(n),str) else code)
            write(path,{'label':label,'expires':time.time()+86400});return label
        except Exception:pass
    label=cache.get('label','');write(path,{'label':label,'expires':time.time()+600});return label

def generate_links(cfg,meta,indices=None):
    """Called by both saved installers' sync workers; parameters come from JSON."""
    lines=[];is_alpine=alpine()
    for pos,i in enumerate(cfg.get('inbounds',[])):
        if indices is not None and pos not in indices:continue
        kind=i.get('type');tls=i.get('tls',{});reality=tls.get('reality',{}).get('enabled',False)
        if kind not in ('vless','hysteria2') or i.get('transport') or not tls.get('enabled'):raise Error('节点包含未支持的协议/传输，保留旧链接。')
        sni=domain(tls['server_name']);p=int(i['listen_port'])
        if not 1<=p<=65535:raise Error('监听端口错误。')
        if is_alpine:ip=meta.get('ipv4') or meta.get('ipv6')
        else:ip=meta.get('ipv6' if i.get('listen')=='::' else 'ipv4')
        if not ip:continue
        ip=str(ipaddress.ip_address(ip));host='['+ip+']' if ':' in ip else ip
        insecure='0'
        if not reality:
            ck=cert_kind(tls['certificate_path']);insecure='1' if ck=='self' else '0'
            if ck!='self':host=sni
        for u in i.get('users',[]):
            if kind=='vless':
                uid=str(uuid.UUID(u['uuid']));scheme='vless://';prefix='VLESS-Reality' if reality else 'VLESS-TLS'
                q={'type':'tcp','encryption':'none','security':'reality' if reality else 'tls','sni':sni}
                if reality:
                    ids=tls['reality'].get('short_id',[])
                    if not ids or not re.fullmatch('[a-fA-F0-9]{0,16}',ids[0]) or len(ids[0])%2:raise Error('Short ID 无效。')
                    q.update(fp='chrome',pbk=public_key(tls['reality']['private_key']),sid=ids[0])
                    if u.get('flow'):q['flow']=u['flow']
                elif is_alpine:q['insecure']=insecure
                else:q['allowInsecure']=insecure
            else:
                uid=urllib.parse.quote(u['password'],safe='');scheme='hysteria2://';prefix='HY2';q={'sni':sni,'insecure':insecure}
            family=ipaddress.ip_address(ip).version
            suffix=geo(ip);label=prefix+'-V'+str(family)+'PORT-'+host+('-'+suffix if suffix else '')
            lines.append(scheme+uid+'@'+host+':'+str(p)+'?'+urllib.parse.urlencode(q,quote_via=urllib.parse.quote)+'#'+urllib.parse.quote(label,safe=''))
    if not lines:raise Error('没有可生成的节点。')
    return '\n'.join(lines)+'\n'

# SYNC_SOURCE is populated at build time; no remote code needed for node management.
SYNC_SOURCE='IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJOb2RlIG1ldGFkYXRhIG9ubHk6IG5ldmVyIHJlc3RhcnRzIG9yIGVkaXRzIHNpbmctYm94IGNvbmZpZ3VyYXRpb24uIiIiCmltcG9ydCBiYXNlNjQsZmNudGwsaGFzaGxpYixpcGFkZHJlc3MsanNvbixvcyxwYXRobGliLHJlLHN1YnByb2Nlc3Msc3lzLHRlbXBmaWxlLHRpbWUsdXJsbGliLnBhcnNlLHV1aWQKU1RBVEU9cGF0aGxpYi5QYXRoKCcvdmFyL2xpYi9zaW5nYm94LW5vZGUtc3luYycpCkNPTkZJRz1wYXRobGliLlBhdGgoJy9ldGMvc2luZy1ib3gvY29uZmlnLmpzb24nKQpPVVRQVVQ9cGF0aGxpYi5QYXRoKCcvZXRjL25vZGVzL3NpbmctYm94L2xpbmtzLnR4dCcpClJVTj1wYXRobGliLlBhdGgoJy9ydW4vc2luZ2JveC1ub2RlLXN5bmMnKQpkZWYgcnVuKGFyZ3MsKiprdyk6CiAgICByZXR1cm4gc3VicHJvY2Vzcy5ydW4oYXJncyxjaGVjaz1UcnVlLHN0ZG91dD1zdWJwcm9jZXNzLlBJUEUsc3RkZXJyPXN1YnByb2Nlc3MuREVWTlVMTCx0aW1lb3V0PTIwLCoqa3cpLnN0ZG91dApkZWYgcmVhZChwKTpyZXR1cm4ganNvbi5sb2FkcyhwYXRobGliLlBhdGgocCkucmVhZF90ZXh0KCkpCmRlZiBhdG9taWMocCxkYXRhKToKICAgIHA9cGF0aGxpYi5QYXRoKHApO3AucGFyZW50Lm1rZGlyKHBhcmVudHM9VHJ1ZSxleGlzdF9vaz1UcnVlKQogICAgZmQsbmFtZT10ZW1wZmlsZS5ta3N0ZW1wKHByZWZpeD0nLicrcC5uYW1lKyctJyxkaXI9cC5wYXJlbnQpCiAgICB0cnk6CiAgICAgICAgb3MuZmNobW9kKGZkLDBvNjAwKQogICAgICAgIHdpdGggb3MuZmRvcGVuKGZkLCd3YicpIGFzIGY6Zi53cml0ZShkYXRhLmVuY29kZSgpIGlmIGlzaW5zdGFuY2UoZGF0YSxzdHIpIGVsc2UgZGF0YSk7Zi5mbHVzaCgpO29zLmZzeW5jKGYuZmlsZW5vKCkpCiAgICAgICAgb3MucmVwbGFjZShuYW1lLHApCiAgICBmaW5hbGx5OgogICAgICAgIGlmIG9zLnBhdGguZXhpc3RzKG5hbWUpOm9zLnVubGluayhuYW1lKQojIFVuaWZpZWQgVFhUIHB1YmxpY2F0aW9uIG9ubHk7IGNvcmUgY29uZmlndXJhdGlvbiBhbmQgcmVhZGluZXNzIGNoZWNrcyBzdGF5IHVuY2hhbmdlZC4KTk9ERVM9cGF0aGxpYi5QYXRoKCcvZXRjL25vZGVzJykKUFVCTElTSF9SVU49cGF0aGxpYi5QYXRoKCcvcnVuL25vZGVzLXB1YmxpY2F0aW9uJykKZGVmIGxpbmtfbGluZXMoY29udGVudCk6CiAgICByZXN1bHQ9W10KICAgIGZvciBsaW5lIGluIGNvbnRlbnQuc3BsaXRsaW5lcygpOgogICAgICAgIGxpbmU9bGluZS5zdHJpcCgpCiAgICAgICAgaWYgbm90IGxpbmUgb3IgbGluZS5zdGFydHN3aXRoKCcjJyk6Y29udGludWUKICAgICAgICBpZiBub3QgcmUubWF0Y2gocideW2EtekEtWl1bYS16QS1aMC05Ky4tXSo6Ly9cUyskJyxsaW5lKToKICAgICAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCfoioLngrnpk77mjqXmlofku7blkKvml6DmlYjooYzvvIzkv53nlZnml6fmlofku7YnKQogICAgICAgIGlmIGxpbmUgbm90IGluIHJlc3VsdDpyZXN1bHQuYXBwZW5kKGxpbmUpCiAgICByZXR1cm4gcmVzdWx0CmRlZiBwdWJsaXNoX25vZGVzKGNvbnRlbnQpOgogICAgbGluZXM9bGlua19saW5lcyhjb250ZW50KQogICAgaWYgbm90IGxpbmVzOnJhaXNlIFJ1bnRpbWVFcnJvcign5pyq55Sf5oiQ5pyJ5pWI6IqC54K577yM5L+d55WZ5pen5paH5Lu2JykKICAgIFBVQkxJU0hfUlVOLm1rZGlyKHBhcmVudHM9VHJ1ZSxleGlzdF9vaz1UcnVlKTtvcy5jaG1vZChQVUJMSVNIX1JVTiwwbzcwMCkKICAgIE5PREVTLm1rZGlyKHBhcmVudHM9VHJ1ZSxleGlzdF9vaz1UcnVlKTtvcy5jaG1vZChOT0RFUywwbzcwMCkKICAgIHdpdGggb3BlbihQVUJMSVNIX1JVTi8nbG9jaycsJ2EnKSBhcyBwdWJsaWNhdGlvbl9sb2NrOgogICAgICAgIG9zLmNobW9kKFBVQkxJU0hfUlVOLydsb2NrJywwbzYwMCkKICAgICAgICBmY250bC5mbG9jayhwdWJsaWNhdGlvbl9sb2NrLGZjbnRsLkxPQ0tfRVgpCiAgICAgICAgbWVyZ2VkPVtdCiAgICAgICAgZm9yIGdyb3VwIGluICgnYXJnbycsJ3NpbmctYm94JywneHJheScpOgogICAgICAgICAgICBzb3VyY2U9Tk9ERVMvZ3JvdXAvJ2xpbmtzLnR4dCcKICAgICAgICAgICAgZW50cmllcz1saW5lcyBpZiBncm91cD09J3NpbmctYm94JyBlbHNlIChsaW5rX2xpbmVzKHNvdXJjZS5yZWFkX3RleHQoKSkgaWYgc291cmNlLmV4aXN0cygpIGVsc2UgW10pCiAgICAgICAgICAgIGZvciBsaW5lIGluIGVudHJpZXM6CiAgICAgICAgICAgICAgICBpZiBsaW5lIG5vdCBpbiBtZXJnZWQ6bWVyZ2VkLmFwcGVuZChsaW5lKQogICAgICAgIHRhcmdldHM9WyhPVVRQVVQsJ1xuJy5qb2luKGxpbmVzKSsnXG4nKSwKICAgICAgICAgICAgICAgICAoTk9ERVMvJ3N1YnNjcmlwdGlvbi50eHQnLCdcbicuam9pbihtZXJnZWQpKydcbicpXQogICAgICAgIHByZXZpb3VzPXtwOnAucmVhZF9ieXRlcygpIGlmIHAuZXhpc3RzKCkgZWxzZSBOb25lIGZvciBwLF8gaW4gdGFyZ2V0c30KICAgICAgICB0b3VjaGVkPVtdCiAgICAgICAgdHJ5OgogICAgICAgICAgICBmb3IgcCx0ZXh0IGluIHRhcmdldHM6CiAgICAgICAgICAgICAgICBpZiBwcmV2aW91c1twXSE9dGV4dC5lbmNvZGUoKToKICAgICAgICAgICAgICAgICAgICB0b3VjaGVkLmFwcGVuZChwKTthdG9taWMocCx0ZXh0KQogICAgICAgICAgICAgICAgZWxzZTpvcy5jaG1vZChwLDBvNjAwKQogICAgICAgICAgICBvcy5jaG1vZChPVVRQVVQucGFyZW50LDBvNzAwKQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgICAgIGZvciBwIGluIHJldmVyc2VkKHRvdWNoZWQpOgogICAgICAgICAgICAgICAgaWYgcHJldmlvdXNbcF0gaXMgTm9uZToKICAgICAgICAgICAgICAgICAgICBpZiBwLmV4aXN0cygpOnAudW5saW5rKCkKICAgICAgICAgICAgICAgIGVsc2U6YXRvbWljKHAscHJldmlvdXNbcF0pCiAgICAgICAgICAgIHJhaXNlCgpkZWYgd3JpdGUocCxkYXRhKTphdG9taWMocCxqc29uLmR1bXBzKGRhdGEsZW5zdXJlX2FzY2lpPUZhbHNlKSkKZGVmIGRpZ2VzdChkYXRhKTpyZXR1cm4gaGFzaGxpYi5zaGEyNTYoZGF0YSkuaGV4ZGlnZXN0KCkKZGVmIGNoZWNrZWRfY29uZmlnKCk6CiAgICBkYXRhPUNPTkZJRy5yZWFkX2J5dGVzKCk7Y2ZnPWpzb24ubG9hZHMoZGF0YSkKICAgIGJpbmFyeT1yZWFkKFNUQVRFLydkZXBsb3ltZW50Lmpzb24nKVsnYmluYXJ5J10KICAgIHJ1bihbYmluYXJ5LCdjaGVjaycsJy1jJyxzdHIoQ09ORklHKV0pCiAgICBpZiBDT05GSUcucmVhZF9ieXRlcygpIT1kYXRhOnJhaXNlIFJ1bnRpbWVFcnJvcign6YWN572u5qOA5p+l5pyf6Ze05Y+R55Sf5Y+Y5YyW77yM562J5b6F5LiL5qyh5qOA5p+lJykKICAgIHJldHVybiBkYXRhLGNmZwpkZWYgb3BlbnJjKCk6cmV0dXJuIHBhdGhsaWIuUGF0aCgnL2V0Yy9hbHBpbmUtcmVsZWFzZScpLmV4aXN0cygpCmRlZiBwcm9jZXNzKCk6CiAgICBpZiBvcGVucmMoKToKICAgICAgICBydW4oWydyYy1zZXJ2aWNlJywnc2luZy1ib3gnLCdzdGF0dXMnXSkKICAgICAgICBwaWQ9aW50KHJlYWQoUlVOLydhY3RpdmUuanNvbicpWydwaWQnXSkKICAgIGVsc2U6CiAgICAgICAgaWYgcnVuKFsnc3lzdGVtY3RsJywnaXMtYWN0aXZlJywnc2luZy1ib3guc2VydmljZSddKS5kZWNvZGUoKS5zdHJpcCgpIT0nYWN0aXZlJzpyYWlzZSBSdW50aW1lRXJyb3IoJ3NpbmctYm94IOacqui/kOihjCcpCiAgICAgICAgcGlkPWludChydW4oWydzeXN0ZW1jdGwnLCdzaG93Jywnc2luZy1ib3guc2VydmljZScsJy0tcHJvcGVydHk9TWFpblBJRCcsJy0tdmFsdWUnXSkuZGVjb2RlKCkuc3RyaXAoKSkKICAgIGlmIHBpZDw9MDpyYWlzZSBSdW50aW1lRXJyb3IoJ+aXoOazleehruiupCBzaW5nLWJveCBQSUQnKQogICAgcHJvYz1wYXRobGliLlBhdGgoJy9wcm9jJykvc3RyKHBpZCkKICAgIHRpY2tzPXByb2Muam9pbnBhdGgoJ3N0YXQnKS5yZWFkX3RleHQoKS5yc3BsaXQoJyknLDEpWzFdLnNwbGl0KClbMTldCiAgICBhcmdzPXByb2Muam9pbnBhdGgoJ2NtZGxpbmUnKS5yZWFkX2J5dGVzKCkuc3BsaXQoYidcMCcpCiAgICBpZiBiJy1jJyBub3QgaW4gYXJncyBvciBhcmdzW2FyZ3MuaW5kZXgoYictYycpKzFdIT1zdHIoQ09ORklHKS5lbmNvZGUoKTpyYWlzZSBSdW50aW1lRXJyb3IoJ+i/kOihjOi/m+eoi+mFjee9rui3r+W+hOS4jeWMuemFjScpCiAgICByZXR1cm4gcGlkLHRpY2tzCmRlZiBtYXJrKCk6CiAgICAjIEV4ZWNTdGFydFBvc3QgcnVucyB3aGlsZSB0aGUgdW5pdCBpcyBhY3RpdmF0aW5nLCBzbyBkbyBub3QgcmVxdWlyZSBpcy1hY3RpdmUgaGVyZS4KICAgIHBpZD1pbnQob3MuZW52aXJvbi5nZXQoJ01BSU5QSUQnLCcwJykpCiAgICBpZiBub3QgcGlkOnBpZD1pbnQocnVuKFsnc3lzdGVtY3RsJywnc2hvdycsJ3NpbmctYm94LnNlcnZpY2UnLCctLXByb3BlcnR5PU1haW5QSUQnLCctLXZhbHVlJ10pLmRlY29kZSgpLnN0cmlwKCkpCiAgICB0aWNrcz1wYXRobGliLlBhdGgoJy9wcm9jJyxzdHIocGlkKSwnc3RhdCcpLnJlYWRfdGV4dCgpLnJzcGxpdCgnKScsMSlbMV0uc3BsaXQoKVsxOV0KICAgIGRhdGE9KFJVTi8ncGVuZGluZy5qc29uJykucmVhZF9ieXRlcygpCiAgICBpZiBDT05GSUcucmVhZF9ieXRlcygpIT1kYXRhOnJhaXNlIFJ1bnRpbWVFcnJvcign5ZCv5Yqo5pyf6Ze06YWN572u5Y+R55Sf5Y+Y5YyW77yM6K+36YeN5paw5ZCv5Yqo5qC45b+DJykKICAgIHdyaXRlKFJVTi8nYWN0aXZlLmpzb24nLHsncGlkJzpwaWQsJ3RpY2tzJzp0aWNrcywnc2hhJzpkaWdlc3QoZGF0YSl9KQogICAgYXRvbWljKFJVTi8nbG9hZGVkLmpzb24nLGRhdGEpCmRlZiBjb3VudHJ5KGlwKToKICAgIHRyeTppcD1zdHIoaXBhZGRyZXNzLmlwX2FkZHJlc3MoaXApKQogICAgZXhjZXB0IFZhbHVlRXJyb3I6cmV0dXJuICcnCiAgICBwYXRoPVNUQVRFLygnY291bnRyeS0nK2RpZ2VzdChpcC5lbmNvZGUoKSlbOjE2XSsnLmpzb24nKTtub3c9dGltZS50aW1lKCkKICAgIGNhY2hlPXt9CiAgICB0cnk6Y2FjaGU9cmVhZChwYXRoKQogICAgZXhjZXB0IChPU0Vycm9yLFZhbHVlRXJyb3IpOnBhc3MKICAgIGlmIGNhY2hlLmdldCgnZXhwaXJlcycsMCk+bm93OnJldHVybiBjYWNoZS5nZXQoJ2xhYmVsJywnJykKICAgIHByb3ZpZGVycz1bKCdodHRwczovL2lwd2hvLmlzLycraXAsJ2NvdW50cnlfY29kZScsJ2NvdW50cnknKSwoJ2h0dHBzOi8vaXBhcGkuY28vJytpcCsnL2pzb24vJywnY291bnRyeV9jb2RlJywnY291bnRyeV9uYW1lJyksKCdodHRwczovL2lwaW5mby5pby8nK2lwKycvanNvbicsJ2NvdW50cnknLE5vbmUpXQogICAgZm9yIHVybCxjb2RlX2ZpZWxkLG5hbWVfZmllbGQgaW4gcHJvdmlkZXJzOgogICAgICAgIHRyeToKICAgICAgICAgICAgcmF3PXJ1bihbJ2N1cmwnLCctZkxzUycsJy0tY29ubmVjdC10aW1lb3V0JywnMicsJy0tbWF4LXRpbWUnLCczJyx1cmxdKQogICAgICAgICAgICBvYmo9anNvbi5sb2FkcyhyYXcpO2NvZGU9b2JqLmdldChjb2RlX2ZpZWxkLCcnKS51cHBlcigpCiAgICAgICAgICAgIGlmIG9iai5nZXQoJ3N1Y2Nlc3MnKSBpcyBGYWxzZSBvciBvYmouZ2V0KCdlcnJvcicpIG9yIG5vdCByZS5mdWxsbWF0Y2goJ1tBLVpdezJ9Jyxjb2RlKTpjb250aW51ZQogICAgICAgICAgICBmbGFnPScnLmpvaW4oY2hyKDB4MWYxZTYrb3JkKGMpLTY1KSBmb3IgYyBpbiBjb2RlKQogICAgICAgICAgICBuYW1lPW9iai5nZXQobmFtZV9maWVsZCkgaWYgbmFtZV9maWVsZCBlbHNlIGNvZGUKICAgICAgICAgICAgbGFiZWw9ZmxhZysobmFtZSBpZiBpc2luc3RhbmNlKG5hbWUsc3RyKSBhbmQgbmFtZSBlbHNlIGNvZGUpCiAgICAgICAgICAgIHdyaXRlKHBhdGgseydsYWJlbCc6bGFiZWwsJ2V4cGlyZXMnOm5vdys4NjQwMCwnaXAnOmlwfSk7cmV0dXJuIGxhYmVsCiAgICAgICAgZXhjZXB0IChWYWx1ZUVycm9yLE9TRXJyb3Isc3VicHJvY2Vzcy5TdWJwcm9jZXNzRXJyb3IsQXR0cmlidXRlRXJyb3IpOmNvbnRpbnVlCiAgICAjIEtlZXAgYW4gb2xkIHZhbGlkIGNvdW50cnkgd2hlbiBwcm92aWRlcnMgYXJlIHVuYXZhaWxhYmxlOyByZXRyeSBmYWlsdXJlcyBhZnRlciAxMCBtaW51dGVzLgogICAgbGFiZWw9Y2FjaGUuZ2V0KCdsYWJlbCcsJycpO3dyaXRlKHBhdGgseydsYWJlbCc6bGFiZWwsJ2V4cGlyZXMnOm5vdys2MDAsJ2lwJzppcH0pO3JldHVybiBsYWJlbApkZWYgaXBfZm9yKHRhZyxtZXRhKToKICAgIHByZWZlcnJlZD0naXB2NicgaWYgJ1Y2JyBpbiB0YWcgZWxzZSAnaXB2NCcKICAgIHJldHVybiBtZXRhLmdldChwcmVmZXJyZWQpIG9yIG1ldGEuZ2V0KCdpcHY2JyBpZiBwcmVmZXJyZWQ9PSdpcHY0JyBlbHNlICdpcHY0Jykgb3IgJycKZGVmIG5vZGVfbmFtZShuYW1lLGlwKToKICAgIHN1ZmZpeD1jb3VudHJ5KGlwKQogICAgcmV0dXJuIHVybGxpYi5wYXJzZS5xdW90ZShuYW1lKygnLScrc3VmZml4IGlmIHN1ZmZpeCBlbHNlICcnKSxzYWZlPScnKQpkZWYgcHVibGljX2tleShwcml2YXRlKToKICAgIHJhdz1iYXNlNjQudXJsc2FmZV9iNjRkZWNvZGUocHJpdmF0ZSsnPScqKCg0LWxlbihwcml2YXRlKSU0KSU0KSkKICAgIGlmIGxlbihyYXcpIT0zMjpyYWlzZSBSdW50aW1lRXJyb3IoJ1JlYWxpdHkg56eB6ZKl6ZW/5bqm6ZSZ6K+vJykKICAgIGRlcj1ieXRlcy5mcm9taGV4KCczMDJlMDIwMTAwMzAwNTA2MDMyYjY1NmUwNDIyMDQyMCcpK3JhdwogICAgcHViPXJ1bihbJ29wZW5zc2wnLCdwa2V5JywnLWluZm9ybScsJ0RFUicsJy1wdWJvdXQnLCctb3V0Zm9ybScsJ0RFUiddLGlucHV0PWRlcikKICAgIGlmIGxlbihwdWIpIT00NCBvciBwdWJbOjEyXSE9Ynl0ZXMuZnJvbWhleCgnMzAyYTMwMDUwNjAzMmI2NTZlMDMyMTAwJyk6cmFpc2UgUnVudGltZUVycm9yKCfml6Dms5Xop6PmnpAgUmVhbGl0eSDlhazpkqUnKQogICAgcmV0dXJuIGJhc2U2NC51cmxzYWZlX2I2NGVuY29kZShwdWJbLTMyOl0pLmRlY29kZSgpLnJzdHJpcCgnPScpCmRlZiBsaXN0ZW5zKHBpZCxjZmcpOgogICAgaW5vZGVzPXNldCgpCiAgICBmb3IgZmQgaW4gcGF0aGxpYi5QYXRoKCcvcHJvYycsc3RyKHBpZCksJ2ZkJykuaXRlcmRpcigpOgogICAgICAgIHRyeToKICAgICAgICAgICAgdGFyZ2V0PW9zLnJlYWRsaW5rKGZkKQogICAgICAgICAgICBpZiB0YXJnZXQuc3RhcnRzd2l0aCgnc29ja2V0OlsnKTppbm9kZXMuYWRkKHRhcmdldFs4Oi0xXSkKICAgICAgICBleGNlcHQgT1NFcnJvcjpwYXNzCiAgICBhdmFpbGFibGU9c2V0KCkKICAgIGZvciB0YWJsZSBpbiBbJ3RjcCcsJ3RjcDYnLCd1ZHAnLCd1ZHA2J106CiAgICAgICAgdHJ5OnJvd3M9cGF0aGxpYi5QYXRoKCcvcHJvYycsc3RyKHBpZCksJ25ldCcsdGFibGUpLnJlYWRfdGV4dCgpLnNwbGl0bGluZXMoKVsxOl0KICAgICAgICBleGNlcHQgT1NFcnJvcjpjb250aW51ZQogICAgICAgIGZvciByb3cgaW4gcm93czoKICAgICAgICAgICAgZmllbGRzPXJvdy5zcGxpdCgpCiAgICAgICAgICAgIGlmIGxlbihmaWVsZHMpPDEwIG9yIGZpZWxkc1s5XSBub3QgaW4gaW5vZGVzOmNvbnRpbnVlCiAgICAgICAgICAgIGlmIHRhYmxlLnN0YXJ0c3dpdGgoJ3RjcCcpIGFuZCBmaWVsZHNbM10hPScwQSc6Y29udGludWUKICAgICAgICAgICAgYXZhaWxhYmxlLmFkZCgoJ3RjcCcgaWYgdGFibGUuc3RhcnRzd2l0aCgndGNwJykgZWxzZSAndWRwJyxpbnQoZmllbGRzWzFdLnNwbGl0KCc6JylbLTFdLDE2KSkpCiAgICBmb3IgaW5ib3VuZCBpbiBjZmcuZ2V0KCdpbmJvdW5kcycsW10pOgogICAgICAgIGtpbmQ9aW5ib3VuZC5nZXQoJ3R5cGUnKQogICAgICAgIGlmIGtpbmQgbm90IGluIFsndmxlc3MnLCdoeXN0ZXJpYTInXTpyYWlzZSBSdW50aW1lRXJyb3IoJ+WHuueOsOmdnuWOn+iEmuacrOaUr+aMgeeahOWFpeerme+8jOacquimhuebluiKgueCueaWh+S7ticpCiAgICAgICAgcHJvdG9jb2w9J3VkcCcgaWYga2luZD09J2h5c3RlcmlhMicgZWxzZSAndGNwJwogICAgICAgIHBvcnQ9aW5ib3VuZC5nZXQoJ2xpc3Rlbl9wb3J0JykKICAgICAgICBpZiBub3QgaXNpbnN0YW5jZShwb3J0LGludCkgb3Igbm90IDE8PXBvcnQ8PTY1NTM1IG9yIChwcm90b2NvbCxwb3J0KSBub3QgaW4gYXZhaWxhYmxlOnJhaXNlIFJ1bnRpbWVFcnJvcign5YWl56uZ56uv5Y+j5bCa5pyq55Sx5b2T5YmN5qC45b+D55uR5ZCsJykKZGVmIGdlbmVyYXRlKGNmZyxtZXRhKToKICAgIGltcG9ydCBydW5weQogICAgcmV0dXJuIHJ1bnB5LnJ1bl9wYXRoKCcvdXNyL2xvY2FsL2xpYi9hcmdvLXN0YW5kYWxvbmUvbWFuYWdlci5weScscnVuX25hbWU9J2FyZ29fZ2VuZXJhdG9yJylbJ2dlbmVyYXRlX2xpbmtzJ10oY2ZnLG1ldGEpCgpkZWYgc3luYygpOgogICAgcGlkLHRpY2tzPXByb2Nlc3MoKTthY3RpdmU9cmVhZChSVU4vJ2FjdGl2ZS5qc29uJykKICAgIGRhdGEsY2ZnPWNoZWNrZWRfY29uZmlnKCkKICAgIGlmIGFjdGl2ZSE9eydwaWQnOnBpZCwndGlja3MnOnRpY2tzLCdzaGEnOmRpZ2VzdChkYXRhKX0gb3IgKFJVTi8nbG9hZGVkLmpzb24nKS5yZWFkX2J5dGVzKCkhPWRhdGE6cmFpc2UgUnVudGltZUVycm9yKCfno4Hnm5jphY3nva7mnKrnoa7orqTlt7LliqDovb3vvIzor7fmo4Dmn6XphY3nva7lkI7ph43lkK8gc2luZy1ib3gnKQogICAgbGlzdGVucyhwaWQsY2ZnKQogICAgY29udGVudD1nZW5lcmF0ZShjZmcscmVhZChTVEFURS8nZGVwbG95bWVudC5qc29uJykpCiAgICAjIFNsb3cgZ2VvbG9jYXRpb24gbXVzdCBub3QgYWxsb3cgYSBzZXJ2aWNlIHJlc3RhcnQgb3IgY29uZmlnIGVkaXQgdG8gcmFjZSB0aGUgd3JpdGUuCiAgICBpZiBwcm9jZXNzKCkhPShwaWQsdGlja3MpIG9yIENPTkZJRy5yZWFkX2J5dGVzKCkhPWRhdGEgb3IgcmVhZChSVU4vJ2FjdGl2ZS5qc29uJykhPWFjdGl2ZTpyYWlzZSBSdW50aW1lRXJyb3IoJ+eUn+aIkOacn+mXtOmFjee9ruaIlui/m+eoi+aUueWPmO+8jOS/neeVmeaXp+aWh+S7ticpCiAgICBwdWJsaXNoX25vZGVzKGNvbnRlbnQpCgpkZWYgbWFpbigpOgogICAgU1RBVEUubWtkaXIocGFyZW50cz1UcnVlLGV4aXN0X29rPVRydWUpO1JVTi5ta2RpcihwYXJlbnRzPVRydWUsZXhpc3Rfb2s9VHJ1ZSkKICAgIG9zLmNobW9kKFNUQVRFLDBvNzAwKTtvcy5jaG1vZChSVU4sMG83MDApCiAgICB3aXRoIG9wZW4oUlVOLydsb2NrJywnYScpIGFzIGxvY2s6CiAgICAgICAgZmNudGwuZmxvY2sobG9jayxmY250bC5MT0NLX0VYKQogICAgICAgIG1vZGU9c3lzLmFyZ3ZbMV0gaWYgbGVuKHN5cy5hcmd2KT4xIGVsc2UgJy0tb25jZScKICAgICAgICBpZiBtb2RlPT0nLS1sYXVuY2gnOgogICAgICAgICAgICBkYXRhLGNmZz1jaGVja2VkX2NvbmZpZygpO2F0b21pYyhSVU4vJ3BlbmRpbmcuanNvbicsZGF0YSkKICAgICAgICAgICAgb3MuZW52aXJvblsnTUFJTlBJRCddPXN0cihvcy5nZXRwaWQoKSk7bWFyaygpCiAgICAgICAgICAgIGJpbmFyeT1yZWFkKFNUQVRFLydkZXBsb3ltZW50Lmpzb24nKVsnYmluYXJ5J10KICAgICAgICAgICAgIyBSZWxlYXNlIHRoZSBzeW5jIGxvY2sgYmVmb3JlIHJlcGxhY2luZyB0aGlzIHByb2Nlc3Mgd2l0aCB0aGUgY29yZS4KICAgICAgICAgICAgZmNudGwuZmxvY2sobG9jayxmY250bC5MT0NLX1VOKTtsb2NrLmNsb3NlKCkKICAgICAgICAgICAgb3MuZXhlY3YoYmluYXJ5LFtiaW5hcnksJ3J1bicsJy1jJyxzdHIoQ09ORklHKV0pCiAgICAgICAgZWxpZiBtb2RlPT0nLS1jYXB0dXJlJzpkYXRhLGNmZz1jaGVja2VkX2NvbmZpZygpO2F0b21pYyhSVU4vJ3BlbmRpbmcuanNvbicsZGF0YSkKICAgICAgICBlbGlmIG1vZGU9PSctLW1hcmsnOm1hcmsoKQogICAgICAgIGVsaWYgbW9kZT09Jy0tbGFiZWwnOnByaW50KG5vZGVfbmFtZShzeXMuYXJndlsyXSxzeXMuYXJndlszXSkpCiAgICAgICAgZWxpZiBtb2RlPT0nLS1vbmNlJzpzeW5jKCkKICAgICAgICBlbHNlOnJhaXNlIFJ1bnRpbWVFcnJvcign5pyq55+l6L+Q6KGM5Y+C5pWwJykKaWYgX19uYW1lX189PSdfX21haW5fXyc6CiAgICB0cnk6CiAgICAgICAgaWYgbGVuKHN5cy5hcmd2KT4xIGFuZCBzeXMuYXJndlsxXT09Jy0td2F0Y2gnOgogICAgICAgICAgICBzeXMuYXJndlsxXT0nLS1vbmNlJwogICAgICAgICAgICB3aGlsZSBUcnVlOgogICAgICAgICAgICAgICAgdHJ5Om1haW4oKQogICAgICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgICAgICAgICAgICAgIHByaW50KHRpbWUuc3RyZnRpbWUoJyVZLSVtLSVkVCVIOiVNOiVTWicsdGltZS5nbXRpbWUoKSkrJyDlkIzmraXmnKrlrozmiJDvvIzkv53nlZnml6fmlofku7bvvJonKyhzdHIoZSkgaWYgaXNpbnN0YW5jZShlLFJ1bnRpbWVFcnJvcikgZWxzZSB0eXBlKGUpLl9fbmFtZV9fKSxmaWxlPXN5cy5zdGRlcnIsZmx1c2g9VHJ1ZSkKICAgICAgICAgICAgICAgIHRpbWUuc2xlZXAoNjApCiAgICAgICAgZWxzZTptYWluKCkKICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICAjIERvIG5vdCBwcmludCBKU09OLCBwYXNzd29yZHMsIHByaXZhdGUga2V5cywgb3IgY29tcGxldGUgVVJJcyB0byBzZXJ2aWNlIGxvZ3MuCiAgICAgICAgcHJpbnQodGltZS5zdHJmdGltZSgnJVktJW0tJWRUJUg6JU06JVNaJyx0aW1lLmdtdGltZSgpKSsnIOWQjOatpeWksei0pe+8iOS/neeVmeaXp+aWh+S7tu+8ie+8micrdHlwZShlKS5fX25hbWVfXysnICcrKHN0cihlKSBpZiBpc2luc3RhbmNlKGUsUnVudGltZUVycm9yKSBlbHNlICfor7fmo4Dmn6XphY3nva7jgIHkvp3otZblj4rmnYPpmZAnKSxmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgc3lzLmV4aXQoMSkK'
def verify_service_config():
    if active():
        if alpine():
            pidpaths=[RUN/'active.json',pathlib.Path('/run/sing-box.pid')]
            pid=0
            for path in pidpaths:
                try:
                    candidate=int(read(path)['pid']) if path.suffix=='.json' else int(path.read_text().strip())
                    args=pathlib.Path('/proc',str(candidate),'cmdline').read_bytes().split(b'\0')
                    if b'-c' in args and args[args.index(b'-c')+1]==str(CONFIG).encode():pid=candidate;break
                except Exception:continue
            if not pid:raise Error('不能确认运行服务使用此配置文件，未修改服务。')
        else:
            pid=int(call(['systemctl','show','sing-box.service','--property=MainPID','--value']).strip())
            args=pathlib.Path('/proc',str(pid),'cmdline').read_bytes().split(b'\0')
            if b'-c' not in args or args[args.index(b'-c')+1]!=str(CONFIG).encode():raise Error('sing-box 服务使用其它配置路径，未修改。')
    else:
        if alpine():
            script=pathlib.Path('/etc/init.d/sing-box').read_text()
            if str(CONFIG) not in script and '--launch' not in script:raise Error('服务配置路径不匹配。')
        elif str(CONFIG) not in call(['systemctl','show','sing-box.service','--property=ExecStart','--value']).decode():raise Error('服务配置路径不匹配。')

PUBLICATION_SOURCE='IyBVbmlmaWVkIFRYVCBwdWJsaWNhdGlvbiBvbmx5OyBjb3JlIGNvbmZpZ3VyYXRpb24gYW5kIHJlYWRpbmVzcyBjaGVja3Mgc3RheSB1bmNoYW5nZWQuCk5PREVTPXBhdGhsaWIuUGF0aCgnL2V0Yy9ub2RlcycpClBVQkxJU0hfUlVOPXBhdGhsaWIuUGF0aCgnL3J1bi9ub2Rlcy1wdWJsaWNhdGlvbicpCmRlZiBsaW5rX2xpbmVzKGNvbnRlbnQpOgogICAgcmVzdWx0PVtdCiAgICBmb3IgbGluZSBpbiBjb250ZW50LnNwbGl0bGluZXMoKToKICAgICAgICBsaW5lPWxpbmUuc3RyaXAoKQogICAgICAgIGlmIG5vdCBsaW5lIG9yIGxpbmUuc3RhcnRzd2l0aCgnIycpOmNvbnRpbnVlCiAgICAgICAgaWYgbm90IHJlLm1hdGNoKHInXlthLXpBLVpdW2EtekEtWjAtOSsuLV0qOi8vXFMrJCcsbGluZSk6CiAgICAgICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcign6IqC54K56ZO+5o6l5paH5Lu25ZCr5peg5pWI6KGM77yM5L+d55WZ5pen5paH5Lu2JykKICAgICAgICBpZiBsaW5lIG5vdCBpbiByZXN1bHQ6cmVzdWx0LmFwcGVuZChsaW5lKQogICAgcmV0dXJuIHJlc3VsdApkZWYgcHVibGlzaF9ub2Rlcyhjb250ZW50KToKICAgIGxpbmVzPWxpbmtfbGluZXMoY29udGVudCkKICAgIGlmIG5vdCBsaW5lczpyYWlzZSBSdW50aW1lRXJyb3IoJ+acqueUn+aIkOacieaViOiKgueCue+8jOS/neeVmeaXp+aWh+S7ticpCiAgICBQVUJMSVNIX1JVTi5ta2RpcihwYXJlbnRzPVRydWUsZXhpc3Rfb2s9VHJ1ZSk7b3MuY2htb2QoUFVCTElTSF9SVU4sMG83MDApCiAgICBOT0RFUy5ta2RpcihwYXJlbnRzPVRydWUsZXhpc3Rfb2s9VHJ1ZSk7b3MuY2htb2QoTk9ERVMsMG83MDApCiAgICB3aXRoIG9wZW4oUFVCTElTSF9SVU4vJ2xvY2snLCdhJykgYXMgcHVibGljYXRpb25fbG9jazoKICAgICAgICBvcy5jaG1vZChQVUJMSVNIX1JVTi8nbG9jaycsMG82MDApCiAgICAgICAgZmNudGwuZmxvY2socHVibGljYXRpb25fbG9jayxmY250bC5MT0NLX0VYKQogICAgICAgIG1lcmdlZD1bXQogICAgICAgIGZvciBncm91cCBpbiAoJ2FyZ28nLCdzaW5nLWJveCcsJ3hyYXknKToKICAgICAgICAgICAgc291cmNlPU5PREVTL2dyb3VwLydsaW5rcy50eHQnCiAgICAgICAgICAgIGVudHJpZXM9bGluZXMgaWYgZ3JvdXA9PSdzaW5nLWJveCcgZWxzZSAobGlua19saW5lcyhzb3VyY2UucmVhZF90ZXh0KCkpIGlmIHNvdXJjZS5leGlzdHMoKSBlbHNlIFtdKQogICAgICAgICAgICBmb3IgbGluZSBpbiBlbnRyaWVzOgogICAgICAgICAgICAgICAgaWYgbGluZSBub3QgaW4gbWVyZ2VkOm1lcmdlZC5hcHBlbmQobGluZSkKICAgICAgICB0YXJnZXRzPVsoT1VUUFVULCdcbicuam9pbihsaW5lcykrJ1xuJyksCiAgICAgICAgICAgICAgICAgKE5PREVTLydzdWJzY3JpcHRpb24udHh0JywnXG4nLmpvaW4obWVyZ2VkKSsnXG4nKV0KICAgICAgICBwcmV2aW91cz17cDpwLnJlYWRfYnl0ZXMoKSBpZiBwLmV4aXN0cygpIGVsc2UgTm9uZSBmb3IgcCxfIGluIHRhcmdldHN9CiAgICAgICAgdG91Y2hlZD1bXQogICAgICAgIHRyeToKICAgICAgICAgICAgZm9yIHAsdGV4dCBpbiB0YXJnZXRzOgogICAgICAgICAgICAgICAgaWYgcHJldmlvdXNbcF0hPXRleHQuZW5jb2RlKCk6CiAgICAgICAgICAgICAgICAgICAgdG91Y2hlZC5hcHBlbmQocCk7YXRvbWljKHAsdGV4dCkKICAgICAgICAgICAgICAgIGVsc2U6b3MuY2htb2QocCwwbzYwMCkKICAgICAgICAgICAgb3MuY2htb2QoT1VUUFVULnBhcmVudCwwbzcwMCkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICBmb3IgcCBpbiByZXZlcnNlZCh0b3VjaGVkKToKICAgICAgICAgICAgICAgIGlmIHByZXZpb3VzW3BdIGlzIE5vbmU6CiAgICAgICAgICAgICAgICAgICAgaWYgcC5leGlzdHMoKTpwLnVubGluaygpCiAgICAgICAgICAgICAgICBlbHNlOmF0b21pYyhwLHByZXZpb3VzW3BdKQogICAgICAgICAgICByYWlzZQoK'
def upgrade_sync_source(source):
    source=source.replace("OUTPUT=pathlib.Path('/root/singbox_nodes.txt')","OUTPUT=pathlib.Path('/etc/nodes/sing-box/links.txt')")
    source=source.replace("SECONDARY=pathlib.Path('/etc/sing-box/v2rayn_links.txt')\n",'')
    if 'def publish_nodes(content):' not in source:
        anchor='def write(p,data):atomic(p,json.dumps(data,ensure_ascii=False))'
        if anchor not in source:raise Error('未知同步程序，未修改。')
        source=source.replace(anchor,base64.b64decode(PUBLICATION_SOURCE).decode()+anchor,1)
        start=source.index('    if not OUTPUT.exists() or OUTPUT.read_text()!=content:',source.index('def sync():'))
        end=source.index('\ndef main():',start)
        source=source[:start]+'    publish_nodes(content)\n'+source[end:]
    return source

@locked
def initialize_sync():
    cfg=config();core=binary();verify_service_config();LIB.mkdir(parents=True,exist_ok=True);os.chmod(LIB,0o700)
    atomic(SYNC,base64.b64decode(SYNC_SOURCE),0o700)
    if not META.exists():
        ips={}
        for family in ('4','6'):
            for url in ('https://api64.ipify.org','https://ifconfig.co/ip'):
                try:
                    address=call(['curl','-'+family,'-fLsS','--max-time','4',url],timeout=6).decode().strip();ips['ipv'+family]=str(ipaddress.ip_address(address));break
                except Exception:pass
        if not ips:raise Error('无法检测公网 IP，不能生成节点链接。')
        META.parent.mkdir(parents=True,exist_ok=True);os.chmod(META.parent,0o700);write(META,dict(ips,binary=core,mode='2',domain=''))
    patched=False;alpine_worker_changed=False
    for path in (pathlib.Path('/usr/local/lib/singbox-node-sync/run'),pathlib.Path('/usr/local/lib/alpine-node-sync/run')):
        if not path.exists():continue
        original_source=path.read_text()
        source=upgrade_sync_source(original_source)
        if 'def generate(cfg,meta):' not in source or "'/run/singbox-node-sync'" not in source:raise Error('检测到未知节点同步程序，未改动它。')
        if '# ARGO_CERT_GENERATOR' not in source:
            backup=path.with_name(path.name+'.before-cert-manager')
            if not backup.exists():atomic(backup,original_source,0o700)
            prefix="def generate(cfg,meta):\n    # ARGO_CERT_GENERATOR\n    import runpy\n    return runpy.run_path('/usr/local/lib/argo-standalone/manager.py',run_name='argo_generator')['generate_links'](cfg,meta)\n"
            source=source.replace('def generate(cfg,meta):\n',prefix,1)
        if source!=original_source:
            atomic(path,source,0o700)
            if str(path)=='/usr/local/lib/alpine-node-sync/run':alpine_worker_changed=True
        patched=True
    current_meta=read(META)
    if current_meta.get('binary')!=core:current_meta['binary']=core;write(META,current_meta)
    if alpine_worker_changed and pathlib.Path('/etc/init.d/alpine-node-sync').exists():
        status=subprocess.run(['rc-service','alpine-node-sync','status'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        if status.returncode==0:call(['rc-service','alpine-node-sync','restart'])
    if patched:return
    if alpine() and RC_CORE.exists() and RC_SYNC.exists() and str(SYNC) in RC_CORE.read_text():return
    # Original installers without a sync worker: add startup snapshots and a timer.
    if alpine():configure_openrc_sync()
    else:
        atomic('/etc/systemd/system/sing-box.service.d/argo-node-sync.conf',f'[Service]\nExecStartPre={SYNC} --capture\nExecStartPost={SYNC} --mark\n')
        atomic('/etc/systemd/system/argo-sb-sync.service',f'[Unit]\nAfter=sing-box.service\n[Service]\nType=oneshot\nExecStart={SYNC} --once\nUMask=0077\nTimeoutStartSec=180\n')
        atomic('/etc/systemd/system/argo-sb-sync.timer','[Timer]\nOnBootSec=45s\nOnUnitActiveSec=60s\n[Install]\nWantedBy=timers.target\n')
        call(['systemctl','daemon-reload']);call(['systemctl','enable','--now','argo-sb-sync.timer'])
@locked
def configure_openrc_sync():
    old=RC_CORE.read_bytes() if RC_CORE.exists() else None
    oldsync=RC_SYNC.read_bytes() if RC_SYNC.exists() else None
    backup=RC_CORE.with_name('sing-box.before-argo-cert-manager')
    if old is not None and not backup.exists():atomic(backup,old,0o755)
    was=active()
    # Stop with the original service file and PID format, before switching supervisor.
    if was:service('stop')
    try:
        atomic(RC_CORE,textwrap.dedent(f'''\
        #!/sbin/openrc-run
        name="sing-box"
        supervisor="supervise-daemon"
        command="{SYNC}"
        command_args="--launch"
        pidfile="/run/sing-box.supervisor.pid"
        respawn_delay=2
        respawn_max=0
        respawn_period=60
        output_log="/var/log/sing-box/argo-core.log"
        error_log="/var/log/sing-box/argo-core.log"
        depend() {{ need net; }}
        '''),0o755)
        atomic(RC_SYNC,textwrap.dedent(f'''\
        #!/sbin/openrc-run
        name="argo sing-box link sync"
        supervisor="supervise-daemon"
        command="{SYNC}"
        command_args="--watch"
        pidfile="/run/argo-sb-sync.pid"
        respawn_delay=5
        respawn_max=0
        respawn_period=60
        output_log="/var/log/sing-box/node-sync.log"
        error_log="/var/log/sing-box/node-sync.log"
        depend() {{ need net; after sing-box; }}
        '''),0o755)
        call(['rc-update','add','sing-box','default'])
        if was:service('start');time.sleep(2)
        call(['rc-update','add','argo-sb-sync','default']);call(['rc-service','argo-sb-sync','restart'])
    except Exception:
        try:call(['rc-service','argo-sb-sync','stop'])
        except Exception:pass
        try:service('stop')
        except Exception:pass
        if old is None:
            if RC_CORE.exists():RC_CORE.unlink()
        else:atomic(RC_CORE,old,0o755)
        if oldsync is None:
            try:call(['rc-update','del','argo-sb-sync','default'])
            except Exception:pass
            if RC_SYNC.exists():RC_SYNC.unlink()
        else:atomic(RC_SYNC,oldsync,0o755)
        if was:
            try:service('start')
            except Exception:say('⚠ 原服务文件已恢复，但服务启动失败。','warn')
        raise Error('OpenRC 接入未完成，原服务文件已恢复。')

def sync_now(strict=True):
    deadline=time.monotonic()+(45 if strict else 0)
    while True:
        try:call([SYNC,'--once'],timeout=180);return
        except Exception:
            if not strict:
                say('⚠ 自检未通过，下面显示上次保存的信息。','warn');return
            if time.monotonic()>=deadline:raise Error('节点链接验证失败，未发布新的节点。')
            time.sleep(2)
def check_config_bytes(data):
    with tempfile.TemporaryDirectory(dir=CONFIG.parent) as tmp:
        candidate=pathlib.Path(tmp)/'config.json';atomic(candidate,data)
        call([binary(),'check','-c',candidate])
@locked
def commit_config(new,old):
    data=(json.dumps(new,ensure_ascii=False,indent=2)+'\n').encode();check_config_bytes(data)
    for i in new.get('inbounds',[]):
        tls=i.get('tls',{})
        if tls.get('enabled') and not tls.get('reality',{}).get('enabled'):
            check_certificate(tls['certificate_path'],tls['key_path'],tls['server_name'],trust=cert_kind(tls['certificate_path'])=='formal')
    if CONFIG.is_symlink():raise Error('配置是符号链接，未覆盖。')
    if CONFIG.read_bytes()!=old:raise Error('配置被其他程序修改，请重新进入。')
    links={path:path.read_bytes() if path.exists() else None for path in LINKFILES}
    was=active();backup=ROOT/'backups'/('config-'+str(time.time_ns())+'.json');atomic(backup,old)
    try:
        atomic(CONFIG,data);service('restart');time.sleep(2);sync_now()
    except BaseException as failure:
        atomic(CONFIG,old)
        try:service('restart' if was else 'stop')
        except Exception:say('⚠ 旧配置已恢复，但服务恢复失败，请查看日志。','warn')
        sync_now(False) if was else None
        for path,content in links.items():
            if content is None:call(['/usr/local/lib/argo-node-files/run','--remove','sing-box'])
            else:call(['/usr/local/lib/argo-node-files/run','--publish','sing-box'],input=content)
        if isinstance(failure,KeyboardInterrupt):raise failure
        raise Error('修改未完成，已恢复旧配置和旧节点参数。')
    say('✓ 配置已生效，节点信息已更新。','ok')

# ---------- Certificate clients ----------
def fetch(url,out):call(['curl','-fLsS','--retry','2','--connect-timeout','10','--max-time','180',url,'-o',out],timeout=400)
def install_acme():
    path=LIB/'acme/acme.sh';path.parent.mkdir(parents=True,exist_ok=True);os.chmod(path.parent,0o700)
    plugin=path.parent/'dnsapi/dns_cf.sh';plugin.parent.mkdir(exist_ok=True)
    for dest,url in [(path,'https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh'),(plugin,'https://raw.githubusercontent.com/acmesh-official/acme.sh/master/dnsapi/dns_cf.sh')]:
        if dest.exists():continue
        with tempfile.TemporaryDirectory(dir=path.parent) as tmp:
            stage=pathlib.Path(tmp)/dest.name;fetch(url,stage);call(['sh','-n',stage]);atomic(dest,stage.read_bytes(),0o700)
    return path

def install_lego():
    path=LIB/'lego'
    if path.exists():call([path,'--version']);return path
    arch={'x86_64':'amd64','aarch64':'arm64','arm64':'arm64'}.get(os.uname().machine)
    if not arch:raise Error('备用程序仅支持 AMD64 / ARM64。')
    with tempfile.TemporaryDirectory() as tmp:
        tmp=pathlib.Path(tmp);fetch('https://api.github.com/repos/go-acme/lego/releases/latest',tmp/'release.json');info=read(tmp/'release.json')
        asset=next((a for a in info['assets'] if a['name'].endswith('linux_'+arch+'.tar.gz')),None)
        if not asset:raise Error('未找到 lego 对应架构。')
        fetch(asset['browser_download_url'],tmp/'lego.tgz');expected=asset.get('digest','')
        if not expected.startswith('sha256:'):
            checksum=next((a for a in info['assets'] if 'checksums' in a['name'].lower()),None)
            if not checksum:raise Error('没有 lego 下载校验信息。')
            fetch(checksum['browser_download_url'],tmp/'checksums')
            expected=next(('sha256:'+line.split()[0] for line in (tmp/'checksums').read_text().splitlines() if line.split()[-1].lstrip('*')==asset['name']),'')
        if expected!='sha256:'+hashlib.sha256((tmp/'lego.tgz').read_bytes()).hexdigest():raise Error('lego 下载校验失败。')
        with tarfile.open(tmp/'lego.tgz') as tar:
            member=next((m for m in tar.getmembers() if pathlib.PurePosixPath(m.name).name=='lego' and m.isfile()),None)
            if not member:raise Error('lego 压缩包中没有程序。')
            atomic(path,tar.extractfile(member).read(),0o700)
    call([path,'--version']);return path

def cf_credentials(host):
    saved=read(ROOT/'dns-auth.json') if (ROOT/'dns-auth.json').exists() else {}
    source=pathlib.Path('/etc/vps-cf-api/auth.json')
    if source.exists() and confirm('复用已接入的 Cloudflare API 凭据？'):
        saved=read(source)
    else:
        token=prompt('Cloudflare API Token（DNS 编辑、Zone 读取；留空保留已存凭据）',secret=True)
        if token:saved={'token':token,'account_id':prompt('Account ID（可留空）'),'zone_id':prompt('Zone ID（可留空）')}
    if not saved.get('token'):raise Error('未提供 DNS API Token。')
    def cf_get(path):
        request=urllib.request.Request('https://api.cloudflare.com/client/v4'+path,headers={'Authorization':'Bearer '+saved['token']})
        with urllib.request.urlopen(request,timeout=20) as response:result=json.load(response)
        if not result.get('success'):raise Error('Cloudflare API 读取验证失败。')
        return result['result']
    zone=None;labels=host.removeprefix('*.').split('.')
    for offset in range(len(labels)-1):
        name='.'.join(labels[offset:])
        try:
            rows=cf_get('/zones?name='+urllib.parse.quote(name)+'&per_page=50')
            if rows:zone=rows[0];break
        except Exception:continue
    if not zone:raise Error('无法读取该域名的 Cloudflare 区域，请检查 Token 的 Zone 读取权限和域名范围；未覆盖旧凭据。')
    saved.update(zone_id=zone['id'],account_id=zone['account']['id'],zone_name=zone['name'])
    write(ROOT/'dns-auth.json',saved)
    say('✓ 域名区域读取通过；DNS 编辑权限将在签发时检查。','ok')
    return saved

def cert_environment(row):
    env=os.environ.copy()
    for name in ('CF_Key','CF_Email','CF_Token','CF_Account_ID','CF_Zone_ID','CF_DNS_API_TOKEN','CF_ZONE_API_TOKEN','CLOUDFLARE_API_KEY','CLOUDFLARE_API_EMAIL','CLOUDFLARE_DNS_API_TOKEN','CLOUDFLARE_ZONE_API_TOKEN'):env.pop(name,None)
    if row['method']=='dns':
        auth=read(row.get('auth_file',ROOT/'dns-auth.json'));token=auth['token']
        env.update(CF_Token=token,CF_DNS_API_TOKEN=token,CF_ZONE_API_TOKEN=token)
        if auth.get('account_id'):env['CF_Account_ID']=auth['account_id']
        if auth.get('zone_id'):env['CF_Zone_ID']=auth['zone_id']
    return env

def http_check(row):
    if row['method']!='http':return
    if row['domain'].startswith('*.'):raise Error('通配符证书必须使用 DNS 验证。')
    try:
        for ip in {a[4][0] for a in socket.getaddrinfo(row['domain'],80,type=socket.SOCK_STREAM)}:ipaddress.ip_address(ip)
    except Exception:raise Error('域名无法解析，请先设置 A / AAAA 记录。')
    for family,host in [(socket.AF_INET,'0.0.0.0'),(socket.AF_INET6,'::')]:
        with socket.socket(family,socket.SOCK_STREAM) as s:
            if family==socket.AF_INET6:
                try:s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1)
                except OSError:continue
            try:s.bind((host,80))
            except OSError as e:
                if e.errno in (97,99):continue
                raise Error('80 端口被占用或无法绑定；请选择 DNS 验证。')

def lego_command(exe,home,row,renew=False):
    version=call([exe,'--version']).decode()
    match=re.search(r'(?:version\s*:?\s*|^v?)(\d+)\.',version,re.I|re.M)
    if not match:raise Error('无法识别 lego 版本，未发起证书申请。')
    major=int(match.group(1))
    if major not in (4,5):raise Error('尚未适配此 lego 主版本，未发起申请。')
    common=['--path',str(home),'--email',row['email'],'--accept-tos','--domains',row['domain']]
    if row['method'] in ('dns','dns-manual'):common+=['--dns','manual' if row['method']=='dns-manual' else 'cloudflare']
    else:common+=['--http','--http.address' if major==5 else '--http.port',':80']
    if major==5:
        helptext=call([exe,'run','--help']).decode()
        required=['--path','--email','--domains','--accept-tos','--dns' if row['method'] in ('dns','dns-manual') else '--http']
        if not all(flag in helptext for flag in required):raise Error('lego run 参数不匹配，未发起申请。')
        # Legacy data can only be migrated by lego itself; preserve a private backup first.
        if any((home/'accounts').glob('*/*/keys')):
            backup=home.with_name(home.name+'-before-v5-'+str(time.time_ns()))
            shutil.copytree(home,backup);os.chmod(backup,0o700)
            call([exe,'migrate','--path',str(home)],timeout=120)
        return [str(exe),'run']+common+(['--renew-force','--no-random-sleep'] if renew and row['method']=='dns-manual' else ['--renew-days','30'] if renew else [])
    return [str(exe)]+common+(['renew','--days','3650' if row['method']=='dns-manual' else '30'] if renew else ['run'])

@locked
def client_issue(row,renew=False):
    home=pathlib.Path(row['client_home']) if row.get('client_home') else ROOT/'clients'/row['id']/row['client'];home.mkdir(parents=True,exist_ok=True);os.chmod(home,0o700)
    export=home/'export';export.mkdir(exist_ok=True);env=cert_environment(row);log=ROOT/'logs'/(row['id']+'.log')
    http_check(row);say('正在'+('续签' if renew else '申请')+'：'+row['domain']+' / '+row['client']) if sys.stdin.isatty() else None
    if row['client']=='acme.sh':
        exe=install_acme();base=['sh',exe,'--home',exe.parent,'--config-home',home,'--server','letsencrypt']
        if row['method']=='dns-manual':
            if not sys.stdin.isatty():raise Error('手动 DNS-01 需要交互终端。')
            flag='--yes-I-know-dns-manual-mode-enough-go-ahead-please'
            phase=['--renew','-d',row['domain'],'--ecc','--force',flag] if renew else ['--issue','-d',row['domain'],'--dns','--keylength','ec-256','--accountemail',row['email'],flag]
            result=managed_run([str(a) for a in base+phase],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=900)
            output=result.stdout.decode(errors='replace')
            print(output,flush=True)
            challenge='_acme-challenge' in output and 'TXT' in output
            if challenge:
                say('请添加上方列出的 TXT 名称和值；等待 DNS 生效后继续。','warn')
                if not confirm('TXT 已添加并生效，继续验证？'):raise Cancel()
                call(base+['--renew','-d',row['domain'],'--ecc',flag]+(['--force'] if renew else []),timeout=900,env=env,log=log)
            elif result.returncode:
                raise Error('未生成可用 TXT 挑战；请检查上方 acme.sh 错误。')
            call(base+['--install-cert','-d',row['domain'],'--ecc','--fullchain-file',export/'fullchain.pem','--key-file',export/'privkey.pem','--reloadcmd','true'],timeout=60,env=env,log=log)
            return export/'fullchain.pem',export/'privkey.pem'
        if renew:
            call(base+['--renew','-d',row['domain'],'--ecc'],timeout=900,env=env,log=log,allowed=(0,2))
        else:
            args=['--issue','-d',row['domain'],'--keylength','ec-256','--accountemail',row['email']]
            args+=['--dns','dns_cf'] if row['method']=='dns' else ['--standalone']
            call(base+args,timeout=900,env=env,log=log,allowed=(0,2))
        call(base+['--install-cert','-d',row['domain'],'--ecc','--fullchain-file',export/'fullchain.pem','--key-file',export/'privkey.pem','--reloadcmd','true'],timeout=60,env=env,log=log)
        return export/'fullchain.pem',export/'privkey.pem'
    if row['method']=='dns-manual':
        if row['client']!='lego':raise Error('手动 DNS-01 当前使用 lego。')
        if not sys.stdin.isatty():raise Error('手动 DNS-01 需要交互终端，不能后台自动续签。')
        exe=install_lego()
        say('请按下方提示在 DNS 控制台添加 TXT 记录。','warn')
        say('主机记录通常为 _acme-challenge；完整名称和值以 lego 显示为准。','dim')
        say('等待 DNS 生效后再按回车；验证成功前保留 TXT，Ctrl+C 可取消。','dim')
        args=lego_command(exe,home,row,renew)
        result=managed_run(args,env=env)
        if result.returncode:raise Error('lego 申请未完成，旧证书与节点配置保持不变；请根据上方错误检查程序参数、网络或 TXT 后重试。')
        filename=row['domain'].replace('*','_')
        return home/'certificates'/(filename+'.crt'),home/'certificates'/(filename+'.key')
    exe=install_lego();args=lego_command(exe,home,row,renew)
    call(args,timeout=900,env=env,log=log)
    filename=row['domain'].replace('*','_');return home/'certificates'/(filename+'.crt'),home/'certificates'/(filename+'.key')

def row_paths(row):
    directory=ROOT/'certs'/row['id'];return directory,directory/'current'
def switch_current(current,target):
    temp=current.with_name('.current-'+secrets.token_hex(4));os.symlink(str(target),temp);os.replace(temp,current)
@locked
def publish_certificate(row,cert,key):
    check_certificate(cert,key,row['domain'],trust=row['kind']=='formal')
    folder,current=row_paths(row);folder.mkdir(parents=True,exist_ok=True);os.chmod(folder,0o700)
    generation=folder/('generation-'+str(time.time_ns()));generation.mkdir(mode=0o700)
    atomic(generation/'fullchain.pem',pathlib.Path(cert).read_bytes());atomic(generation/'privkey.pem',pathlib.Path(key).read_bytes())
    row=dict(row,cert=str(current/'fullchain.pem'),key=str(current/'privkey.pem'),updated=time.time())
    oldtarget=os.readlink(current) if current.is_symlink() else None
    db=registry();oldrow=db.get(row['id']);was=active();bound=False
    if CONFIG.exists():
        bound=any(i.get('tls',{}).get('certificate_path')==row['cert'] for i in config().get('inbounds',[]))
    xbound=XCONFIG.exists() and any(pair.get('certificateFile')==row['cert'] for i in read(XCONFIG).get('inbounds',[]) for pair in i.get('streamSettings',{}).get('tlsSettings',{}).get('certificates',[]))
    xwas=bool(xpids()) if xbound else False
    try:
        switch_current(current,generation)
        if bound:
            initialize_sync()
            call([binary(),'check','-c',CONFIG])
            if was:service('restart');time.sleep(2);sync_now()
        if xbound:
            call([XBIN,'run','-test','-config',XCONFIG])
            if xwas:xrestart()
        db[row['id']]=row;save_registry(db)
    except BaseException as failure:
        if oldtarget is not None:switch_current(current,oldtarget)
        elif current.is_symlink():current.unlink()
        if bound and was:
            try:service('restart');time.sleep(1);sync_now(False)
            except Exception:say('⚠ 旧证书已恢复，但服务恢复失败。','warn')
        if xbound and xwas:
            try:xrestart()
            except Exception:say('旧证书已恢复，但 Xray 恢复失败。','warn')
        if oldrow:db[row['id']]=oldrow
        else:db.pop(row['id'],None)
        if isinstance(failure,KeyboardInterrupt):raise failure
        raise Error('证书切换失败，已恢复旧证书。')
    say('✓ 证书已保存：'+row['domain'],'ok')
    if sys.stdin.isatty():
        title('签发完成 · 证书信息')
        try:
            details=call(['openssl','x509','-in',row['cert'],'-noout','-subject','-issuer','-dates','-ext','subjectAltName']).decode(errors='replace')
            print(details,flush=True);say('证书路径：'+row['cert'],'dim');say('私钥路径：'+row['key']+'（不显示私钥内容）','dim')
            title('完整证书 PEM（含证书链）');print(pathlib.Path(row['cert']).read_text(),flush=True)
        except Exception:say('证书已保存，详情展示失败；可通过“查看已有证书”查看。','warn')
    return row

def schedule_renew():
    if alpine():
        path=pathlib.Path('/etc/periodic/daily/argo-cert-renew')
        atomic(path,f'#!/bin/sh\numask 077\nexec /usr/bin/python3 {SELF} renew-due >> {ROOT}/renew.log 2>&1\n',0o700)
        call(['rc-update','add','crond','default']);call(['rc-service','crond','start'])
    else:
        atomic('/etc/systemd/system/argo-cert-renew.service',f'[Service]\nType=oneshot\nExecStart=/usr/bin/python3 {SELF} renew-due\nUMask=0077\nTimeoutStartSec=3600\n')
        atomic('/etc/systemd/system/argo-cert-renew.timer','[Timer]\nOnCalendar=daily\nPersistent=true\nRandomizedDelaySec=1h\n[Install]\nWantedBy=timers.target\n')
        call(['systemctl','daemon-reload']);call(['systemctl','enable','--now','argo-cert-renew.timer'])

@locked
def issue_certificate(host=None,selfsigned=False):
    host=domain(host,True) if host else domain_input('证书域名（DNS 验证可使用 *.example.com）',wildcard=True)
    if selfsigned:
        if host.startswith('*.'):raise Error('自签节点请使用具体域名。')
        row={'id':hashlib.sha256(('self:'+host).encode()).hexdigest()[:20],'domain':host,'kind':'self','client':'openssl','method':'self','email':''}
        with tempfile.TemporaryDirectory(dir=ROOT) as tmp:
            cert=pathlib.Path(tmp)/'cert';key=pathlib.Path(tmp)/'key'
            call(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','3650','-subj','/CN='+host,'-addext','subjectAltName=DNS:'+host,'-keyout',key,'-out',cert],timeout=60)
            return publish_certificate(row,cert,key)
    existing=next((r for r in registry().values() if r['domain']==host and r['kind']=='formal'),None)
    if existing and not confirm('已有该域名证书，重新检查/申请并替换它的管理方式？'):return existing
    method=choose('验证方式：1 Cloudflare DNS API / 2 HTTP（公网 80） / 3 手动 DNS-01（无 API）',('1','2','3'),'1');method={'1':'dns','2':'http','3':'dns-manual'}[method]
    auth=cf_credentials(host) if method=='dns' else None
    email=prompt('ACME 联系邮箱')
    if not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+',email):raise Error('请输入有效邮箱。')
    if method=='dns-manual':
        selected=choose('手动 DNS 申请程序：1 acme.sh / 2 lego',('1','2'),'2');client='acme.sh' if selected=='1' else 'lego'
        say('手动 DNS-01 使用 '+client+'；后续续签也需人工添加 TXT。','warn')
    else:
        client=choose('申请程序：1 acme.sh（主用）/ 2 lego（备用）',('1','2'),'1');client='acme.sh' if client=='1' else 'lego'
    row={'id':existing['id'] if existing else hashlib.sha256(('formal:'+host).encode()).hexdigest()[:20],'domain':host,'kind':'formal','client':client,'method':method,'email':email}
    row['client_home']=str(ROOT/'clients'/row['id']/('attempt-'+str(time.time_ns())+'-'+client))
    if auth is not None:
        authfile=ROOT/'auth'/row['id']/('token-'+str(time.time_ns())+'.json')
        write(authfile,auth);row['auth_file']=str(authfile)
    try:cert,key=client_issue(row)
    except Cancel:raise
    except Exception as e:
        say(str(e),'warn')
        if not confirm('本次申请失败，改用备用程序申请？'):raise Cancel()
        row['client']='lego' if client=='acme.sh' else 'acme.sh'
        row['client_home']=str(ROOT/'clients'/row['id']/('attempt-'+str(time.time_ns())+'-'+row['client']))
        cert,key=client_issue(row)
    result=publish_certificate(row,cert,key)
    if method=='dns-manual':say('✓ 手动 DNS 证书已保存；到期前请进入“续签证书”并按提示更新 TXT。','ok')
    else:schedule_renew();say('✓ 已启用每日续签检查。','ok')
    return result

def list_certificates(select=False,host=None):
    rows=list(registry().items())
    # Include existing node certificate paths for inspection/reuse; never steal renewal ownership.
    known={r['cert'] for _,r in rows}
    if CONFIG.exists():
        for i in config().get('inbounds',[]):
            tls=i.get('tls',{});cert=tls.get('certificate_path');key=tls.get('key_path')
            if not cert or cert in known or not key:continue
            try:
                dns=names(cert);kind=cert_kind(cert)
                row={'id':'external-'+hashlib.sha256(cert.encode()).hexdigest()[:12],'domain':tls.get('server_name',''),'cert':cert,'key':key,'kind':kind,'client':'原安装程序','method':'external'}
                rows.append((row['id'],row));known.add(cert)
            except Exception:continue
    if XCONFIG.exists():
        for i in read(XCONFIG).get('inbounds',[]):
            tls=i.get('streamSettings',{}).get('tlsSettings',{})
            for pair in tls.get('certificates',[]):
                cert=pair.get('certificateFile');key=pair.get('keyFile')
                if not cert or not key or cert in known:continue
                try:
                    kind=cert_kind(cert);row={'id':'external-'+hashlib.sha256(cert.encode()).hexdigest()[:12],'domain':tls.get('serverName',''),'cert':cert,'key':key,'kind':kind,'client':'原安装程序','method':'external'}
                    rows.append((row['id'],row));known.add(cert)
                except Exception:continue
    valid=[]
    for rid,row in rows:
        try:
            details=decode_cert(row['cert']);san=names(row['cert']);expires=details['notAfter']
            if host:
                try:check_certificate(row['cert'],row['key'],host,trust=row['kind']=='formal')
                except Exception:continue
            valid.append((rid,row));item(len(valid),', '.join(san)+' · '+('自签' if row['kind']=='self' else '正式')+' · '+expires)
            say('证书：'+row['cert'],'dim');say('私钥路径：'+row['key'],'dim');say('续签程序：'+row['client']+('（手动 DNS，需人工更新 TXT）' if row.get('method')=='dns-manual' else ''),'dim')
        except Exception:say('⚠ 无法读取证书：'+row['cert'],'warn')
    if not valid:say('暂无可用证书。','warn');return None
    if select:
        value=choose('选择证书编号 / 0 返回',tuple(str(i) for i in range(len(valid)+1)))
        return None if value=='0' else valid[int(value)-1][1]
    return valid

def cert_menu():
    while True:
        title('证书申请 / 续签');item(1,'申请正式证书','install');item(2,'查看已有证书');item(3,'续签证书','edit');item(4,'生成自签证书','install');item(0,'返回首页','dim')
        option=choose('请选择',('0','1','2','3','4'))
        if option=='0':return
        try:
            if option=='1':issue_certificate()
            elif option=='4':issue_certificate(selfsigned=True)
            elif option=='2':
                row=list_certificates(True)
                if row and confirm('查看完整证书 PEM（不显示私钥）？'):print(pathlib.Path(row['cert']).read_text())
            else:
                row=list_certificates(True)
                if row:
                    if row['method'] in ('external','self'):raise Error('此证书由原安装程序续签，或为自签证书；可在申请菜单生成并切换新证书。')
                    if confirm('检查并续签 '+row['domain']+'？'):
                        cert,key=client_issue(row,True);publish_certificate(row,cert,key);schedule_renew()
        except Cancel:pass
        except Exception as e:say('错误：'+safe_error(e),'error')

def renew_due():
    failures=0
    for row in registry().values():
        if row['kind']!='formal' or row['method']=='external':continue
        if row['method']=='dns-manual':
            try:check_certificate(row['cert'],row['key'],row['domain'],seconds=30*86400,trust=True)
            except Exception:say('需要人工续签：'+row['domain']+'；请进入证书管理 → 续签证书更新 TXT。','warn')
            continue
        try:check_certificate(row['cert'],row['key'],row['domain'],seconds=30*86400,trust=True);continue
        except Exception:pass
        try:cert,key=client_issue(row,True);publish_certificate(row,cert,key)
        except Exception as e:failures+=1;say('续签失败：'+row['domain']+' / '+safe_error(e),'warn')
    if failures:raise Error(str(failures)+' 张证书续签失败，请查看日志。')

# ---------- Node editing ----------
def select_certificate(tls):
    title('域名 / 证书');item(1,'保留当前域名与证书','edit');item(2,'从证书列表选择域名');item(3,'手动输入新域名','edit');item(4,'手动指定证书与私钥路径','edit');item(0,'取消','dim')
    choice=choose('请选择',('0','1','2','3','4'),'1')
    if choice=='0':raise Cancel()
    if choice=='1':return None
    if choice=='4':
        host=domain_input('SNI / 域名',tls['server_name']);cert=prompt('证书完整路径',tls.get('certificate_path',''));key=prompt('私钥完整路径',tls.get('key_path',''))
        if not pathlib.Path(cert).is_absolute() or not pathlib.Path(key).is_absolute():raise Error('请输入绝对路径。')
        check_certificate(cert,key,host,trust=cert_kind(cert)=='formal');return {'domain':host,'cert':cert,'key':key,'kind':cert_kind(cert)}
    if choice=='2':
        row=list_certificates(True)
        if not row:raise Cancel()
        host=row['domain']
        if host.startswith('*.'):host=domain_input('通配符证书对应的具体节点域名')
        check_certificate(row['cert'],row['key'],host,trust=row['kind']=='formal');return dict(row,domain=host)
    host=domain_input('新域名',tls['server_name']);matches=matching_rows(host)
    if matches:
        for num,(_,row) in enumerate(matches,1):item(num,row['domain']+' · '+row['kind'])
        idx=choose('选择匹配证书',tuple(str(n) for n in range(1,len(matches)+1)),'1')
        return dict(matches[int(idx)-1][1],domain=host)
    kind=choose('无匹配证书：1 申请正式证书 / 2 生成自签证书 / 0 取消',('0','1','2'),'1')
    if kind=='0':raise Cancel()
    return issue_certificate(host,selfsigned=kind=='2')

def reality_probe(host,sni,port=443):
    # OpenSSL validates the target certificate against local CA roots and requested SNI.
    result=call(['openssl','s_client','-connect',host+':'+str(port),'-servername',sni,'-tls1_3','-verify_hostname',sni,'-verify_return_error'],input=b'',timeout=20)
    if b'TLSv1.3' not in result:raise Error('伪装目标未确认支持 TLS 1.3。')

def select_inbounds(cfg,kind):
    groups={4:[],6:[]};wildcards=[]
    for index,inbound in enumerate(cfg.get('inbounds',[])):
        reality=inbound.get('tls',{}).get('reality',{}).get('enabled',False)
        matches=(kind=='reality' and inbound.get('type')=='vless' and reality) or (kind=='tls' and inbound.get('type')=='vless' and not reality) or (kind=='hy2' and inbound.get('type')=='hysteria2')
        if not matches:continue
        try:family=ipaddress.ip_address(inbound.get('listen','::')).version
        except ValueError:raise Error('无法识别节点监听地址，请检查配置。')
        groups[family].append(index)
        if inbound.get('listen','::')=='::':wildcards.append(index)
    if not any(groups.values()):raise Error('没有该协议的节点。')
    title('选择修改范围');item(1,'IPv4','edit');item(2,'IPv6','edit');item(3,'IPv4 和 IPv6','edit');item(0,'返回上一级','dim')
    selected=choose('请选择修改范围',('0','1','2','3'))
    if selected=='0':raise Cancel()
    # A sole IPv6 wildcard is one configuration, not two independently editable nodes.
    # Do not infer actual IPv4 reachability from the wildcard alone.
    if not groups[4] and len(groups[6])==1 and wildcards==groups[6]:
        index=groups[6][0];inbound=cfg['inbounds'][index]
        say('当前协议只有一组配置，监听 [::]:'+str(inbound['listen_port'])+'；可能接收双栈连接。','warn')
        say('IPv4 是否可连接取决于实际监听和系统设置；UUID、SNI 等是这组配置共用的参数。','dim')
        if selected in ('1','2'):
            say('无法只对 IPv'+('4' if selected=='1' else '6')+' 单独修改这组共用参数。','warn')
            if not confirm('继续修改这组配置（会影响所有使用它的连接）？'):raise Cancel()
        return [index]
    families={'1':[4],'2':[6],'3':[4,6]}[selected];indices=[]
    for family in families:
        candidates=groups[family]
        if not candidates:raise Error('未配置 IPv'+str(family)+' 节点，未修改任何配置。')
        if len(candidates)>1:
            title('选择 IPv'+str(family)+' 节点')
            for number,index in enumerate(candidates,1):
                inbound=cfg['inbounds'][index]
                item(number,inbound.get('tag','节点')+' · 当前 SNI：'+inbound['tls'].get('server_name','未设置')+' · 端口：'+str(inbound['listen_port']))
            value=choose('请输入节点序号 / 0 返回',tuple(str(i) for i in range(len(candidates)+1)))
            if value=='0':raise Cancel()
            indices.append(candidates[int(value)-1])
        else:indices.append(candidates[0])
    return indices

def group_input(label,values,validate=lambda v:v,generate=None,secret=False):
    # Blank means preserve each selected node's value, including differing defaults.
    same=all(v==values[0] for v in values)
    default=str(values[0]) if same and not secret else ''
    shown=('已设置，留空保留' if secret else default or '各自原值')
    while True:
        value=prompt(label+' [当前：'+shown+'；留空保留]',secret=secret)
        if value=='':return None
        try:return generate() if generate and value.lower()=='g' else validate(value)
        except (Error,ValueError):say('↻ 输入格式无效，请重新输入。','retry')

def edit_node(kind):
    cfg=config();old=CONFIG.read_bytes();indices=select_inbounds(cfg,kind);new=copy.deepcopy(cfg);targets=[new['inbounds'][i] for i in indices];display_indices=list(indices)
    title('修改 '+{'reality':'VLESS-Reality','tls':'VLESS-TLS','hy2':'Hysteria2'}[kind])
    for i in indices:
        current=cfg['inbounds'][i];family=ipaddress.ip_address(current.get('listen','::')).version
        label='通配监听（可能双栈）' if current.get('listen','::')=='::' else 'IPv'+str(family)
        say(label+' · '+current.get('tag','节点')+' · 监听：'+('['+current.get('listen','::')+']' if family==6 else current.get('listen','0.0.0.0'))+':'+str(current['listen_port']))
        say('当前 SNI / 域名：'+current['tls'].get('server_name','未设置'),'default')
    say('留空分别保留各自原值；输入新值同时应用到所选节点。','dim')
    users=targets[0].get('users',[])
    if not users or any(not t.get('users') for t in targets):raise Error('节点没有用户。')
    user=0
    if len(users)>1:
        for num,u in enumerate(users,1):item(num,u.get('name','用户 '+str(num)))
        user=int(choose('用户编号',tuple(str(i) for i in range(1,len(users)+1))))-1
    if any(len(t['users'])!=len(users) or t['users'][user].get('name')!=users[user].get('name') for t in targets):
        raise Error('两组节点用户结构不同，请分别修改 IPv4 和 IPv6。')
    selected_users=[t['users'][user] for t in targets]
    if kind=='hy2':
        value=group_input('HY2 密码（G 自动生成）',[u['password'] for u in selected_users],generate=lambda:secrets.token_urlsafe(24),secret=True)
        if value is not None:
            for u in selected_users:u['password']=value
    else:
        value=group_input('UUID（G 自动生成）',[u['uuid'] for u in selected_users],lambda v:str(uuid.UUID(v)),lambda:str(uuid.uuid4()))
        if value is not None:
            for u in selected_users:u['uuid']=value
    def valid_port(v):
        if not v.isdigit() or not 1<=int(v)<=65535:raise Error('端口应为 1–65535。')
        return int(v)
    value=group_input('监听端口',[t['listen_port'] for t in targets],valid_port)
    if value is not None:
        for t in targets:t['listen_port']=value
    if kind=='reality':
        realities=[t['tls']['reality'] for t in targets]
        value=group_input('伪装目标',[r['handshake']['server'] for r in realities],domain)
        if value is not None:
            for r in realities:r['handshake']['server']=value
        value=group_input('客户端 SNI',[t['tls']['server_name'] for t in targets],domain)
        if value is not None:
            for t in targets:t['tls']['server_name']=value
        value=group_input('伪装目标端口',[r['handshake'].get('server_port',443) for r in realities],valid_port)
        if value is not None:
            for r in realities:r['handshake']['server_port']=value
        def valid_sid(v):
            if not re.fullmatch('[a-fA-F0-9]{0,16}',v) or len(v)%2:raise Error('Short ID 格式错误。')
            return v
        value=group_input('Short ID（G 自动生成）',[r['short_id'][0] for r in realities],valid_sid,lambda:secrets.token_hex(4))
        if value is not None:
            for r in realities:r['short_id'][0]=value
        if choose('密钥对：1 保留 / 2 自动生成新密钥对',('1','2'),'1')=='2':
            kp=call([binary(),'generate','reality-keypair']).decode();private=re.search(r'PrivateKey:\s*(\S+)',kp)
            if not private:raise Error('密钥对生成失败。')
            for r in realities:r['private_key']=private.group(1)
            say('新公钥：'+public_key(private.group(1)),'default')
        checked=set()
        for index,target in zip(indices,targets):
            tls=target['tls'];r=tls['reality'];before=cfg['inbounds'][index]['tls'];oldr=before['reality']
            args=(r['handshake']['server'],tls['server_name'],r['handshake'].get('server_port',443))
            oldargs=(oldr['handshake']['server'],before['server_name'],oldr['handshake'].get('server_port',443))
            if args!=oldargs and args not in checked:
                try:reality_probe(*args);checked.add(args)
                except Exception:raise Error('Reality 目标 TLS 1.3 / SNI 校验失败，未保存。')
    else:
        row=select_certificate(targets[0]['tls'])
        if row:
            oldpairs={(t['tls'].get('certificate_path'),t['tls'].get('key_path')) for t in targets}
            shared=[t for j,t in enumerate(new['inbounds']) if j not in indices and
                    (t.get('tls',{}).get('certificate_path'),t.get('tls',{}).get('key_path')) in oldpairs and not t.get('tls',{}).get('reality',{}).get('enabled')]
            allshared=bool(shared) and choose('当前证书被其它节点共用：1 一起更换 / 2 仅所选节点',('1','2'),'2')=='1'
            if allshared:
                display_indices+= [j for j,t in enumerate(new['inbounds']) if j not in display_indices and any(t is other for other in shared)]
            for target in targets+(shared if allshared else []):target['tls'].update(server_name=row['domain'],certificate_path=row['cert'],key_path=row['key'])
        for target in targets:
            tls=target['tls'];check_certificate(tls['certificate_path'],tls['key_path'],tls['server_name'],trust=cert_kind(tls['certificate_path'])=='formal')
    if not confirm('保存所选节点配置、重启 sing-box 并更新节点信息？'):return
    initialize_sync();commit_config(new,old)
    try:
        title('刚修改的节点链接 · 可直接复制')
        print(color('link',generate_links(new,json.loads(META.read_text()),display_indices)),flush=True);subscription_info()
        say('每条链接单独一行；复制到 v2rayN，从剪贴板导入。','dim')
    except Exception:
        say('配置已生效；链接展示失败，可到“查看节点信息”读取已保存链接。','warn')
    if kind=='reality' and alpine() and pathlib.Path('/etc/sing-box/reality_private_key.txt').exists():
        # The legacy informational files hold one pair; update only for a single pair.
        keys={i['tls']['reality']['private_key'] for i in new['inbounds'] if i.get('tls',{}).get('reality',{}).get('enabled')}
        if len(keys)==1:
            key=next(iter(keys));atomic('/etc/sing-box/reality_private_key.txt',key+'\n');atomic('/etc/sing-box/reality_public_key.txt',public_key(key)+'\n')

def node_info():
    if SYNC.exists():sync_now(False)
    path=pathlib.Path('/etc/nodes/sing-box/links.txt')
    if not path.exists():raise Error('没有保存的节点信息，请先安装或完成一次配置修改。')
    title('NODE · 节点信息');print(color('link',path.read_text()))

def node_menu():
    while True:
        title('更改节点配置');item(1,'VLESS-Reality','edit');item(2,'VLESS-TLS','edit');item(3,'Hysteria2','edit');item(0,'返回上一级','dim')
        option=choose('请选择',('0','1','2','3'))
        if option=='0':return
        try:edit_node({'1':'reality','2':'tls','3':'hy2'}[option])
        except Cancel:pass
        except Exception as e:say('错误：'+safe_error(e),'error')

def safe_error(error):
    return str(error) if isinstance(error,Error) else ('网络或执行超时，请查看日志。' if isinstance(error,subprocess.TimeoutExpired) else '执行失败，请检查配置、依赖及权限。')
def setup_root():
    os.umask(0o077)
    ROOT.mkdir(parents=True,exist_ok=True);LIB.mkdir(parents=True,exist_ok=True);os.chmod(ROOT,0o700);os.chmod(LIB,0o700)
XCONFIG=pathlib.Path('/etc/xray/config.json')
XSTATE=pathlib.Path('/var/lib/xray-node-sync/deployment.json')
XWORKER=pathlib.Path('/usr/local/lib/xray-node-sync/run')
XBIN='/usr/local/bin/xray'

def subscription_info():
    p=pathlib.Path('/etc/nodes/subscription.json')
    if p.exists():
        data=read(p);url=data.get('url','')
        if re.fullmatch(r'https://[A-Za-z0-9.-]+/subs',url):say('v2rayN 订阅地址：','dim');say(url,'ok');return
    say('订阅服务尚未安装；可从首页 4 安装。','dim')

def xworker():
    if not XWORKER.exists():raise Error('未找到 Xray 同步程序，请先通过本工具安装。')
    spec=importlib.util.spec_from_loader('vpskit_xray_sync',loader=None)
    mod=importlib.util.module_from_spec(spec);exec(compile(XWORKER.read_text(),str(XWORKER),'exec'),mod.__dict__);return mod

def xpids():
    found=[]
    for p in pathlib.Path('/proc').iterdir():
        if not p.name.isdigit():continue
        try:
            if re.sub(r' \(deleted\)$','',os.path.realpath(p/'exe'))!=os.path.realpath(XBIN):continue
            args=(p/'cmdline').read_bytes().split(b'\0')
            if str(XCONFIG).encode() not in args:continue
            ticks=(p/'stat').read_text().rsplit(')',1)[1].split()[19]
            found.append((int(p.name),ticks))
        except OSError:continue
    return found

def xstop():
    if alpine() and pathlib.Path('/etc/init.d/vpskit-xray').exists():
        call(['rc-service','vpskit-xray','stop'],allowed=(0,1))
    for pid,ticks in xpids():
        for sig in (signal.SIGTERM,signal.SIGKILL):
            try:
                p=pathlib.Path('/proc',str(pid))
                if (p/'stat').read_text().rsplit(')',1)[1].split()[19]!=ticks:break
                os.kill(pid,sig)
            except (ProcessLookupError,FileNotFoundError):break
            for _ in range(30):
                if not p.exists():break
                time.sleep(.1)

def xservice_setup():
    if not alpine():raise Error('现有 Xray 安装器仅支持 Alpine。')
    atomic('/etc/init.d/vpskit-xray','''#!/sbin/openrc-run
name="VPSKit Xray"
command="/usr/local/lib/xray-node-sync/run"
command_args="--launch"
command_background="yes"
pidfile="/run/vpskit-xray.pid"
output_log="/var/log/xray.log"
error_log="/var/log/xray.log"
depend() { need net; after firewall; }
''',0o755)
    call(['rc-update','add','vpskit-xray','default'])

def xrestart():
    if not alpine():raise Error('现有 Xray 管理仅支持 Alpine。')
    call([XBIN,'run','-test','-config',XCONFIG])
    xstop();xservice_setup();call(['rc-service','vpskit-xray','start'])
    error=None
    for _ in range(40):
        try:
            mod=xworker();mod.RUN.mkdir(parents=True,exist_ok=True)
            with open(mod.RUN/'lock','a') as lock:
                fcntl.flock(lock,fcntl.LOCK_EX);mod.sync()
            return
        except Exception as e:error=e;time.sleep(.25)
    raise Error('Xray 启动或节点发布失败：'+str(error))

def xinfo():
    if not XCONFIG.exists():say('Xray 尚未安装。','warn');return
    say('核心：'+XBIN,'dim');say('配置：'+str(XCONFIG),'dim')
    say('运行状态：'+('运行中' if xpids() else '未运行'),'ok')
    p=pathlib.Path('/etc/nodes/xray/links.txt')
    if p.exists():print(color('link',p.read_text()),flush=True)
    subscription_info()

@locked
def xedit():
    if not alpine():raise Error('现有 Xray 管理仅支持 Alpine。')
    if not XCONFIG.exists() or not XSTATE.exists():raise Error('请先安装 Xray。')
    if XCONFIG.is_symlink() or XSTATE.is_symlink():raise Error('配置或安装记录是符号链接，未覆盖。')
    original=XCONFIG.read_bytes();oldmeta=XSTATE.read_bytes();cfg=json.loads(original);meta=json.loads(oldmeta)
    candidates=[i for i in cfg.get('inbounds',[]) if i.get('protocol')=='vless' and i.get('streamSettings',{}).get('security')=='tls']
    if not candidates:raise Error('当前配置没有可修改的 VLESS TLS 节点。')
    for n,i in enumerate(candidates,1):item(n,'VLESS TLS · 端口 '+str(i['port']))
    choice=choose('选择节点 / 0 返回',tuple(str(n) for n in range(len(candidates)+1)))
    if choice=='0':return
    i=candidates[int(choice)-1];tls=i['streamSettings']['tlsSettings'];clients=i['settings']['clients']
    i['port']=port_input(i['port'],'节点端口')
    for n,c in enumerate(clients,1):c['id']=uuid_input(c['id'])
    certs=tls.get('certificates',[])
    if not certs:raise Error('配置缺少证书。')
    old=certs[0]
    row=select_certificate(dict(server_name=tls['serverName'],certificate_path=old['certificateFile'],key_path=old['keyFile']))
    if row:
        if any(t['streamSettings']['tlsSettings'].get('serverName')!=tls['serverName'] or t['streamSettings']['tlsSettings'].get('certificates')!=certs for t in candidates):raise Error('多个独立证书的配置不能共用当前同步模式，未保存修改。')
        prior_sni=tls['serverName'];prior_certs=copy.deepcopy(certs)
        # Both installers share one certificate/SNI; keep the sharing relationship.
        for target in candidates:
            t=target['streamSettings']['tlsSettings']
            if t.get('serverName')==prior_sni and t.get('certificates',[])==prior_certs:
                t['serverName']=row['domain'];t['certificates']=[dict(certificateFile=row['cert'],keyFile=row['key'])]
        meta['domain_mode']=row['kind']=='formal'
    candidate=json.dumps(cfg,ensure_ascii=False,indent=2)+'\n'
    temp=XCONFIG.with_name('.vpskit-test-'+secrets.token_hex(4)+'.json')
    try:
        atomic(temp,candidate);call([XBIN,'run','-test','-config',temp])
    finally:temp.unlink(missing_ok=True)
    if not confirm('配置校验通过，保存并重启 Xray？'):return
    if XCONFIG.read_bytes()!=original or XSTATE.read_bytes()!=oldmeta:raise Error('配置已被其他操作修改，请重新进入。')
    try:
        atomic(XCONFIG,candidate);write(XSTATE,meta);xrestart()
    except BaseException:
        atomic(XCONFIG,original);atomic(XSTATE,oldmeta)
        try:xrestart()
        except Exception:say('旧配置已恢复，但服务恢复失败，请查看 /var/log/xray.log。','warn')
        raise
    say('配置生效，节点和合并订阅已同步。','ok');xinfo()

def remove_group(group):
    call(['/usr/local/lib/argo-node-files/run','--remove',group])

def stop_unit(name):
    if alpine():
        if pathlib.Path('/etc/init.d',name).exists():call(['rc-service',name,'stop'],allowed=(0,1));call(['rc-update','del',name,'default'],allowed=(0,1))
    else:call(['systemctl','disable','--now',name],allowed=(0,1,5))

@locked
def uninstall_core(kind):
    if kind=='xray' and not alpine():raise Error('现有 Xray 管理仅支持 Alpine。')
    marker=XSTATE if kind=='xray' else META
    if not marker.exists():raise Error('未发现本工具管理的安装记录，未执行卸载。')
    if not confirm('卸载独立 '+kind+' 核心、配置及其链接？证书和其他节点保留。'):return
    if kind=='xray':
        xstop()
        if alpine():call(['rc-update','del','vpskit-xray','default'],allowed=(0,1))
        cron=subprocess.run(['crontab','-l'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
        if cron.returncode==0:call(['crontab','-'],input=('\n'.join(l for l in cron.stdout.decode().splitlines() if '# xray-node-sync' not in l)+'\n').encode())
        files=[XCONFIG,pathlib.Path(XBIN),pathlib.Path('/etc/init.d/vpskit-xray')]
        folders=['/usr/local/lib/xray-node-sync','/var/lib/xray-node-sync','/run/xray-node-sync']
    else:
        for unit in ('singbox-node-sync.timer','argo-sb-sync.timer','alpine-node-sync','argo-sb-sync','sing-box'):stop_unit(unit)
        files=[CONFIG,pathlib.Path('/usr/local/bin/sing-box'),pathlib.Path('/etc/init.d/sing-box'),pathlib.Path('/etc/init.d/alpine-node-sync'),RC_SYNC]
        files += [pathlib.Path('/etc/systemd/system',n) for n in ('sing-box.service','singbox-node-sync.service','singbox-node-sync.timer','argo-sb-sync.service','argo-sb-sync.timer')]
        folders=['/usr/local/lib/singbox-node-sync','/usr/local/lib/alpine-node-sync','/var/lib/singbox-node-sync','/run/singbox-node-sync','/etc/systemd/system/sing-box.service.d']
        link=pathlib.Path('/usr/bin/sing-box')
        if link.is_symlink() and os.readlink(link)=='/usr/local/bin/sing-box':files.append(link)
    remove_group(kind)
    for p in files:p.unlink(missing_ok=True)
    for folder in folders:shutil.rmtree(folder,ignore_errors=True)
    if not alpine():call(['systemctl','daemon-reload'])
    say('卸载完成，合并订阅已重新生成。','ok')

@locked
def xinstall(source):
    source=pathlib.Path(source)
    if source.name not in ('musl-Xray.sh','install-Xray-core.sh') or not source.is_file():raise Error('未知 Xray 安装器。')
    pathlib.Path('/var/backups/vpskit').mkdir(parents=True,exist_ok=True)
    backup=pathlib.Path(tempfile.mkdtemp(prefix='xray-',dir='/var/backups/vpskit'));backup.chmod(0o700)
    targets=[pathlib.Path('/etc/xray'),pathlib.Path(XBIN),XWORKER.parent,XSTATE.parent,pathlib.Path('/etc/init.d/vpskit-xray')]
    existing=[]
    was=bool(xpids());old_links=pathlib.Path('/etc/nodes/xray/links.txt');links=old_links.read_text() if old_links.exists() else None
    cron=subprocess.run(['crontab','-l'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
    old_jobs=[l for l in cron.stdout.decode().splitlines() if '# xray-node-sync' in l]
    enabled=pathlib.Path('/etc/runlevels/default/vpskit-xray').exists()
    for n,p in enumerate(targets):
        if p.exists():
            existing.append(n)
            if p.is_dir():shutil.copytree(p,backup/str(n),symlinks=True)
            else:shutil.copy2(p,backup/str(n))
    restored=True
    try:
        xstop()
        result=managed_run(['bash',source],timeout=1800)
        if result.returncode:raise Error('安装器未完成。')
        xrestart();xinfo()
    except BaseException:
        try:
            xstop()
            for n,p in enumerate(targets):
                if p.is_dir():shutil.rmtree(p)
                else:p.unlink(missing_ok=True)
                if n in existing:
                    p.parent.mkdir(parents=True,exist_ok=True)
                    if (backup/str(n)).is_dir():shutil.copytree(backup/str(n),p,symlinks=True)
                    else:shutil.copy2(backup/str(n),p)
            current=subprocess.run(['crontab','-l'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
            jobs=[l for l in current.stdout.decode().splitlines() if '# xray-node-sync' not in l]+old_jobs
            call(['crontab','-'],input=('\n'.join(jobs)+'\n').encode())
            if enabled:call(['rc-update','add','vpskit-xray','default'])
            else:call(['rc-update','del','vpskit-xray','default'],allowed=(0,1))
            if was:xrestart()
            if not enabled:call(['rc-update','del','vpskit-xray','default'],allowed=(0,1))
            if links is None:remove_group('xray')
            else:call(['/usr/local/lib/argo-node-files/run','--publish','xray'],input=links.encode())
            say('安装失败，原 Xray 配置和链接已恢复。','warn')
        except Exception:
            restored=False;say('恢复未完成，备份保留于 '+str(backup)+'；请查看 /var/log/xray.log。','warn')
        raise
    finally:
        if restored:shutil.rmtree(backup,ignore_errors=True)

def main():
    setup_root();action=sys.argv[1] if len(sys.argv)>1 else 'cert-menu'
    if action=='xray-install':xinstall(sys.argv[2])
    elif action=='xray-info':xinfo()
    elif action=='xray-edit':xedit()
    elif action=='xray-restart':xrestart();xinfo()
    elif action=='xray-renew-reload':
        if XCONFIG.exists() and XSTATE.exists() and xpids():
            try:
                with management_lock():xrestart()
            except Error as e:
                if '正在进行' not in str(e):raise
    elif action=='xray-stop':xstop()
    elif action=='xray-uninstall':uninstall_core('xray')
    elif action=='sb-uninstall':uninstall_core('sing-box')
    elif action=='cert-menu':cert_menu()
    elif action=='edit-menu':node_menu()
    elif action=='info':node_info();subscription_info()
    elif action=='cert-list':
        row=list_certificates(True)
        if row and confirm('查看完整证书 PEM（不显示私钥）？'):print(pathlib.Path(row['cert']).read_text())
    elif action=='renew-due':
        with open(ROOT/'renew.lock','a') as f:
            try:fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError:return
            renew_due()
    elif action=='post-install':
        initialize_sync();service('restart');time.sleep(2);sync_now()
        title('统一命名后的节点链接');print(color('link',LINKFILES[0].read_text()),flush=True);subscription_info()
    else:raise Error('未知管理选项。')
if __name__=='__main__':
    def stop_requested(signum,frame):raise KeyboardInterrupt()
    signal.signal(signal.SIGINT,stop_requested);signal.signal(signal.SIGTERM,stop_requested)
    try:main()
    except KeyboardInterrupt:say('已取消本次操作，申请子进程已清理，管理锁已释放。','warn');sys.exit(130)
    except Cancel:sys.exit(0)
    except Exception as e:say('错误：'+safe_error(e),'error');sys.exit(1)
