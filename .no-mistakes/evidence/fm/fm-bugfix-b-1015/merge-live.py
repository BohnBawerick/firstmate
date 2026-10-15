import json,os,pathlib,socketserver,ssl,subprocess,sys,threading
root=pathlib.Path(sys.argv[1]);w=root/'.test-phase/merge-live';w.mkdir(exist_ok=True)
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','GH_','GITHUB_','TASKS_AXI'))}
env.update(TMPDIR=str(root/'.test-phase/runtime'),GH_CONFIG_DIR=str(w/'gh-config'),XDG_CACHE_HOME=str(w/'cache'),GH_TOKEN='disposable-local-endpoint-token',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='fixture',GIT_AUTHOR_EMAIL='fixture@example.invalid',GIT_COMMITTER_NAME='fixture',GIT_COMMITTER_EMAIL='fixture@example.invalid')
home=w/'home';subprocess.run(['bash','bin/fm-lab-home.sh','create',str(home)],env=env,cwd=root,check=True,stdout=subprocess.DEVNULL);env['FM_HOME']=str(home)
project=w/'project';subprocess.run(['git','init','-q','-b','task',str(project)],check=True,env=env)
subprocess.run(['git','-C',str(project),'commit','-q','--allow-empty','-m','fixture'],check=True,env=env)
head=subprocess.check_output(['git','-C',str(project),'rev-parse','HEAD'],text=True).strip()
subprocess.run(['git','-C',str(project),'update-ref','refs/remotes/origin/task',head],check=True)
(home/'state/task.meta').write_text(f'window=fixture:task\nworktree={project}\nproject={project}\nkind=ship\nmode=direct-PR\n')
state={'base':'release','default':'main','merged':False,'mutations':0,'default_readable':True}
def pr():
 r={'id':'PR_disposable','number':1,'title':'fixture','body':'fixture','url':'https://github.com/lab/disposable/pull/1','state':'MERGED' if state['merged'] else 'OPEN','closed':state['merged'],'isDraft':False,'mergeable':'MERGEABLE','mergeStateStatus':'CLEAN','headRefOid':head,'headRefName':'task','baseRefName':state['base'],'merged':state['merged'],'isInMergeQueue':False,'isCrossRepository':False,'maintainerCanModify':True,'mergeQueueEntry':None,'mergedAt':'2026-10-16T00:00:00Z' if state['merged'] else None,'headRepositoryOwner':{'login':'lab'},'author':{'login':'fixture'},'commits':{'nodes':[{'commit':{'oid':head,'statusCheckRollup':{'contexts':{'nodes':[],'pageInfo':{'hasNextPage':False,'endCursor':None}}}}}]},'reviews':{'nodes':[]},'labels':{'nodes':[]},'statusCheckRollup':[]}
 for key in ('headRepository','baseRepository'):r[key]={'id':'R_disposable','name':'disposable','nameWithOwner':'lab/disposable','owner':{'login':'lab'},'defaultBranchRef':{'name':'main'}}
 r['statusCheckRollup']=r['commits']
 return r
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(root/'.test-phase/forge.crt',root/'.test-phase/forge.key')
class Handler(socketserver.StreamRequestHandler):
 def handle(self):
  try:
   line=self.rfile.readline().decode()
   if not line.startswith('CONNECT api.github.com:443 '):raise ValueError('unexpected outbound endpoint '+line)
   while self.rfile.readline().strip():pass
   self.wfile.write(b'HTTP/1.1 200 Connection established\r\n\r\n');self.wfile.flush()
   conn=ctx.wrap_socket(self.connection,server_side=True);f=conn.makefile('rb')
   method,path,_=f.readline().decode().split();headers={}
   while row:=f.readline().decode().strip():
    k,v=row.split(':',1);headers[k.lower()]=v.strip()
   body=f.read(int(headers.get('content-length','0')))
   print('local forge request:',method,path,flush=True)
   code=200;data={}
   if path=='/graphql':
    request=json.loads(body);query=request.get('query','')
    print('GraphQL:',query,flush=True)
    if '__type(' in query:
     keys=['WorkflowRun'] if 'fields2' in query else ['PullRequest','StatusCheckRollupContextConnection']
     data={'data':{key:{'fields':[{'name':name} for name in ['isInMergeQueue','mergeStateStatus','nodes','workflow']]} for key in keys}}
    elif 'mutation' in query:
     state['mutations']+=1;state['merged']=True
     data={'data':{'mergePullRequest':{'clientMutationId':None}}}
    else:data={'data':{'repository':{'id':'R_disposable','name':'disposable','owner':{'login':'lab'},'defaultBranchRef':{'name':state['default']},'pullRequest':pr()},'viewer':{'login':'fixture'}}}
   elif path=='/repos/lab/disposable':
    if state['default_readable']:data={'default_branch':state['default']}
    else:code=500;data={'message':'disposable unreadable default'}
   elif '/rules/branches/' in path:data=[]
   elif '/branches/' in path:data={'name':state['base'],'protected':False,'protection':{'enabled':False,'required_status_checks':{'contexts':[],'checks':[]}}}
   elif '/check-runs' in path:data={'total_count':0,'check_runs':[]}
   elif '/actions/runs' in path:data={'total_count':0,'workflow_runs':[]}
   else:code=404;data={'message':'unsupported disposable endpoint'}
   raw=json.dumps(data).encode();conn.sendall(f'HTTP/1.1 {code} OK\r\nContent-Type: application/json\r\nContent-Length: {len(raw)}\r\nConnection: close\r\n\r\n'.encode()+raw);conn.close()
  except Exception as error:print('local forge transport:',str(error),flush=True)
