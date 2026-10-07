#!/usr/bin/env python3
"""Targeted subscription backups and lifecycle; shared nodes/certificates survive uninstall."""
import base64,json,os,pathlib,re,shutil,subprocess,sys,tempfile
STATE=pathlib.Path('/etc/nodes/subscription.json')
UNITS=('subscription-api.service','subscription-cert-sync.timer','subscription-cert-sync.service')
def run(args,check=True):return subprocess.run(args,check=check,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
def atomic(path,data):
 p=pathlib.Path(path);p.parent.mkdir(parents=True,exist_ok=True);fd,tmp=tempfile.mkstemp(dir=p.parent)
 try:
  os.fchmod(fd,0o600)
  with os.fdopen(fd,'wb') as f:f.write(data)
  os.replace(tmp,p)
 finally:
  if os.path.exists(tmp):os.unlink(tmp)
def load():
 if not STATE.exists():raise RuntimeError('订阅服务尚未安装。')
 d=json.loads(STATE.read_text());domain=d['domain']
 if not re.fullmatch(r'[A-Za-z0-9.-]+',domain) or '..' in domain:raise RuntimeError('订阅配置无效。')
 return d
def paths(domain):return ['/root/subscription_api.py','/usr/local/sbin/sync-subscription-cert.sh','/usr/local/lib/subscription-api/cert-sync.py','/etc/nodes/subscription-cert.json',str(STATE),'/etc/nginx/conf.d/'+domain+'.conf','/etc/nginx/ssl/'+domain+'/fullchain.pem','/etc/nginx/ssl/'+domain+'/privkey.pem']+['/etc/systemd/system/'+u for u in UNITS]
def capture(directory,domain):
 if not re.fullmatch(r'[A-Za-z0-9.-]+',domain) or '..' in domain:raise RuntimeError('域名无效。')
 records=[]
 names=paths(domain)
 if STATE.exists():
  previous=load()['domain']
  if previous!=domain:names+=['/etc/nginx/conf.d/'+previous+'.conf']
 for name in names:
  p=pathlib.Path(name)
  records.append(dict(path=name,data=base64.b64encode(p.read_bytes()).decode() if p.exists() else None,mode=p.stat().st_mode & 0o777 if p.exists() else 0o600,link=os.readlink(p) if p.is_symlink() else None))
 units={u:dict(active=run(['systemctl','is-active','--quiet',u],False).returncode==0,enabled=run(['systemctl','is-enabled','--quiet',u],False).returncode==0) for u in UNITS+('nginx.service',)}
 atomic(pathlib.Path(directory)/'backup.json',json.dumps(dict(files=records,units=units)).encode())
def restore(directory):
 data=json.loads((pathlib.Path(directory)/'backup.json').read_text())
 for u in UNITS:run(['systemctl','stop',u],False)
 for r in data['files']:
  p=pathlib.Path(r['path'])
  if r['link'] is not None:
   p.unlink(missing_ok=True);p.symlink_to(r['link'])
  elif r['data'] is None:p.unlink(missing_ok=True)
  else:atomic(p,base64.b64decode(r['data']));p.chmod(r['mode'])
 run(['systemctl','daemon-reload'])
 for u,s in data['units'].items():
  run(['systemctl','enable' if s['enabled'] else 'disable',u],False)
  if u=='nginx.service':
   if s['active']:
    run(['nginx','-t']);run(['systemctl','reload-or-restart','nginx'])
   else:run(['systemctl','stop','nginx'],False)
  elif s['active']:run(['systemctl','restart',u])
 print('安装失败，已恢复原订阅文件和服务状态。',file=sys.stderr)
def info():
 d=load();print('订阅地址：\n  '+d['url']+'\n节点文件：\n  /etc/nodes/subscription.txt')
 result=run(['systemctl','is-active','subscription-api.service'],False);print('API 状态：'+result.stdout.decode().strip())
def uninstall():
 d=load()
 if input('卸载订阅 API 和专用 Nginx 配置？节点、证书及 Nginx 保留。输入 YES：').strip().upper()!='YES':print('已取消。');return
 # Never remove a configuration repurposed by the administrator.
 p=pathlib.Path('/etc/nginx/conf.d')/(d['domain']+'.conf')
 if p.exists() and '# VPSKit subscription' not in p.read_text():raise RuntimeError('Nginx 配置已改变，未执行卸载。')
 original=p.read_bytes() if p.exists() else None
 p.unlink(missing_ok=True)
 if run(['nginx','-t'],False).returncode:
  if original is not None:atomic(p,original)
  raise RuntimeError('Nginx 检查失败，配置已恢复。')
 try:run(['systemctl','reload','nginx'])
 except Exception:
  if original is not None:atomic(p,original)
  raise
 for u in UNITS:
  run(['systemctl','disable','--now',u],False)
  if run(['systemctl','is-active','--quiet',u],False).returncode==0:
   if original is not None:atomic(p,original);run(['systemctl','reload','nginx'],False)
   raise RuntimeError('服务仍在运行，未删除程序文件，请检查 '+u)
 for name in ['/root/subscription_api.py','/usr/local/sbin/sync-subscription-cert.sh','/usr/local/lib/subscription-api/cert-sync.py','/etc/nodes/subscription-cert.json',str(STATE)]+['/etc/systemd/system/'+u for u in UNITS]:pathlib.Path(name).unlink(missing_ok=True)
 run(['systemctl','daemon-reload']);print('订阅服务已卸载，所有节点文件和证书保留。')
def save(domain):
 if not re.fullmatch(r'[A-Za-z0-9.-]+',domain) or '..' in domain:raise RuntimeError('域名无效。')
 atomic(STATE,json.dumps(dict(domain=domain,url='https://'+domain+'/subs'),ensure_ascii=False).encode())
if __name__=='__main__':
 try:
  action=sys.argv[1]
  if action=='capture':capture(sys.argv[2],sys.argv[3])
  elif action=='restore':restore(sys.argv[2])
  elif action=='save':save(sys.argv[2])
  elif action=='info':info()
  elif action=='uninstall':uninstall()
  else:raise RuntimeError('未知订阅管理操作。')
 except (KeyboardInterrupt,EOFError):sys.exit(130)
 except Exception as e:print('错误：'+str(e),file=sys.stderr);sys.exit(1)
