import json, os, pathlib, subprocess, sys, selectors, time
root=pathlib.Path(sys.argv[1]); scratch=root/'.test-phase'
home=scratch/'app-refusal-home'
subprocess.run(['bash',str(root/'bin/fm-lab-home.sh'),'create',str(home)],check=True,stdout=subprocess.DEVNULL)
codehome=scratch/'codex-server-home';codehome.mkdir(exist_ok=True)
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','CLAUDE_','CLAUDECODE'))}
env.update(CODEX_HOME=str(codehome),FM_HOME=str(home))
err=open(scratch/'codex-server.err','w')
p=subprocess.Popen(['codex','app-server','--stdio'],cwd=root,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=err,text=True,bufsize=1)
def rpc(ident,method,params):
    p.stdin.write(json.dumps({'id':ident,'method':method,'params':params})+'\n');p.stdin.flush()
    start=time.monotonic()
    sel=selectors.DefaultSelector();sel.register(p.stdout,selectors.EVENT_READ)
    while time.monotonic()-start<35:
        if not sel.select(1): continue
        line=p.stdout.readline()
        if not line: raise RuntimeError('server closed')
        obj=json.loads(line)
        if obj.get('id')==ident: return obj
    raise TimeoutError(method)
try:
    result=rpc(1,'initialize',{'clientInfo':{'name':'firstmate-live-test','version':'1.0'},'capabilities':{'experimentalApi':True}})
    print('real app-server initialization:',json.dumps(result))
    result=rpc(2,'command/exec',{'command':['bash','bin/fm-lock.sh'],'cwd':str(root),'env':{'FM_HOME':str(home)},'sandboxPolicy':{'type':'dangerFullAccess'},'timeoutMs':10000})
    print('fm-lock through real app-server:',json.dumps(result))
    assert 'no per-thread process' in json.dumps(result),result
    assert not (home/'state/.lock').exists()
    print('lock remains absent after shared app-server refusal')
finally:
    p.terminate()
    try:p.wait(timeout=10)
    except subprocess.TimeoutExpired:p.kill();p.wait()
    err.close()
terminal=scratch/'terminal-lock-home'
subprocess.run(['bash',str(root/'bin/fm-lab-home.sh'),'create',str(terminal)],check=True,stdout=subprocess.DEVNULL)
e=dict(os.environ,FM_HOME=str(terminal))
r=subprocess.run(['bash','bin/fm-lock.sh'],cwd=root,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
print('terminal session:',r.returncode,r.stdout.strip())
assert r.returncode==0 and 'THIS session' in r.stdout
print('LIVE CODEX LOCK SCENARIOS PASSED')
