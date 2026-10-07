#!/usr/bin/env python3
"""Validate and publish a certificate/key pair; restore both if Nginx rejects it."""
import fcntl,json,os,pathlib,subprocess,tempfile
CONFIG=pathlib.Path('/etc/nodes/subscription-cert.json')
LOCK=pathlib.Path('/run/subscription-cert-sync.lock')
def run(args):return subprocess.run(args,check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=30).stdout
def atomic(path,data,mode):
 p=pathlib.Path(path);fd,name=tempfile.mkstemp(dir=p.parent)
 try:
  os.fchmod(fd,mode)
  with os.fdopen(fd,'wb') as f:f.write(data);f.flush();os.fsync(f.fileno())
  os.replace(name,p)
 finally:
  if os.path.exists(name):os.unlink(name)
def sync():
 os.umask(0o077);LOCK.parent.mkdir(parents=True,exist_ok=True)
 with LOCK.open('a') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX)
  cfg=json.loads(CONFIG.read_text());src,key,dst,dkey=(pathlib.Path(cfg[n]) for n in ('cert_src','key_src','cert_dst','key_dst'))
  certdata=src.read_bytes();keydata=key.read_bytes()
  oldcert=dst.read_bytes() if dst.exists() else None;oldkey=dkey.read_bytes() if dkey.exists() else None
  if certdata==oldcert and keydata==oldkey:return
  with tempfile.TemporaryDirectory(dir=dst.parent) as tmp:
   c=pathlib.Path(tmp)/'cert.pem';k=pathlib.Path(tmp)/'key.pem';c.write_bytes(certdata);k.write_bytes(keydata)
   run(['openssl','x509','-in',str(c),'-noout','-checkend','0'])
   result=run(['openssl','x509','-in',str(c),'-noout','-checkhost',cfg['domain']])
   if b'does match certificate' not in result:raise RuntimeError('证书域名不匹配，未更新 Nginx。')
   if run(['openssl','x509','-in',str(c),'-pubkey','-noout'])!=run(['openssl','pkey','-in',str(k),'-pubout']):raise RuntimeError('证书与私钥不匹配，未更新 Nginx。')
   if src.read_bytes()!=certdata or key.read_bytes()!=keydata:raise RuntimeError('申请来源正在更新，留待下一次同步。')
  try:
   atomic(dst,certdata,0o644);atomic(dkey,keydata,0o600)
   run(['nginx','-t']);run(['systemctl','reload','nginx'])
  except BaseException:
   for p,data,mode in ((dst,oldcert,0o644),(dkey,oldkey,0o600)):
    if data is None:p.unlink(missing_ok=True)
    else:atomic(p,data,mode)
   raise
  print('订阅证书已同步，Nginx 已重新加载。')
if __name__=='__main__':
 try:sync()
 except Exception as e:
  import sys
  print('证书同步失败，保留原证书：'+(str(e) if isinstance(e,RuntimeError) else type(e).__name__),file=sys.stderr);sys.exit(1)
