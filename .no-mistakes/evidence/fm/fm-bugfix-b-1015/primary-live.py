import os,pathlib,shlex,subprocess,sys,time
root=pathlib.Path(sys.argv[1]);evidence=pathlib.Path(__file__).parent
home=root/'.test-phase/primary-live-home'
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','FMX_','HERDR_','CLAUDE_','CLAUDECODE','TASKS_AXI'))}
env.update(TMPDIR=str(root/'.test-phase/runtime'),FM_HERDR_LAB_STATE_DIR=str(root/'.test-phase/herdr-state'),PATH='/home/bohn/.local/share/mise/installs/claude/latest:/usr/bin:/bin')
def helper(*args):
 r=subprocess.run(['bash',str(root/'bin/fm-herdr-lab.sh'),*args],cwd=root,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=70)
 if r.returncode: raise RuntimeError(r.stdout)
 return r.stdout
subprocess.run(['bash',str(root/'bin/fm-lab-home.sh'),'create',str(home)],check=True,env=env,stdout=subprocess.DEVNULL)
session=helper('name','primary-proof').strip()
try:
 helper('provision',session)
 import json
 pane=json.loads(helper('run',session,'workspace','create','--cwd',str(root),'--label','primary-proof','--no-focus'))['result']['root_pane']['pane_id']
 cmd=['env','FM_HOME='+str(home),'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false','CLAUDE_CODE_SEND_FEEDBACK=0','claude','-p','Run exactly this command with Bash and then stop: bash '+str(evidence/'primary-probe.sh')+' '+str(root)+' '+str(home),'--model','haiku','--dangerously-skip-permissions','--setting-sources','','--no-session-persistence','--tools','Bash','--system-prompt','Execute the requested command with Bash. Do not run other commands.','--output-format','stream-json','--verbose']
 shell=shlex.join(cmd)+' > '+shlex.quote(str(evidence/'primary-model.jsonl'))+' 2>&1; echo $? > '+shlex.quote(str(home/'finished'))
 helper('run',session,'pane','run',pane,shell)
 for _ in range(180):
  if (home/'finished').exists():break
  time.sleep(1)
 print(helper('run',session,'pane','read',pane,'--source','recent','--lines','100'))
 print('primary model exited:',(home/'finished').read_text() if (home/'finished').exists() else 'timed out')
 print((evidence/'primary-model.jsonl').read_text())
 assert 'LIVE PRIMARY SCENARIOS PASSED' in (evidence/'primary-model.jsonl').read_text()
finally:
 print(helper('teardown',session))
