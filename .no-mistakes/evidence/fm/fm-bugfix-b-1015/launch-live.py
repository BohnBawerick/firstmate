import os,pathlib,subprocess,sys,time
root=pathlib.Path(sys.argv[1]);w=root/'.test-phase/launch-live';w.mkdir(exist_ok=True)
e={k:v for k,v in os.environ.items() if not k.startswith(('FM_','LAVISH_AXI','TASKS_AXI'))};e.update(TMPDIR=str(root/'.test-phase/runtime'),FM_HOME=str(w/'home'),FM_PROCEVENT_CLAIM_ROOT=str(w/'claims'),LAVISH_AXI_STATE_DIR=str(w/'lavish'),FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS='1')
def run(*a,ok=True):
 r=subprocess.run(['bash',str(root/'bin/fm-procevent.sh'),*a],env=e,cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=12)
 print('$ fm-procevent',' '.join(a),'\n'+r.stdout,'exit=',r.returncode,flush=True)
 if ok:assert r.returncode==0,r.stdout
 return r
subprocess.run(['bash',str(root/'bin/fm-lab-home.sh'),'create',e['FM_HOME']],check=True,stdout=subprocess.DEVNULL)
home=pathlib.Path(e['FM_HOME'])
def count():
 p=home/'state/.wake-queue'
 return sum('launch-failed:' in row for row in p.read_text().splitlines()) if p.exists() else 0
fifo=w/'source.fifo';os.mkfifo(fifo)
run('register','lavish','late-source','--','/bin/cat',str(fifo))
record=home/'state/procevent/late-source.source';good=record.read_text();record.write_text(good.split('argv:\n')[0]+'argv:\n')
r=run('reconcile',ok=False);assert 'failed=1' in r.stdout and count()==0
print('first unconfirmed launch: no launch-failed wake',flush=True)
record.write_text(good)
runner=subprocess.Popen(['bash',str(root/'bin/fm-procevent.sh'),'start','late-source'],env=e,cwd=root,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
try:
 for _ in range(70):
  r=run('list')
  if 'live' in r.stdout:break
  time.sleep(.1)
 assert 'live' in r.stdout
 r=run('reconcile');assert 'failed=0' in r.stdout and count()==0
 print('late listener found live on next cycle: still no launch-failed wake',flush=True)
 with fifo.open('w') as f:f.write('session:\n  status: ended\n  session_ended: true\nprompts[0]:\n')
 runner.wait(timeout=10)
finally:
 if runner.poll() is None:runner.terminate();runner.wait(timeout=5)
run('retire','late-source',ok=False)
run('register','lavish','bad-source','--','/bin/cat',str(fifo))
record=home/'state/procevent/bad-source.source';good=record.read_text();record.write_text(good.split('argv:\n')[0]+'argv:\n')
r=run('reconcile',ok=False);assert 'failed=1' in r.stdout and count()==0
r=run('reconcile',ok=False);assert 'failed=1' in r.stdout and count()==1
r=run('reconcile',ok=False);assert 'failed=1' in r.stdout and count()==1
print((home/'state/.wake-queue').read_text(),flush=True)
run('retire','bad-source');run('sweep-home')
print('LIVE LISTENER SCENARIOS PASSED',flush=True)
