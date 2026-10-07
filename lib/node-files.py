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
