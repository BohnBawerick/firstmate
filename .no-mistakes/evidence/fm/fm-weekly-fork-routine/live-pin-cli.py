import os,pathlib,shutil,subprocess
root=pathlib.Path.cwd(); evidence=pathlib.Path('/home/bohn/.no-mistakes/evidence/01M5SBZKF04BPTHKEM4XDQWAA6'); lab=evidence/'tmp/pin-cli-lab'
env={k:v for k,v in os.environ.items() if not k.startswith('FM_')}; env['FM_HOME']=str(lab)
with (evidence/'live-pin-cli.log').open('w') as log:
 def run(script,*args,code=0):
  p=subprocess.run(['bash',str(root/'bin'/script),*map(str,args)],env=env,capture_output=True,text=True,timeout=20)
  log.write('$ '+script+' '+' '.join(map(str,args))+'\n'+p.stdout+p.stderr+f'exit: {p.returncode}\n'); log.flush(); assert p.returncode==code,(p.returncode,p.stdout,p.stderr); return p.stdout
 try:
  run('fm-lab-home.sh','create',lab)
  cfg=lab/'config'; (cfg/'crew-harness').write_text('pi\n'); (cfg/'secondmate-harness').write_text('claude sonnet high\nmate mac: opencode model low\n'); (cfg/'secondmate-harness.d').mkdir(); per=cfg/'secondmate-harness.d/mac'; per.write_text('codex gpt-6.1-sol xhigh\n')
  for expected in [('codex','gpt-6.1-sol','xhigh'),('opencode','model','low'),('claude','sonnet','high'),('pi','','')]:
   values=tuple(run('fm-harness.sh',verb,'mac').strip() for verb in ['secondmate','secondmate-model','secondmate-effort']); assert values==expected,(values,expected)
   if per.exists(): per.unlink()
   elif (cfg/'secondmate-harness').exists() and 'mate mac' in (cfg/'secondmate-harness').read_text(): (cfg/'secondmate-harness').write_text('claude sonnet high\n')
   elif (cfg/'secondmate-harness').exists(): (cfg/'secondmate-harness').unlink()
  (cfg/'secondmate-harness').write_text('claude\nmate mac: codex\nbad syntax extra tokens here\n')
  for verb in ['secondmate','secondmate-model','secondmate-effort']: assert run('fm-harness.sh',verb,'mac',code=1)==''
  run('fm-harness.sh','secondmate','../bad',code=2)
  (cfg/'secondmate-harness').unlink(); (cfg/'claude-account').write_text('/does-not-exist/pinned-account\n')
  project=lab/'project'; project.mkdir(); subprocess.run(['git','init','-q',str(project)],check=True)
  p=subprocess.run(['bash',str(root/'bin/fm-spawn.sh'),'pin-refusal',str(project),'--harness','claude --print raw','--scout'],env=env,capture_output=True,text=True,timeout=20)
  log.write('$ fm-spawn.sh pin-refusal <isolated-project> --harness "claude --print raw" --scout\n'+p.stdout+p.stderr+f'exit: {p.returncode}\n'); log.flush()
  assert p.returncode==1 and 'raw launch commands are unsupported' in p.stderr+p.stdout,(p.returncode,p.stdout,p.stderr)
  assert not (lab/'state/pin-refusal.meta').exists()
  print('PASS: secondmate file, inline, shared, and crew precedence; malformed pins and ids refuse; raw pinned launch refuses before task publication')
 finally: shutil.rmtree(lab,ignore_errors=True)
