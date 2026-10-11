import contextlib,copy,json,pathlib,subprocess,tempfile,unittest,unittest.mock
from test_vpskit import namespace,body,ROOT
class SmoothTests(unittest.TestCase):
 def test_uninstall_without_ownership_record(self):
  ns=namespace(ROOT/'lib/node-manager.py');calls=[]
  ns.update(management_lock=contextlib.nullcontext,alpine=lambda:True,confirm=lambda *a:True,say=lambda *a:None,fresh_cleanup=lambda kind:calls.append(kind))
  ns['uninstall_core']('sing-box');ns['uninstall_core']('xray');self.assertEqual(calls,['sing-box','xray'])
 def test_lego_uses_capabilities_not_version(self):
  ns=namespace(ROOT/'lib/node-manager.py')
  ns['call']=lambda args,**kw:b'--path --email --domains --accept-tos --http --http.address --renew-days --dns'
  with tempfile.TemporaryDirectory() as tmp:
   args=ns['lego_command']('lego',pathlib.Path(tmp),dict(email='a@b.c',domain='example.com',method='http'))
  self.assertEqual(args[:2],['lego','run']);self.assertIn('--http.address',args)
  ns['call']=lambda args,**kw:b'no usable options'
  with self.assertRaises(ns['Error']):ns['lego_command']('lego',pathlib.Path('/unused'),dict(email='a@b.c',domain='example.com',method='http'))
 def test_web_service_restored_on_failure(self):
  ns=namespace(ROOT/'lib/node-manager.py');calls=[];checks=[False,True]
  def check(row):
   if not checks.pop(0):raise ns['Error']('80 occupied')
  def fail(*a,**k):raise ns['Error']('CA failed')
  ns.update(management_lock=contextlib.nullcontext,http_check=check,choose=lambda text,*a:'4' if '改用' in text else '1',confirm=lambda *a:True,alpine=lambda:False,say=lambda *a:None,item=lambda *a:None,client_issue_impl=fail,call=lambda args,**kw:calls.append(args))
  with unittest.mock.patch('sys.stdin.isatty',return_value=True),unittest.mock.patch('subprocess.run',side_effect=lambda args,**kw:subprocess.CompletedProcess(args,0 if args[-1]=='nginx' else 1)):
   with self.assertRaises(ns['Error']):ns['client_issue'](dict(method='http'))
  self.assertEqual(calls,[['systemctl','stop','nginx'],['systemctl','start','nginx']])
 def test_xray_cert_modes_are_independent(self):
  for name in ('musl-Xray.sh','install-Xray-core.sh'):
   ns={'__name__':'test'};exec(body(ROOT/'installers'/name,'XRAY_SYNC_PY'),ns)
   ns.update(country=lambda ip:'',run=lambda *a,**kw:b'certificate DER')
   nodes=[]
   for host,cert,port in [('one.example','/one.pem',443),('two.example','/two.pem',8443)]:
    nodes.append(dict(protocol='vless',port=port,settings=dict(clients=[dict(id='7bd86e44-7eaf-4815-855d-58079c65ca96')]),streamSettings=dict(security='tls',tlsSettings=dict(serverName=host,certificates=[dict(certificateFile=cert,keyFile='/key')]))))
   links,_=ns['generate'](dict(inbounds=nodes),dict(ip='192.0.2.1',domain_mode=False,certificate_modes={'/one.pem':True}))
   self.assertIn('@one.example:443',links);self.assertIn('@192.0.2.1:8443',links)
 def test_different_ipv4_ipv6_user_lists(self):
  ns=namespace(ROOT/'lib/node-manager.py');seen=[]
  nodes=[dict(type='hysteria2',listen='0.0.0.0',listen_port=1234,users=[dict(password='a')],tls=dict(server_name='one.example')),dict(type='hysteria2',listen='::',listen_port=2345,users=[dict(password='b'),dict(password='c')],tls=dict(server_name='two.example'))]
  with tempfile.TemporaryDirectory() as tmp:
   config=pathlib.Path(tmp)/'config';config.write_text(json.dumps(dict(inbounds=nodes)))
   ns.update(CONFIG=config,fresh_sync_source=lambda:'',config=lambda:dict(inbounds=copy.deepcopy(nodes)),select_inbounds=lambda *a:[0,1],title=lambda *a:None,say=lambda *a:None,item=lambda *a:None,choose=lambda *a:'2',group_input=lambda label,values,*a,**k:seen.append(values),edit_listen_ports=lambda *a:None,select_certificate=lambda *a:None,check_certificate=lambda *a,**k:None,cert_kind=lambda *a:'formal',confirm=lambda *a:False)
   for node in nodes:node['tls'].update(certificate_path='/cert',key_path='/key')
   ns['edit_node']('hy2')
  self.assertEqual(seen[0],['a','c'])
 def test_http_shell_guard_restores_after_failed_issuance(self):
  source=(ROOT/'lib/http-guard.sh').read_text()
  with tempfile.TemporaryDirectory() as tmp:
   log=pathlib.Path(tmp)/'calls';flag=pathlib.Path(tmp)/'paused'
   code=f'''ss() {{ [ -f '{flag}' ] || printf 'LISTEN 0 128 0.0.0.0:80 0.0.0.0:*\\n'; }}
rc-service() {{ case "$2" in status) [ "$1" = nginx ];; stop) touch '{flag}'; echo stop >>'{log}';; start) echo start >>'{log}';; esac; }}
fail() {{ return 7; }}
'''+source+'\nvpskit_http_run fail\n'
   result=subprocess.run(['bash','-c',code],input='2\ny\n',text=True,capture_output=True)
   self.assertEqual(result.returncode,7,result.stderr);self.assertEqual(log.read_text().splitlines(),['stop','start'])
 def test_failed_apt_source_requires_confirmation_and_preserves_file(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=pathlib.Path(tmp);directory=root/'sources.list.d';directory.mkdir();source=directory/'bad.list';original='deb https://broken.example/repo stable main\n';source.write_text(original)
   helper=(ROOT/'lib/apt-retry.sh').read_text().replace('/etc/apt/sources.list.d/',str(directory)+'/').replace('/etc/apt/sources.list',str(root/'sources.list'))
   stub=f'''apt-get() {{ if [ -f '{source}' ]; then printf 'Err:4 https://broken.example/repo stable InRelease\\nE: Failed to fetch https://broken.example/repo/InRelease 402 Payment Required\\n'; return 1; fi; return 0; }}\n'''
   result=subprocess.run(['bash','-c',stub+helper+'\nvpskit_apt_update\n'],input='2\n1\nYES\n',text=True,capture_output=True,timeout=5)
   self.assertEqual(result.returncode,0,result.stderr);self.assertFalse(source.exists());self.assertEqual(next(directory.glob('*.vpskit-disabled-*')).read_text(),original)
 def test_failed_dependency_preflight_preserves_existing_installation(self):
  ns=namespace(ROOT/'lib/node-manager.py');calls=[]
  with tempfile.TemporaryDirectory() as tmp:
   source=pathlib.Path(tmp)/'singbox.sh';source.write_text('# fake installer')
   ns.update(management_lock=contextlib.nullcontext,say=lambda *a:None,call=lambda *a,**k:b'',confirm=lambda *a:True,fresh_cleanup=lambda *a:calls.append('cleanup'),managed_run=lambda *a,**k:subprocess.CompletedProcess(a,1))
   with self.assertRaises(ns['Error']):ns['fresh_install']('sing-box',source)
  self.assertEqual(calls,[])
 def test_certificate_binding_failure_restores_both_cores(self):
  ns=namespace(ROOT/'lib/node-manager.py')
  with tempfile.TemporaryDirectory() as tmp:
   root=pathlib.Path(tmp);ns.update(CONFIG=root/'sb',XCONFIG=root/'x',XSTATE=root/'meta',management_lock=contextlib.nullcontext,say=lambda *a:None,check_certificate=lambda *a,**k:None,initialize_sync=lambda:None)
   old=dict(cert='/old',key='/old-key');new=dict(cert='/new',key='/new-key',domain='new.example',kind='formal')
   sb=dict(inbounds=[dict(tls=dict(certificate_path='/old',key_path='/old-key',server_name='old.example'))]);x=dict(inbounds=[dict(streamSettings=dict(tlsSettings=dict(serverName='old.example',certificates=[dict(certificateFile='/old',keyFile='/old-key')])) )])
   ns['CONFIG'].write_text(json.dumps(sb));xbytes=json.dumps(x).encode();ns['XCONFIG'].write_bytes(xbytes);ns['XSTATE'].write_text('{}')
   ns['commit_config']=lambda config,original:ns['CONFIG'].write_text(json.dumps(config))
   calls=[]
   def restart():
    calls.append(1)
    if len(calls)==1:raise ns['Error']('reload failed')
   ns['xrestart']=restart
   with self.assertRaises(ns['Error']):ns['replace_certificate_bindings'](old,new)
   self.assertEqual(json.loads(ns['CONFIG'].read_text()),sb);self.assertEqual(ns['XCONFIG'].read_bytes(),xbytes);self.assertEqual(ns['XSTATE'].read_text(),'{}');self.assertEqual(len(calls),2)
 def test_unknown_protocol_does_not_publish_obsolete_link(self):
  for name in ('musl-Xray.sh','install-Xray-core.sh'):
   ns={'__name__':'test'};exec(body(ROOT/'installers'/name,'XRAY_SYNC_PY'),ns);ns.update(country=lambda ip:'',run=lambda *a,**kw:b'DER')
   valid=dict(protocol='vless',port=443,settings=dict(clients=[dict(id='7bd86e44-7eaf-4815-855d-58079c65ca96')]),streamSettings=dict(security='tls',tlsSettings=dict(serverName='test.example',certificates=[dict(certificateFile='/cert')])) )
   unknown=dict(protocol='other',port=8443)
   text,ports=ns['generate'](dict(inbounds=[unknown,valid]),dict(ip='192.0.2.1',domain_mode=False))
   self.assertEqual(ports,[443]);self.assertEqual(len(text.splitlines()),1)
   with self.assertRaises(RuntimeError):ns['generate'](dict(inbounds=[unknown]),dict(ip='192.0.2.1',domain_mode=False))
  ns=namespace(ROOT/'lib/node-manager.py')
  with self.assertRaises(ns['Error']):ns['generate_links'](dict(inbounds=[dict(type='mixed')]),{})
 def test_supported_listener_validation_is_retained(self):
  for name in ('singbox.sh','Encrypt.sh'):
   ns={'__name__':'test'};source=body(ROOT/'installers'/name,'NODE_SYNC_PY')
   with tempfile.TemporaryDirectory() as tmp:
    source=source.replace("'/proc'",repr(tmp));exec(source,ns)
    fd=pathlib.Path(tmp)/'42/fd';fd.mkdir(parents=True)
    unknown=dict(type='mixed',listen_port=9999)
    ns['listens'](42,dict(inbounds=[unknown]))
    for kind in ('vless','hysteria2'):
     with self.assertRaises(RuntimeError):ns['listens'](42,dict(inbounds=[unknown,dict(type=kind,listen_port=443)]))
