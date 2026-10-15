import os,pathlib,subprocess,sys,time,sqlite3,shlex,shutil
root=pathlib.Path(sys.argv[1]); ev=pathlib.Path(__file__).parent
home=root/'.test-phase/nm-fleet'; nm=root/'.test-phase/nm-read'; project=root/'.test-phase/nm-project'
e={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_','CLAUDE_','CLAUDECODE','TASKS_AXI','TMUX'))}
e.update(FM_HOME=str(home),NM_HOME=str(nm),FM_BACKEND='tmux',FM_CREW_STATE_NO_FORGE='1',FM_POLL='1',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_SECONDMATE_LIVENESS_SECS='99999999',FM_STALE_ESCALATE_SECS='2',FM_PAUSE_RESURFACE_SECS='30',FM_TRIAGE_LOG='1')
def run(args,check=True):
 r=subprocess.run(args,cwd=root,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=20)
 if check: assert r.returncode==0,(args,r.stdout)
 return r
shutil.rmtree(home)
run(['bash','bin/fm-lab-home.sh','create',str(home)])
(home/'state/idle.meta').write_text(f'window=firstmate:fm-idle\nworktree={project}\nkind=ship\nharness=codex\nbackend=tmux\n')
sock=run(['bash','bin/fm-lab-home.sh','tmux-dir',str(home)]).stdout.strip();e['TMUX_TMPDIR']=sock
watch=None;log=None
def tm(*a,check=True):return run(['tmux','-L','fm-lab',*a],check)
def read_state():
 r=run(['bash','bin/fm-crew-state.sh','idle']);print(r.stdout.strip(),flush=True);return r.stdout
def launch(label):
 global watch,log
 log=(ev/(label+'.txt')).open('w')
 watch=subprocess.Popen(['bash','bin/fm-watch.sh'],cwd=root,env=e,stdout=log,stderr=subprocess.STDOUT)
def stop():
 global watch,log
 if watch and watch.poll() is None:
  watch.terminate()
  try:watch.wait(timeout=10)
  except subprocess.TimeoutExpired:watch.kill();watch.wait()
 if log:log.close()
 watch=None;log=None
def no_wake(seconds,label):
 start=time.monotonic()
 while time.monotonic()-start<seconds:
  assert watch.poll() is None,(ev/(label+'.txt')).read_text()
  time.sleep(.25)
 q=home/'state/.wake-queue'
 assert not q.exists() or not q.read_text().strip(),q.read_text()
def wait_wake(label):
 try:watch.wait(timeout=40)
 except subprocess.TimeoutExpired:raise AssertionError('watch did not surface: '+(ev/(label+'.txt')).read_text())
 log.flush();text=(ev/(label+'.txt')).read_text();print(text,flush=True);return text
try:
 with sqlite3.connect(nm/'state.sqlite') as db:db.execute("update runs set status='running'")
 tm('new-session','-d','-s','firstmate','-n','fm-idle','-x','120','-y','40','-c',str(root),'codex -c '+shlex.quote('projects."'+str(root)+'".trust_level="trusted"'))
 tm('set-window-option','-t','firstmate:','automatic-rename','off')
 tm('set-window-option','-t','firstmate:','allow-rename','off')
 tm('rename-window','-t','firstmate:','fm-idle')
 e['TMUX']=tm('display-message','-p','-t','firstmate:fm-idle','#{socket_path},#{pid},0').stdout.strip()
 for _ in range(100):
  pane=tm('capture-pane','-p','-t','firstmate:fm-idle').stdout
  if 'Hooks need review' in pane:tm('send-keys','-t','firstmate:fm-idle','3','Enter')
  if 'Tip:' in pane or 'context left' in pane:break
  time.sleep(.25)
 print('Real Codex pane:\n'+pane,flush=True)
 (ev/'watch-codex-pane.txt').write_text(pane)
 (home/'state/idle.status').write_text('working: validation is between steps\n')
 assert 'state: working' in read_state()
 launch('watch-active-run');no_wake(12,'watch-active-run')
 print('Twelve seconds of watcher polls, beyond the two-second wedge threshold: no wake for an active run between steps',flush=True)
 with sqlite3.connect(nm/'state.sqlite') as db:db.execute("update runs set status='cancelled' where id='01NMIDLE0000000000000000000'")
 text=wait_wake('watch-active-run');assert 'stale:' in text and 'possible wedge' in text,text
 print('Once the run stopped, the same idle pane raised a genuine wedge alarm',flush=True)
 stop()
 print('LIVE WATCHER RUN-STATE SCENARIOS PASSED',flush=True)
finally:
 stop();tm('kill-server',check=False)
 run(['bash','bin/fm-lab-home.sh','teardown',str(root/'.test-phase/nm-fleet')],check=False)
