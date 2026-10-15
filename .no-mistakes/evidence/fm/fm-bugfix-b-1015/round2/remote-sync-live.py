import os,pathlib,shutil,subprocess,sys
root=pathlib.Path(sys.argv[1]);w=root/'.test-phase/sync-live';w.mkdir(exist_ok=True)
e={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI'))};e.update(TMPDIR=str(root/'.test-phase/runtime'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='fixture',GIT_AUTHOR_EMAIL='fixture@example.invalid',GIT_COMMITTER_NAME='fixture',GIT_COMMITTER_EMAIL='fixture@example.invalid')
def run(argv,env=None,check=True):
 r=subprocess.run(argv,cwd=root,env=env or e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=20)
 print('$',' '.join(map(str,argv)),'\n'+r.stdout,'exit=',r.returncode,flush=True)
 if check: assert r.returncode==0,r.stdout
 return r
p=w/'primary';run(['git','init','-q','-b','main',str(p)])
(p/'bin').mkdir();(p/'bin/.keep').touch();shutil.copy2(root/'AGENTS.md',p/'AGENTS.md')
(p/'.gitignore').write_text('state/\ndata/\nconfig/\nprojects/\n.fm-lab-home\n.fm-secondmate-home\n')
(p/'README.md').write_text('fixture\n');run(['git','-C',str(p),'add','.']);run(['git','-C',str(p),'commit','-qm','fixture'])
origin=w/'origin.git';run(['git','clone','-q','--bare',str(p),str(origin)]);run(['git','-C',str(p),'remote','add','origin',str(origin)]);run(['git','-C',str(p),'fetch','-q','origin'])
mate=w/'mate';run(['bash','bin/fm-lab-home.sh','create',str(mate)])
run(['git','-C',str(mate),'init','-q','-b','main']);run(['git','-C',str(mate),'remote','add','origin',str(origin)]);run(['git','-C',str(mate),'fetch','-q','origin']);run(['git','-C',str(mate),'reset','--hard','origin/main'])
(mate/'.fm-secondmate-home').write_text('mate\n')
(p/'README.md').write_text('local change\n');run(['git','-C',str(p),'commit','-qam','local fixture change'])
commit=run(['git','-C',str(p),'rev-parse','HEAD']).stdout.strip()
before=run(['git','-C',str(mate),'rev-parse','HEAD']).stdout.strip()
r=run(['bash','bin/fm-remote-secondmate-control.sh','sync','mate',commit],dict(e,FM_HOME=str(mate)),False)
assert r.returncode!=0 and 'could not import' in r.stdout
reason=run(['bash','-c','. "$1/bin/fm-ff-lib.sh"; remote_sync_failure_reason "$2" "$3" "$4" "$5"','_',str(root),str(r.returncode),r.stdout,commit,str(p)]).stdout
assert 'is on no remote branch this primary knows of' in reason
assert run(['git','-C',str(mate),'rev-parse','HEAD']).stdout.strip()==before
run(['git','-C',str(p),'push','-q','origin','main'])
r=run(['bash','bin/fm-remote-secondmate-control.sh','sync','mate',commit],dict(e,FM_HOME=str(mate)))
assert run(['git','-C',str(mate),'rev-parse','HEAD']).stdout.strip()==commit
print('LIVE REMOTE SYNC DIAGNOSTIC PASSED',flush=True)