class Server(socketserver.ThreadingTCPServer):allow_reuse_address=True;daemon_threads=True
server=Server(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
env.update(HTTPS_PROXY='http://127.0.0.1:'+str(server.server_address[1]),HTTP_PROXY='http://127.0.0.1:'+str(server.server_address[1]),NO_PROXY='',SSL_CERT_FILE=str(root/'.test-phase/forge.crt'),PATH='/home/bohn/.local/share/mise/installs/gh/latest/gh_2.102.0_linux_amd64/bin:'+os.environ['PATH'])
def merge(name,*flags):
 r=subprocess.run(['bash','bin/fm-pr-merge.sh','task','https://github.com/lab/disposable/pull/1',*flags],cwd=root,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=25)
 print(name,': exit=',r.returncode,'\n'+r.stdout,flush=True);return r
try:
 debug=subprocess.run(['gh','pr','view','https://github.com/lab/disposable/pull/1','--json','state,isDraft,mergeable,mergeStateStatus,headRefOid,baseRefName,statusCheckRollup'],env=env,cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);print('real gh probe:',debug.returncode,debug.stdout,flush=True)
 r=merge('side-branch-refused');assert r.returncode and 'base branch is "release"' in r.stdout and state['mutations']==0
 r=merge('mismatched-waiver-refused','--allow-base','other');assert r.returncode and 'base branch is "release"' in r.stdout and state['mutations']==0
 state['default_readable']=False;r=merge('unreadable-default-refused');assert r.returncode and 'default branch could not be read' in r.stdout and state['mutations']==0
 state['default_readable']=True
 subprocess.run(['bash','bin/fm-afk-contract.sh','enter','--words','Disposable test mandate'],cwd=root,env=env,check=True,stdout=subprocess.DEVNULL);r=merge('away-waiver-refused','--allow-base','release');assert r.returncode and 'attended-only' in r.stdout and state['mutations']==0
 (home/'state/.afk-contract').unlink()
 r=merge('exact-waiver','--allow-base','release');assert not r.returncode and state['mutations']==1
 other=w/'default-home'
 subprocess.run(['bash','bin/fm-lab-home.sh','create',str(other)],cwd=root,env=env,check=True,stdout=subprocess.DEVNULL)
 (other/'state/task.meta').write_text((home/'state/task.meta').read_text())
 env['FM_HOME']=str(other);state.update(base='main',merged=False,mutations=0)
 r=merge('default-base-without-waiver');assert not r.returncode and state['mutations']==1
 print('LIVE MERGE GUARD SCENARIOS PASSED',flush=True)
finally:server.shutdown();server.server_close()
