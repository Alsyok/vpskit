#!/usr/bin/env python3
"""Offline tests. Services and network commands are mocked; never operate on the host VPS."""
import unittest.mock
import ast,base64,copy,hashlib,json,os,pathlib,re,shutil,subprocess,tempfile,time,unittest,urllib.parse
ROOT=pathlib.Path(__file__).resolve().parents[1]
def body(path,name):
 s=path.read_text();return re.search(r"<<'"+name+r"'\n(.*?)\n"+name,s,re.S).group(1)
def namespace(path):
 ns={'__name__':'vpskit_test','__file__':str(path)};source=path.read_text().replace('/usr/local/lib/argo-node-files/sync-publication.py',str(ROOT/'lib/sync-publication.py'));exec(compile(source,str(path),'exec'),ns);return ns
class SyntaxTests(unittest.TestCase):
 def test_shell_and_python(self):
  for p in ROOT.rglob('*.sh'):
   shell='bash' if p.parent.name=='installers' or p.name=='vpskit.sh' else 'sh'
   subprocess.run([shell,'-n',str(p)],check=True)
   # Compile quoted Python heredocs too, which bash -n cannot inspect.
   for marker,code in re.findall(r"<<'([A-Z_]+)'\n(.*?)\n\1",p.read_text(),re.S):
    if marker.endswith(('PY','META')) or marker in ('NODE_SYNC_META','NODE_FILES_PY') or code.lstrip().startswith(('import ','from ','#!/usr/bin/env python3')):
     compile(code,str(p)+':'+marker,'exec')
    elif code.startswith(('#!/bin/sh','#!/sbin/openrc-run','#!/usr/bin/env bash')):
     with tempfile.NamedTemporaryFile(mode='w') as file:
      file.write(code);file.flush();subprocess.run(['bash' if 'bash' in code.splitlines()[0] else 'sh','-n',file.name],check=True)
  for p in (ROOT/'lib').glob('*.py'):compile(p.read_text(),str(p),'exec')
  ns=namespace(ROOT/'lib/node-manager.py')
  for key in ('SYNC_SOURCE','PUBLICATION_SOURCE'):compile(base64.b64decode(ns[key]).decode(),key,'exec')
 def test_argo_split(self):
  text=(ROOT/'modules/CFtunnel.sh').read_text()
  entries=re.findall(r"menu_item .*?'(\d+)\.'",text[text.rindex('\nmain() {'):])
  self.assertEqual(entries,[str(i) for i in range(1,16)]+['0'])
  self.assertNotIn('ARGO_STANDALONE_PY',text)
  for file in ('Encrypt.sh','singbox.sh'):
   ns=namespace(ROOT/'lib/node-manager.py');source=body(ROOT/'installers'/file,'NODE_SYNC_PY')
   updated=ns['current_sync_source'](source);compile(updated,file,'exec');self.assertEqual(updated,ns['current_sync_source'](updated))
   self.assertNotIn("OUTPUT=pathlib.Path('/root/singbox_nodes.txt')",updated)
class FreshStartupTests(unittest.TestCase):
 def test_startup_does_not_migrate_old_workers(self):
  for path in [ROOT/'vpskit.sh',ROOT/'lib/node-services.sh',*list((ROOT/'modules').glob('*.sh'))]:
   source=path.read_text()
   self.assertNotIn('migrate_installed',source)
   self.assertNotIn('sync-publication.py',source)
  ns=namespace(ROOT/'lib/node-manager.py')
  with self.assertRaises(ns['Error']):ns['current_sync_source']('def old_sync():pass')
  self.assertNotIn('var/backups/vpskit', (ROOT/'lib/node-manager.py').read_text())
class MobileMenuTests(unittest.TestCase):
 def test_blank_crlf_and_invalid_selection(self):
  common=(ROOT/'lib/common.sh').read_text()
  ask=common[common.index('ask() {'):common.index('menu_item() {')]
  stub="print_prompt_defaults() { :; }; C_CYAN=; C_PROMPT=; C_PURPLE=; C_RESET=;\n"
  code=stub+ask+"\nask '请选择 [0–7]：'; printf '%s' \"$REPLY\""
  result=subprocess.run(['sh','-c',code],input='\r\n\n 2 \r\n',text=True,capture_output=True,timeout=5)
  self.assertEqual(result.stdout,'2');self.assertEqual(result.returncode,0)
  default=stub+ask+"\nask '域名 [example.com]：'; printf '<%s>' \"$REPLY\""
  result=subprocess.run(['sh','-c',default],input='\n',text=True,capture_output=True,timeout=5);self.assertEqual(result.stdout,'<>')
  module=(ROOT/'modules/xray-manager.sh').read_text();func=module[module.index('xray_install() {'):module.index('case "${1:-menu}" in')]
  code=stub+ask+"\nMANAGER=openrc; VPSKIT_ROOT=/test; standalone_tools() { :; }; die() { exit 1; }; retry_input() { :; }; bash() { :; }; python3() { printf '%s' \"$3\"; };\n"+func+'\nxray_install'
  result=subprocess.run(['sh','-c',code],input='\n9\n2\r\n',text=True,capture_output=True,timeout=5)
  self.assertEqual(result.returncode,0);self.assertEqual(result.stdout,'/test/installers/install-Xray-core.sh')
