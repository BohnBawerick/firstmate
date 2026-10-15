import os, subprocess, tempfile, shutil
from pathlib import Path
root=Path.cwd()
lab=Path(tempfile.mkdtemp(prefix='pins.',dir=root/'.no-mistakes/test-tmp'))
env=dict(os.environ)
for key in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:
 env.pop(key,None)
def run(args,want=0):
 p=subprocess.run([str(x) for x in args],env=env,text=True,capture_output=True,timeout=20)
 print('$ '+' '.join(str(x) for x in args),flush=True)
 print((p.stdout+p.stderr).strip(),flush=True)
 assert p.returncode==want,(p.returncode,p.stdout,p.stderr)
 return p.stdout.strip()
try:
 run(['bash',root/'bin/fm-lab-home.sh','create',lab/'home'])
 env['FM_HOME']=str(lab/'home')
 cfg=lab/'home/config'
 (cfg/'secondmate-harness.d').mkdir()
 (cfg/'crew-harness').write_text('claude\n')
 (cfg/'secondmate-harness').write_text('pi deepseek high\n')
 (cfg/'secondmate-harness.d/mac').write_text('codex gpt-6.1-sol xhigh\n')
 for mate,expected in [('mac',['codex','gpt-6.1-sol','xhigh','config/secondmate-harness.d/mac']),('work',['pi','deepseek','high','config/secondmate-harness'])]:
  for verb,want in zip(['secondmate','secondmate-model','secondmate-effort','secondmate-source'],expected):
   assert run(['bash',root/'bin/fm-harness.sh',verb,mate])==want
 (cfg/'secondmate-harness.d/mac').write_text('default\n')
 assert run(['bash',root/'bin/fm-harness.sh','secondmate','mac'])=='pi'
 assert run(['bash',root/'bin/fm-harness.sh','secondmate','../mac'],2)==''
 print('A per-mate pin wins as a whole line; other mates and default pins use shared settings; path traversal is refused.',flush=True)
finally:
 shutil.rmtree(lab)
