import pathlib,os,subprocess,sys,shutil,json,hashlib
root=pathlib.Path(sys.argv[1]);w=root/'.test-phase/hash-live';w.mkdir(exist_ok=True)
e={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI','CLAUDE_'))}
e.update(TMPDIR=str(root/'.test-phase/runtime'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
b=w/'bin';b.mkdir()
for tool in ['bash','env','dirname','basename','mktemp','date','jq','awk','sed','wc','cat','rm','mkdir','rmdir','git','head','tail','stat','tr','sort','cut','cmp','mv','chmod','touch','sleep','ps','readlink','perl','python3','tmux','node','timeout','find','grep','ls','cp','printf','id','uname','kill','sha256sum','claude','tasks-axi','xargs','paste','true','tee','ln','od','pkill','pgrep','setsid']:
 p=shutil.which(tool)
 if p:(b/tool).symlink_to(p)
e['PATH']=str(b)
def run(args,env=None):
 r=subprocess.run(args,cwd=root,env=env or e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
 print('$',' '.join(args),'\nexit=',r.returncode,'\n'+r.stdout,flush=True);return r
url='https://github.com/lab/disposable/pull/1';token='comment:12'
def home(name):
 h=w/name;run(['bash','bin/fm-lab-home.sh','create',str(h)])
 (h/'data/hash').mkdir();(h/'config/backlog-backend').write_text('manual\n');(h/'data/backlog.md').write_text('# Backlog\n\n## Queued\n')
 record={'schema':'fm-contributions.v1','task':'hash','records':[{'url':url,'kind':'pr','checked_at':'2026-10-16T00:00:00Z','error':None,'pending':[{'token':token}],'seen':[token],'notified':[],'verdict':None,'observation':{'head':'a'*40,'state':'merged','draft':False,'mergeable':'mergeable','can_merge':False,'review_decision':'','checks':[],'reviews':[],'events':[]}}]}
 (h/'data/hash/contributions.json').write_text(json.dumps(record));return h
h=home('fallback');en=dict(e,FM_HOME=str(h))
r=run(['bash','bin/fm-contributions.sh','poll'],en);assert r.returncode==0
q=(h/'state/.wake-queue').read_text();print(q,flush=True)
expected=hashlib.sha256((url+'\n'+token+'\n').encode()).hexdigest();assert '\tcontribution-'+expected+'\t' in q
r=run(['bash','bin/fm-contributions.sh','poll'],en);assert r.returncode==0 and (h/'state/.wake-queue').read_text()==q
print('sha256sum-only contribution wake has the exact digest and deduplicates',flush=True)
user=w/'user';(user/'.pi/agent').mkdir(parents=True);(user/'.pi/agent/trust.json').write_text('{}\n');(user/'.claude.json').write_text('{}\n')
en=dict(e,HOME=str(user));lab=w/'partial-lab'
r=run(['bash','bin/fm-live-lab.sh','up','--harness','claude','--source',str(w/'missing-origin'),str(lab)],en)
assert r.returncode!=0 and (lab/'.fm-live-lab').exists(),r.stdout
r=run(['bash','bin/fm-live-lab.sh','down',str(lab)],en);assert r.returncode==0 and not lab.exists()
print('sha256sum-only lab prepares and tears down a partial launch',flush=True)
(b/'sha256sum').unlink()
h=home('no-hash');r=run(['bash','bin/fm-contributions.sh','poll'],dict(e,FM_HOME=str(h)))
assert r.returncode!=0 and 'shasum or sha256sum is required' in r.stdout,r.stdout
r=run(['bash','bin/fm-live-lab.sh','up','--harness','claude','--source',str(w/'missing-origin'),str(w/'refused-lab')],en)
assert r.returncode!=0 and 'shasum or sha256sum is required' in r.stdout and not (w/'refused-lab').exists(),r.stdout
print('Missing both hash tools refuses by name before a lab launch',flush=True)
print('LIVE HASH SCENARIOS PASSED',flush=True)
