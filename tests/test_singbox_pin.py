import pathlib,re,runpy,subprocess,tempfile,unittest,urllib.parse,hashlib
ROOT=pathlib.Path(__file__).resolve().parents[1]
class SingboxPinTests(unittest.TestCase):
 def test_cert_fingerprint_in_both_workers_and_manager(self):
  with tempfile.TemporaryDirectory() as tmp:
   cert=pathlib.Path(tmp)/'cert.pem';key=pathlib.Path(tmp)/'key.pem'
   subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=test.example','-addext','subjectAltName=DNS:test.example','-addext','basicConstraints=critical,CA:FALSE','-keyout',str(key),'-out',str(cert)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   expected=subprocess.check_output(['openssl','x509','-in',str(cert),'-noout','-fingerprint','-sha256']).decode().strip().split('=')[1].replace(':','').lower()
   cfg={'inbounds':[{'type':'vless','tag':'in-vless-tls','listen':'::','listen_port':23456,'users':[{'uuid':'7bd86e44-7eaf-4815-855d-58079c65ca96'}],'tls':{'enabled':True,'server_name':'test.example','certificate_path':str(cert)}}]}
   meta={'mode':'2','ipv4':'192.0.2.1','ipv6':'2001:db8::1'}
   for filename in ('Encrypt.sh','singbox.sh'):
    code=re.search(r"<<'NODE_SYNC_PY'\n(.*?)\nNODE_SYNC_PY",(ROOT/'installers'/filename).read_text(),re.S).group(1)
    ns={'__name__':'test'};exec(code,ns);ns['country']=lambda ip:''
    link=next(line for line in ns['generate'](cfg,meta).splitlines() if line.startswith('vless://'))
    q=urllib.parse.parse_qs(urllib.parse.urlsplit(link).query)
    self.assertEqual(q['pcs'],[expected]);self.assertEqual(q['allowInsecure'],['0'])
    ns['run']=lambda *a,**k:(_ for _ in ()).throw(RuntimeError('missing cert'))
    with self.assertRaises(RuntimeError):ns['generate'](cfg,meta)
   ns=runpy.run_path(str(ROOT/'lib/node-manager.py'),run_name='test');ns['alpine']=lambda:True;ns['geo']=lambda ip:''
   # runpy function globals remain their original namespace.
   ns['generate_links'].__globals__.update(alpine=lambda:True,geo=lambda ip:'',cert_kind=lambda p:'self')
   q=urllib.parse.parse_qs(urllib.parse.urlsplit(ns['generate_links'](cfg,meta).strip()).query)
   self.assertEqual(q['pcs'],[expected]);self.assertEqual(q['allowInsecure'],['0'])
