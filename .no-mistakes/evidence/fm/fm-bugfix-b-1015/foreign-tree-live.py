import os,pathlib,shlex,subprocess,json,time,sys
root=pathlib.Path(sys.argv[1]);evidence=pathlib.Path(__file__).parent;home=root/'.test-phase/foreign-tree-home'
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','FMX_','HERDR_','CLAUDE_','CLAUDECODE','TASKS_AXI'))};env.update(TMPDIR=str(root/'.test-phase/runtime'),FM_HERDR_LAB_STATE_DIR=str(root/'.test-phase/herdr-state'),PATH='/home/bohn/.local/share/mise/installs/claude/latest:/usr/bin:/bin')
def helper(*a):
 r=subprocess.run(['bash',str(root/'bin/fm-herdr-lab.sh'),*a],cwd=root,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=70);assert r.returncode==0,r.stdout;return r.stdout
subprocess.run(['bash',str(root/'bin/fm-lab-home.sh'),'create',str(home)],check=True,env=env,stdout=subprocess.DEVNULL)
session=helper('name','foreign-tree').strip()
try:
 helper('provision',session);pane=json.loads(helper('run',session,'workspace','create','--cwd',str(root),'--label','foreign-tree','--no-focus'))['result']['root_pane']['pane_id']
 command=f'bash {root}/bin/fm-lock.sh && touch {home}/ready && sleep 20'
 prompt='Run exactly this Bash command and then stop: '+command
 args=['env','FM_HOME='+str(home),'claude','-p',prompt,'--model','haiku','--dangerously-skip-permissions','--setting-sources','','--no-session-persistence','--tools','Bash','--system-prompt','Execute the requested command with Bash. Do not run other commands.']
 helper('run',session,'pane','run',pane,shlex.join(args)+' > '+str(evidence/'foreign-tree-holder.log')+' 2>&1')
 for _ in range(120):
  if (home/'ready').exists():break
  time.sleep(.25)
 assert (home/'ready').exists()
 owner=(home/'state/.lock').read_text().strip()
 e=dict(env,FM_HOME=str(home),FM_SUPERVISION_ACTOR='branch',FM_LEASE_HOLDER_PID=owner)
 result=subprocess.run(['bash',str(root/'bin/fm-wake-drain.sh')],env=e,cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 print('Real primary owner:',owner,'\nForged branch outside its process tree: exit=',result.returncode,'\n'+result.stdout,flush=True)
 assert result.returncode!=0 and 'does not hold the fleet lock' in result.stdout
 assert (home/'state/.lock').read_text().strip()==owner
 print('LIVE FOREIGN-TREE REFUSAL PASSED',flush=True)
finally:helper('teardown',session)
