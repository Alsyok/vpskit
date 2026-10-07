#!/usr/bin/env python3
"""Only migrate publication; preserve config parsing, readiness checks and protocols."""
import ast,contextlib,fcntl,os,pathlib,subprocess,tempfile
PUBLISHER='/usr/local/lib/argo-node-files/run'
def adapter(group):
    if group not in ('sing-box','xray'):raise RuntimeError('未知节点组')
    return "def publish_nodes(content):\n    # VPSKIT_SHARED_PUBLICATION\n    import runpy\n    runpy.run_path("+repr(PUBLISHER)+",run_name='vpskit_publication')['publish']("+repr(group)+",content)\n"
def upgrade(source,group):
    tree=ast.parse(source);functions={n.name:n for n in tree.body if isinstance(n,ast.FunctionDef)}
    if not all(n in functions for n in ('sync','main','generate')):raise RuntimeError('未知同步程序，未修改')
    if 'publish_nodes' not in functions:raise RuntimeError('旧程序缺少发布入口，请先升级配置管理程序')
    # Refuse arbitrary custom exporters that use the fields elsewhere.
    remove=[functions['publish_nodes']]
    if 'link_lines' in functions:remove.append(functions['link_lines'])
    for n in tree.body:
        if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id in ('NODES','PUBLISH_RUN') for t in n.targets):remove.append(n)
    removed={id(n) for n in remove}
    for n in tree.body:
        if id(n) not in removed and any(isinstance(item,ast.Name) and item.id in ('NODES','PUBLISH_RUN','link_lines') for item in ast.walk(n)):raise RuntimeError('检测到自定义发布依赖，未修改')
    rows=source.splitlines(keepends=True)
    for n in sorted(remove,key=lambda n:n.lineno,reverse=True):
        rows[n.lineno-1:n.end_lineno]=[adapter(group)] if n is functions['publish_nodes'] else []
    result=''.join(rows);compile(result,'upgraded sync','exec');return result

def atomic(path,data):
    p=pathlib.Path(path);fd,name=tempfile.mkstemp(dir=p.parent)
    try:
        os.fchmod(fd,0o700)
        with os.fdopen(fd,'w') as f:f.write(data);f.flush();os.fsync(f.fileno())
        os.replace(name,p)
    finally:
        if os.path.exists(name):os.unlink(name)
WORKERS=(('/usr/local/lib/singbox-node-sync/run','sing-box'),('/usr/local/lib/alpine-node-sync/run','sing-box'),('/usr/local/lib/argo-standalone/node-sync.py','sing-box'),('/usr/local/lib/xray-node-sync/run','xray'))
def migrate_installed():
    plans=[];watchers=[]
    for filename,group in WORKERS:
        path=pathlib.Path(filename)
        if not path.exists():continue
        if path.is_symlink():raise RuntimeError('同步程序是符号链接，未修改')
        source=path.read_text()
        marker="'/run/singbox-node-sync'" if group=='sing-box' else "'/run/xray-node-sync'"
        if marker not in source:raise RuntimeError('同步程序来源不匹配，未修改：'+filename)
        result=upgrade(source,group)
        if source!=result:plans.append((path,source,result,group))
    if not plans:return
    # No core restart. These two services only watch for link changes.
    for name,filename in (('alpine-node-sync','/usr/local/lib/alpine-node-sync/run'),('argo-sb-sync','/usr/local/lib/argo-standalone/node-sync.py')):
        if pathlib.Path('/etc/init.d',name).exists() and any(str(p)==filename for p,_,_,_ in plans):
            if subprocess.run(['rc-service',name,'status'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0:watchers.append(name)
    touched=[]
    # Hold worker locks in a fixed order until every file is replaced.
    with contextlib.ExitStack() as stack:
        for group in sorted({g for _,_,_,g in plans}):
            folder=pathlib.Path('/run/singbox-node-sync' if group=='sing-box' else '/run/xray-node-sync');folder.mkdir(parents=True,exist_ok=True);folder.chmod(0o700)
            f=stack.enter_context(open(folder/'lock','a'));fcntl.flock(f,fcntl.LOCK_EX)
        try:
            for path,source,result,_ in plans:
                if path.read_text()!=source:raise RuntimeError('同步程序同时被修改，请重试')
                backup=path.with_name(path.name+'.before-shared-publication')
                if not backup.exists():atomic(backup,source)
                touched.append((path,source));atomic(path,result)
        except BaseException:
            for path,source in reversed(touched):atomic(path,source)
            raise
    try:
        for name in watchers:subprocess.run(['rc-service',name,'restart'],check=True)
    except BaseException:
        for path,source in touched:atomic(path,source)
        for name in watchers:subprocess.run(['rc-service',name,'restart'],check=False)
        raise RuntimeError('同步服务升级失败，已恢复原程序')
    print('公共发布入口已更新；节点核心和配置保持原样。')
if __name__=='__main__':
    import sys
    try:migrate_installed()
    except Exception as e:print('同步升级失败：'+str(e),file=sys.stderr);sys.exit(1)