class PublisherTests(unittest.TestCase):
 def test_groups_remove_and_rollback(self):
  ns=namespace(ROOT/'lib/node-files.py')
  with tempfile.TemporaryDirectory() as tmp:
   root=pathlib.Path(tmp);ns.update(ROOT=root/'nodes',LOCK=root/'lock')
   for group in ('argo','sing-box','xray'):ns['publish'](group,'vless://'+group+'@test:443\n')
   self.assertEqual((root/'nodes/subscription.txt').read_text().splitlines(),['vless://argo@test:443','vless://sing-box@test:443','vless://xray@test:443'])
   ns['publish']('xray',remove=True);self.assertNotIn('xray',(root/'nodes/subscription.txt').read_text());self.assertTrue((root/'nodes/sing-box/links.txt').exists())
   old=(root/'nodes/subscription.txt').read_bytes();original=ns['atomic'];failed=[False]
   def atomic(path,data):
    if str(path).endswith('subscription.txt') and not failed[0]:failed[0]=True;raise OSError('simulated disk failure')
    return original(path,data)
   ns['atomic']=atomic
   with self.assertRaises(OSError):ns['publish']('sing-box','vless://replacement@test:443\n')
   self.assertEqual((root/'nodes/subscription.txt').read_bytes(),old)
   self.assertEqual((root/'nodes/sing-box/links.txt').read_text(),'vless://sing-box@test:443\n')
 def test_xray_naming_and_loaded_guard(self):
  for file in ('musl-Xray.sh','install-Xray-core.sh'):
   ns={'__name__':'test'};exec(body(ROOT/'installers'/file,'XRAY_SYNC_PY'),ns)
   cfg={'inbounds':[{'port':18477,'protocol':'vless','settings':{'clients':[{'id':'7bd86e44-7eaf-4815-855d-58079c65ca96'}]},'streamSettings':{'network':'tcp','security':'tls','tlsSettings':{'serverName':'test.example'}}}]}
   ns['country']=lambda ip:'🇸🇬Singapore'
   cfg['inbounds'][0]['streamSettings']['tlsSettings']['certificates']=[{'certificateFile':'/test/cert.pem'}]
   ns['run']=lambda *a,**k:b'test certificate DER'
   content,ports=ns['generate'](cfg,dict(ip='192.0.2.1',domain_mode=True))
   self.assertIn('allowInsecure=0',content);self.assertIn('@test.example:18477',content)
   self.assertEqual(urllib.parse.unquote(content.split('#')[1]).strip(),'VLESS-TLS-V4PORT-test.example-🇸🇬Singapore')
   cfg['inbounds'][0]['streamSettings']['tlsSettings']['certificates']=[{'certificateFile':'/test/self.pem'}]
   ns['run']=lambda *a,**k:b'test certificate DER'
   content6,_=ns['generate'](cfg,dict(ip='2001:db8::1',domain_mode=False));self.assertIn('@[2001:db8::1]:18477',content6);self.assertIn('allowInsecure=0',content6);self.assertIn('pcs='+hashlib.sha256(b'test certificate DER').hexdigest(),content6)
   with tempfile.TemporaryDirectory() as tmp:
    root=pathlib.Path(tmp);ns.update(CONFIG=root/'config.json',STATE=root/'state',RUN=root/'run',NODES=root/'nodes',OUTPUT=root/'nodes/xray/links.txt',PUBLISH_RUN=root/'pub')
    ns['STATE'].mkdir();ns['RUN'].mkdir();data=json.dumps(cfg).encode();ns['CONFIG'].write_bytes(data)
    ns['write'](ns['STATE']/'deployment.json',dict(ip='192.0.2.1',domain_mode=True));ns['write'](ns['RUN']/'active.json',dict(pid=100,ticks='5',sha=ns['digest'](data)))
    ns.update(process=lambda pid:'5',run=lambda args,**k:b'test certificate DER' if args[0]=='openssl' else b'',listeners=lambda *a:None)
    publisher=namespace(ROOT/'lib/node-files.py');publisher.update(ROOT=ns['NODES'],LOCK=ns['PUBLISH_RUN'])
    ns['publish_nodes']=lambda content:publisher['publish']('xray',content)
    ns['sync']();self.assertEqual(ns['OUTPUT'].read_text(),content)
    ns['CONFIG'].write_text('{}')
    with self.assertRaises(RuntimeError):ns['sync']()
    self.assertEqual(ns['OUTPUT'].read_text(),content)
class XrayCertificatePinTests(unittest.TestCase):
 def test_real_certificate_hash_and_replacement(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=pathlib.Path(tmp);key=root/'key.pem';cert=root/'cert.pem'
   cfg={'inbounds':[{'port':443,'protocol':'vless','settings':{'clients':[{'id':'7bd86e44-7eaf-4815-855d-58079c65ca96'}]},'streamSettings':{'network':'tcp','security':'tls','tlsSettings':{'serverName':'test.example','certificates':[{'certificateFile':str(cert)}]}}}]}
   previous=None
   for _ in range(2):
    subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=test.example','-addext','subjectAltName=DNS:test.example','-addext','basicConstraints=critical,CA:FALSE','-keyout',str(key),'-out',str(cert)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    fingerprint=subprocess.check_output(['openssl','x509','-in',str(cert),'-noout','-fingerprint','-sha256']).decode().strip().split('=')[1].replace(':','').lower()
    self.assertNotEqual(fingerprint,previous);previous=fingerprint
    for filename in ('musl-Xray.sh','install-Xray-core.sh'):
     ns={'__name__':'test'};exec(body(ROOT/'installers'/filename,'XRAY_SYNC_PY'),ns);ns['country']=lambda ip:''
     content,_=ns['generate'](cfg,dict(ip='192.0.2.1',domain_mode=False))
     query=urllib.parse.parse_qs(urllib.parse.urlsplit(content.strip()).query)
     self.assertEqual(query['pcs'],[fingerprint]);self.assertEqual(query['allowInsecure'],['0'])
     formal,_=ns['generate'](cfg,dict(ip='192.0.2.1',domain_mode=True));self.assertIn('pcs='+fingerprint,formal)
   cert.unlink()
   with self.assertRaises(Exception):ns['generate'](cfg,dict(ip='192.0.2.1',domain_mode=False))
class EditTests(unittest.TestCase):
 def test_xray_transaction(self):
  for fail in (False,True):
   ns=namespace(ROOT/'lib/node-manager.py')
   with tempfile.TemporaryDirectory() as tmp:
    root=pathlib.Path(tmp);ns.update(ROOT=root,XCONFIG=root/'config.json',XSTATE=root/'deployment.json')
    tls=dict(serverName='old.example',certificates=[dict(certificateFile='/cert/old.pem',keyFile='/cert/key.pem')])
    inbound=dict(protocol='vless',port=443,settings=dict(clients=[dict(id='7bd86e44-7eaf-4815-855d-58079c65ca96')]),streamSettings=dict(security='tls',tlsSettings=tls))
    cfg=dict(inbounds=[copy.deepcopy(inbound),copy.deepcopy(inbound)]);cfg['inbounds'][1]['port']=8443
    old=json.dumps(cfg).encode();meta=json.dumps(dict(ip='192.0.2.1',domain_mode=False)).encode();ns['XCONFIG'].write_bytes(old);ns['XSTATE'].write_bytes(meta)
    ns.update(alpine=lambda:True,choose=lambda *a:'1',confirm=lambda *a:True,port_input=lambda *a:9443,uuid_input=lambda old:old,select_certificate=lambda *a:dict(domain='new.example',cert='/cert/new.pem',key='/cert/new.key',kind='formal'),call=lambda *a,**k:b'',xinfo=lambda:None,say=lambda *a:None,item=lambda *a:None)
    calls=[]
    def restart():
     calls.append(ns['XCONFIG'].read_bytes())
     if fail and len(calls)==1:raise ns['Error']('simulated restart failure')
    ns['xrestart']=restart
    if fail:
     with self.assertRaises(ns['Error']):ns['xedit']()
     self.assertEqual(ns['XCONFIG'].read_bytes(),old);self.assertEqual(ns['XSTATE'].read_bytes(),meta);self.assertEqual(len(calls),2)
    else:
     ns['xedit']();new=json.loads(ns['XCONFIG'].read_text());self.assertEqual(new['inbounds'][0]['port'],9443);self.assertEqual(new['inbounds'][1]['port'],8443)
     self.assertTrue(all(i['streamSettings']['tlsSettings']['serverName']=='new.example' for i in new['inbounds']))
     self.assertTrue(json.loads(ns['XSTATE'].read_text())['domain_mode'])
 def test_certificate_switch_xray_and_rollback(self):
  for fail in (False,True):
   ns=namespace(ROOT/'lib/node-manager.py')
   with tempfile.TemporaryDirectory() as tmp:
    root=pathlib.Path(tmp);ns.update(ROOT=root,CONFIG=root/'sb.json',XCONFIG=root/'xray.json')
    row=dict(id='demo',domain='test.example',kind='formal');folder,current=ns['row_paths'](row);folder.mkdir(parents=True);old=folder/'old';old.mkdir();current.symlink_to(old)
    cert=root/'cert.pem';key=root/'key.pem';cert.write_text('NEW CERT');key.write_text('NEW KEY')
    ns['XCONFIG'].write_text(json.dumps(dict(inbounds=[dict(streamSettings=dict(tlsSettings=dict(certificates=[dict(certificateFile=str(current/'fullchain.pem'))])))])))
    calls=[]
    def restart():
     calls.append(os.readlink(current))
     if fail and len(calls)==1:raise ns['Error']('reload failure')
    ns.update(check_certificate=lambda *a,**k:None,active=lambda:False,xpids=lambda:[(10,'1')],xrestart=restart,call=lambda *a,**k:b'',say=lambda *a:None)
    if fail:
     with self.assertRaises(ns['Error']):ns['publish_certificate'](row,cert,key)
     self.assertEqual(os.readlink(current),str(old));self.assertEqual(len(calls),2)
    else:
     result=ns['publish_certificate'](row,cert,key);self.assertEqual(pathlib.Path(result['cert']).read_text(),'NEW CERT');self.assertEqual(len(calls),1)
class LogTests(unittest.TestCase):
 def test_rotation_retention(self):
  worker=body(ROOT/'lib/node-services.sh','LOGWORKER')
  with tempfile.TemporaryDirectory() as tmp:
   root=pathlib.Path(tmp)
   for p in ('run','etc/vps-tunnel','var/log/vps-tunnel'):(root/p).mkdir(parents=True)
   for prefix in ('/run/','/etc/','/var/'):worker=worker.replace(prefix,str(root)+prefix)
   script=root/'worker';script.write_text(worker);log=root/'var/log/vps-tunnel/cloudflared.log';log.write_bytes(b'x'*5242880);inode=log.stat().st_ino
   with log.open('a') as stream:
    subprocess.run(['sh',str(script)],check=True);stream.write('continued\n');stream.flush()
   self.assertEqual(log.stat().st_ino,inode);self.assertEqual(log.read_text(),'continued\n')
   for _ in range(4):log.write_bytes(b'x'*5242880);subprocess.run(['sh',str(script)],check=True)
   self.assertFalse(pathlib.Path(str(log)+'.4').exists())
   old=pathlib.Path(str(log)+'.2');os.utime(old,(time.time()-16*86400,)*2);log.write_text('keep\n');subprocess.run(['sh',str(script)],check=True)
   self.assertFalse(old.exists());self.assertEqual(log.read_text(),'keep\n')
   sb=root/'var/log/sing-box';sb.mkdir(parents=True)
   for name in ('sing-box.log','sing-box.stdout','sing-box.err'):(sb/name).write_bytes(b'x'*5242880)
   subprocess.run(['sh',str(script)],check=True)
   for name in ('sing-box.log','sing-box.stdout','sing-box.err'):self.assertTrue((sb/(name+'.1')).exists())
class MenuTests(unittest.TestCase):
 def test_all_menu_returns(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=pathlib.Path(tmp);project=root/'vpskit';shutil.copytree(ROOT,project)
   # Redirect every installed file into a temporary fake filesystem.
   for p in project.rglob('*'):
    if p.suffix in ('.sh','.py') and 'tests' not in p.parts:
     text=p.read_text()
     for prefix in ('/usr/local/','/etc/','/var/','/run/'):text=text.replace(prefix,str(root/'fs')+prefix)
     p.write_text(text)
   common=project/'lib/common.sh'
   with common.open('a') as f:f.write('\ndetect() { ID=debian; MANAGER=systemd; ARCH=amd64; }\n')
   binpath=root/'bin';binpath.mkdir()
   for name in ('systemctl','rc-service','rc-update'):
    file=binpath/name;file.write_text('#!/bin/sh\nexit 0\n');file.chmod(0o755)
   env=dict(os.environ,PATH=str(binpath)+':'+os.environ['PATH'],NO_COLOR='1')
   # Enter each module, return to the parent, then exit. Singbox also exercises a nested menu.
   for sequence in ('1\n0\n6\n','2\n1\n0\n0\n6\n','3\n0\n6\n','4\n0\n6\n','5\n0\n6\n'):
    run=subprocess.run(['bash',str(project/'vpskit.sh')],input=sequence,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=15)
    self.assertEqual(run.returncode,0,run.stderr);self.assertGreaterEqual(run.stdout.count('VPSKit ·'),2)
   self.assertFalse((root/'fs/etc/vps-cf-api/pause-pid').exists())
class SubscriptionTests(unittest.TestCase):
 def test_install_restore_and_uninstall_scope(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=pathlib.Path(tmp);source=(ROOT/'lib/subscription-manager.py').read_text()
   for prefix in ('/root/','/usr/local/','/etc/'):source=source.replace(prefix,str(root)+prefix)
   ns={'__name__':'test'};exec(compile(source,'subscription','exec'),ns)
   ns['save']('old.example');oldstate=ns['STATE'].read_bytes()
   oldconf=root/'etc/nginx/conf.d/old.example.conf';oldconf.parent.mkdir(parents=True);oldconf.write_text('# VPSKit subscription\nOLD')
   api=root/'root/subscription_api.py';api.parent.mkdir();api.write_text('OLD API');api.chmod(0o640)
   ssl=root/'etc/nginx/ssl/new.example';ssl.mkdir(parents=True);(ssl/'fullchain.pem').write_text('KEEP CERT')
   backup=root/'backup';backup.mkdir();calls=[]
   def run(args,check=True):
    calls.append(args)
    code=0
    if args[1:3]==['is-active','--quiet'] and any(x[:2]==['systemctl','disable'] for x in calls):code=3
    return subprocess.CompletedProcess(args,code,b'active\n',b'')
   ns['run']=run;ns['capture'](str(backup),'new.example')
   api.write_text('NEW API');oldconf.unlink();newconf=root/'etc/nginx/conf.d/new.example.conf';newconf.write_text('# VPSKit subscription\nNEW');ns['save']('new.example')
   ns['restore'](str(backup));self.assertEqual(api.read_text(),'OLD API');self.assertEqual(api.stat().st_mode&0o777,0o640);self.assertEqual(ns['STATE'].read_bytes(),oldstate);self.assertTrue(oldconf.exists());self.assertFalse(newconf.exists())
   nodes=root/'etc/nodes/subscription.txt';nodes.write_text('vless://keep@test:443\n')
   ns['input']=lambda *a:'YES';ns['uninstall']()
   self.assertFalse(api.exists());self.assertFalse(oldconf.exists());self.assertFalse(ns['STATE'].exists())
   self.assertTrue(nodes.exists());self.assertEqual((ssl/'fullchain.pem').read_text(),'KEEP CERT')
 def test_uninstall_failed_nginx_retains_config(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=pathlib.Path(tmp);source=(ROOT/'lib/subscription-manager.py').read_text()
   for prefix in ('/root/','/usr/local/','/etc/'):source=source.replace(prefix,str(root)+prefix)
   ns={'__name__':'test'};exec(source,ns);ns['save']('test.example')
   conf=root/'etc/nginx/conf.d/test.example.conf';conf.parent.mkdir(parents=True);conf.write_text('# VPSKit subscription\nORIGINAL')
   ns['input']=lambda *a:'YES';ns['run']=lambda args,check=True:subprocess.CompletedProcess(args,1,b'',b'')
   with self.assertRaises(RuntimeError):ns['uninstall']()
   self.assertEqual(conf.read_text(),'# VPSKit subscription\nORIGINAL');self.assertTrue(ns['STATE'].exists())
class BootstrapTests(unittest.TestCase):
 def test_download_checksum_and_short_command(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=pathlib.Path(tmp);fixture=root/'fixture';shutil.copytree(ROOT,fixture)
   for p in fixture.rglob('*'):
    if p.suffix in ('.sh','.py') and 'tests' not in p.parts:
     text=p.read_text()
     for prefix in ('/usr/local/','/etc/','/var/','/run/'):text=text.replace(prefix,str(root/'fs')+prefix)
     p.write_text(text)
   with (fixture/'lib/common.sh').open('a') as f:f.write('\ndetect() { ID=debian; MANAGER=systemd; ARCH=amd64; }\n')
   subprocess.run(['python3',str(fixture/'scripts/build-manifest.py')],check=True,stdout=subprocess.DEVNULL)
   launcher=root/'remote.sh';launcher.write_text((fixture/'vpskit.sh').read_text())
   binpath=root/'bin';binpath.mkdir();curl=binpath/'curl';counter=root/'calls'
   curl.write_text('#!'+shutil.which('python3')+'\nimport sys,pathlib,shutil\na=sys.argv[1:]\nurl=next(x for x in a if x.startswith("https://"))\nname=url.split("/main/",1)[1]\nshutil.copyfile(pathlib.Path('+repr(str(fixture))+')/name,a[a.index("-o")+1])\nwith open('+repr(str(counter))+',"a") as f:f.write(name+"\\n")\n');curl.chmod(0o755)
   env=dict(os.environ,PATH=str(binpath)+':'+os.environ['PATH'],NO_COLOR='1')
   result=subprocess.run(['bash',str(launcher)],input='6\n',text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=20)
   self.assertEqual(result.returncode,0,result.stderr)
   destination=root/'fs/usr/local/lib/vpskit';old=(destination/'lib/common.sh').read_bytes();count=len(counter.read_text().splitlines())
   result=subprocess.run(['bash',str(root/'fs/usr/local/bin/vpskit')],input='6\n',text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=10)
   self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(len(counter.read_text().splitlines()),count)
   with (fixture/'lib/common.sh').open('a') as f:f.write('\n# corrupt checksum\n')
   result=subprocess.run(['bash',str(launcher)],input='6\n',text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=20)
   self.assertNotEqual(result.returncode,0);self.assertEqual((destination/'lib/common.sh').read_bytes(),old)
   self.assertFalse(list((root/'fs/usr/local/lib').glob('.vpskit-download.*')))

class CertificateSyncTests(unittest.TestCase):
 def test_pair_validation_and_nginx_rollback(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=pathlib.Path(tmp)
   for prefix in ('old','new','wrong'):
    subprocess.run(['openssl','req','-x509','-nodes','-days','2','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256','-subj','/CN=test.example','-addext','subjectAltName=DNS:test.example','-keyout',str(root/(prefix+'.key')),'-out',str(root/(prefix+'.crt'))],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   ns=namespace(ROOT/'lib/subscription-cert-sync.py');ns.update(CONFIG=root/'config.json',LOCK=root/'lock')
   cert=root/'dst.crt';key=root/'dst.key';cert.write_bytes((root/'old.crt').read_bytes());key.write_bytes((root/'old.key').read_bytes());original=(cert.read_bytes(),key.read_bytes())
   settings=dict(domain='test.example',cert_src=str(root/'new.crt'),key_src=str(root/'wrong.key'),cert_dst=str(cert),key_dst=str(key));ns['CONFIG'].write_text(json.dumps(settings))
   with self.assertRaises(RuntimeError):ns['sync']()
   self.assertEqual((cert.read_bytes(),key.read_bytes()),original)
   settings['key_src']=str(root/'new.key');settings['domain']='other.example';ns['CONFIG'].write_text(json.dumps(settings))
   with self.assertRaises(RuntimeError):ns['sync']()
   self.assertEqual((cert.read_bytes(),key.read_bytes()),original)
   settings['domain']='test.example';ns['CONFIG'].write_text(json.dumps(settings));execute=ns['run']
   def run(args):
    if args[0]=='nginx':raise subprocess.CalledProcessError(1,args)
    return execute(args)
   ns['run']=run
   with self.assertRaises(subprocess.CalledProcessError):ns['sync']()
   self.assertEqual((cert.read_bytes(),key.read_bytes()),original)
   ns['run']=lambda args:b'' if args[0] in ('nginx','systemctl') else execute(args)
   ns['sync']();self.assertEqual(cert.read_bytes(),(root/'new.crt').read_bytes());self.assertEqual(key.stat().st_mode&0o777,0o600)

class InstallationRollbackTests(unittest.TestCase):
 def test_fresh_install_failure_never_restores_old_install(self):
  with tempfile.TemporaryDirectory() as tmp:
   installer=pathlib.Path(tmp)/'musl-Xray.sh';installer.write_text('# stub')
   ns=namespace(ROOT/'lib/node-manager.py');calls=[]
   ns.update(confirm=lambda *a:True,management_lock=__import__('contextlib').nullcontext,alpine=lambda:True,call=lambda *a,**k:b'',say=lambda *a:None,fresh_cleanup=lambda kind:calls.append(('clean',kind)),xrestart=lambda:calls.append(('restart',)),xinfo=lambda:None)
   def failed(*args,**kwargs):raise KeyboardInterrupt()
   ns['managed_run']=failed
   with self.assertRaises(KeyboardInterrupt):ns['xinstall'](installer)
   self.assertEqual(calls,[('clean','xray'),('clean','xray')])
 def test_fresh_install_success_starts_new_xray(self):
  with tempfile.TemporaryDirectory() as tmp:
   installer=pathlib.Path(tmp)/'musl-Xray.sh';installer.write_text('# stub')
   ns=namespace(ROOT/'lib/node-manager.py');calls=[]
   ns.update(confirm=lambda *a:True,management_lock=__import__('contextlib').nullcontext,alpine=lambda:True,call=lambda *a,**k:b'',say=lambda *a:None,fresh_cleanup=lambda kind:calls.append(('clean',kind)),managed_run=lambda *a,**k:subprocess.CompletedProcess(a,0),xrestart=lambda:calls.append(('restart',)),xinfo=lambda:None)
   ns['xinstall'](installer);self.assertEqual(calls,[('clean','xray'),('restart',)])
 def test_fresh_cleanup_preserves_other_core_argo_and_cron(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=pathlib.Path(tmp);source=(ROOT/'lib/node-manager.py').read_text()
   for prefix in ('/usr/local/','/usr/bin/','/usr/lib/','/lib/','/etc/','/var/','/run/','/root/','/proc'):
    source=source.replace(prefix,str(root)+prefix)
   ns={'__name__':'test'};exec(source,ns)
   (root/'proc').mkdir()
   for name in ('sing-box','xray'):
    config=root/'etc'/name/'config.json';config.parent.mkdir(parents=True);config.write_text('old')
    binary=root/'usr/local/bin'/name;binary.parent.mkdir(parents=True,exist_ok=True);binary.write_text('old')
   argo=root/'usr/local/lib/vps-node/core';argo.parent.mkdir(parents=True);argo.write_text('keep')
   cert=root/'etc/argo-certificates/shared.key';cert.parent.mkdir(parents=True);cert.write_text('keep')
   service=root/'etc/init.d/third-party-sb';service.parent.mkdir(parents=True);service.write_text('command_args="'+str(root)+'/etc/sing-box/config.json"')
   removed=[];commands=[];stopped=[]
   def call(args,**kw):commands.append((args,kw));return b''
   with unittest.mock.patch('subprocess.run',return_value=subprocess.CompletedProcess([],0,b'* * * * * sync # alpine-node-sync\n0 1 * * * echo unrelated\n',b'')),unittest.mock.patch('shutil.which',return_value='/usr/bin/crontab'):
    ns.update(alpine=lambda:True,call=call,stop_unit=lambda n:stopped.append(n),remove_group=lambda n:removed.append(n))
    ns['fresh_cleanup']('sing-box')
   self.assertFalse((root/'etc/sing-box').exists());self.assertFalse(service.exists())
   self.assertTrue((root/'etc/xray/config.json').exists());self.assertEqual(argo.read_text(),'keep');self.assertEqual(cert.read_text(),'keep')
   self.assertIn('third-party-sb',stopped);self.assertEqual(removed,['sing-box'])
   self.assertEqual(commands[0][1]['input'],b'0 1 * * * echo unrelated\n')
 def test_uninstall_singbox_keeps_argo_and_certificates(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=pathlib.Path(tmp);source=(ROOT/'lib/node-manager.py').read_text()
   for prefix in ('/usr/local/','/usr/bin/','/etc/','/var/','/run/'):source=source.replace(prefix,str(root)+prefix)
   ns={'__name__':'test'};exec(source,ns);ns['ROOT'].mkdir(parents=True)
   ns['CONFIG'].parent.mkdir(parents=True);ns['CONFIG'].write_text('{}');ns['META'].parent.mkdir(parents=True);ns['META'].write_text('{}')
   core=root/'usr/local/bin/sing-box';core.parent.mkdir(parents=True);core.write_text('BINARY')
   argo=root/'usr/local/lib/vps-node/core';argo.parent.mkdir(parents=True);argo.write_text('KEEP ARGO')
   cert=ns['ROOT']/'saved.key';cert.write_text('KEEP CERT')
   removed=[];ns.update(confirm=lambda *a:True,alpine=lambda:False,stop_unit=lambda *a:None,call=lambda *a,**k:b'',remove_group=lambda name:removed.append(name),say=lambda *a:None)
   ns['uninstall_core']('sing-box');self.assertFalse(core.exists());self.assertFalse(ns['CONFIG'].exists());self.assertEqual(removed,['sing-box']);self.assertEqual(argo.read_text(),'KEEP ARGO');self.assertEqual(cert.read_text(),'KEEP CERT')

def legacy_worker(source):
 rows=source.splitlines(keepends=True)
 node=next(n for n in ast.parse(source).body if isinstance(n,ast.FunctionDef) and n.name=='publish_nodes')
 rows[node.lineno-1:node.end_lineno]=[(ROOT/'tests/fixtures/legacy-publication.txt').read_text()]
 return ''.join(rows)
class SharedPublicationTests(unittest.TestCase):
 def test_adapters_and_readiness_functions_unchanged(self):
  def defs(source):return {n.name:ast.dump(n,include_attributes=False) for n in ast.parse(source).body if isinstance(n,ast.FunctionDef)}
  for filename in ('singbox.sh','Encrypt.sh','musl-Xray.sh','install-Xray-core.sh'):
   marker='XRAY_SYNC_PY' if 'Xray' in filename else 'NODE_SYNC_PY';group='xray' if 'Xray' in filename else 'sing-box'
   source=body(ROOT/'installers'/filename,marker);self.assertIn('VPSKIT_SHARED_PUBLICATION',source)
   self.assertNotIn('def link_lines',source);self.assertNotIn('PUBLISH_RUN=',source)
   expected=json.loads((ROOT/'tests/fixtures/readiness-sha256.json').read_text())[filename]
   updated=defs(source)
   for name,digest in expected.items():self.assertEqual(hashlib.sha256(updated[name].encode()).hexdigest(),digest,filename+':'+name)
   with tempfile.TemporaryDirectory() as tmp:
    root=pathlib.Path(tmp);publisher=root/'publisher.py';code=(ROOT/'lib/node-files.py').read_text().replace("'/etc/nodes'",repr(str(root/'nodes'))).replace("'/run/nodes-publication'",repr(str(root/'lock')));publisher.write_text(code)
    adapter=source.replace('/usr/local/lib/argo-node-files/run',str(publisher));ns={'__name__':'test'};exec(adapter,ns)
    with unittest.mock.patch('subprocess.Popen',side_effect=AssertionError('must not spawn Python')):
     ns['publish_nodes']('vless://'+group+'@test:443\n')
    self.assertEqual((root/'nodes'/group/'links.txt').read_text(),'vless://'+group+'@test:443\n')
 def test_concurrent_publish_remove_and_restore(self):
  from concurrent.futures import ThreadPoolExecutor
  with tempfile.TemporaryDirectory() as tmp:
   root=pathlib.Path(tmp);publisher=root/'publisher.py';publisher.write_text((ROOT/'lib/node-files.py').read_text().replace("'/etc/nodes'",repr(str(root/'nodes'))).replace("'/run/nodes-publication'",repr(str(root/'lock'))))
   def publish(group,n):subprocess.run(['python3',str(publisher),'--publish',group],input='vless://'+group+'-'+str(n)+'@test:443\n',text=True,check=True)
   with ThreadPoolExecutor(max_workers=6) as pool:
    futures=[pool.submit(publish,g,n) for n in range(8) for g in ('argo','sing-box','xray')]
    for future in futures:future.result()
   expected=[(root/'nodes'/g/'links.txt').read_text().strip() for g in ('argo','sing-box','xray')];self.assertEqual((root/'nodes/subscription.txt').read_text().splitlines(),expected)
   subprocess.run(['python3',str(publisher),'--remove','xray'],check=True)
   self.assertEqual((root/'nodes/subscription.txt').read_text().splitlines(),expected[:2])
   # Restore only Xray's old link, keeping a concurrently changed Singbox group.
   publish('sing-box',99);subprocess.run(['python3',str(publisher),'--publish','xray'],input=expected[2]+'\n',text=True,check=True)
   self.assertEqual((root/'nodes/subscription.txt').read_text().splitlines(),[expected[0],'vless://sing-box-99@test:443',expected[2]])

if __name__=='__main__':unittest.main(verbosity=2)

class InstallCancelAndPortTests(unittest.TestCase):
 def test_cancel_before_cleanup_or_installer(self):
  with tempfile.TemporaryDirectory() as tmp:
   installer=pathlib.Path(tmp)/'singbox.sh';installer.write_text('# stub')
   ns=namespace(ROOT/'lib/node-manager.py');calls=[]
   ns.update(management_lock=__import__('contextlib').nullcontext,call=lambda *a,**k:b'',say=lambda *a:None,confirm=lambda *a:False,fresh_cleanup=lambda *a:calls.append('cleanup'),managed_run=lambda *a,**k:calls.append('installer'))
   self.assertFalse(ns['fresh_install']('sing-box',installer));self.assertEqual(calls,[])
 def test_ports_independent_and_blank_preserved(self):
  ns=namespace(ROOT/'lib/node-manager.py');targets=[dict(listen='0.0.0.0',listen_port=28282),dict(listen='::',listen_port=38997)]
  labels=[];answers=iter(['30001',''])
  ns.update(prompt=lambda text,**kw:(labels.append(text),next(answers))[1])
  ns['edit_listen_ports'](targets)
  self.assertEqual([t['listen_port'] for t in targets],[30001,38997]);self.assertIn('IPv4',labels[0]);self.assertIn('IPv6',labels[1])
  answers=iter(['0','40002']);ns['say']=lambda *a:None
  ns['edit_listen_ports']([targets[1]]);self.assertEqual(targets[1]['listen_port'],40002)
