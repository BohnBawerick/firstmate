import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

root=Path.cwd()
lab=Path(tempfile.mkdtemp(prefix='capacity.',dir=root/'.no-mistakes/test-tmp'))
env=dict(os.environ)
for key in ['FM_ROOT_OVERRIDE','FM_CONFIG_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE','HERDR_ENV','HERDR_PANE_ID','HERDR_TAB_ID','HERDR_WORKSPACE_ID','HERDR_SOCKET_PATH','HERDR_SESSION']:
    env.pop(key,None)
env.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_SYSTEM='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Fixture',GIT_AUTHOR_EMAIL='fixture@example.invalid',GIT_COMMITTER_NAME='Fixture',GIT_COMMITTER_EMAIL='fixture@example.invalid',FM_HERDR_LAB_STATE_DIR=str(lab/'herdr-state'))
helper=root/'bin/fm-herdr-lab.sh'
session=None
prepared=False
def run(args,expected=0,visible=False):
    p=subprocess.run([str(x) for x in args],env=env,text=True,capture_output=True,timeout=50)
    if visible:
        print('$ '+' '.join(str(x) for x in args),flush=True)
        print((p.stdout+p.stderr).strip(),flush=True)
        print('exit='+str(p.returncode),flush=True)
    assert p.returncode==expected,(args,p.returncode,p.stdout,p.stderr)
    return p.stdout.strip()
try:
    home=lab/'home'
    run(['bash',root/'bin/fm-lab-home.sh','create',home])
    env['FM_HOME']=str(home)
    project=lab/'project'
    run(['git','init','-q','-b','main',project])
    run(['git','-C',project,'commit','-qm','fixture','--allow-empty'])
    run(['git','init','--bare','-q',lab/'origin.git'])
    run(['git','-C',project,'remote','add','origin',lab/'origin.git'])
    (home/'config/project-capacity').write_text('project 1\n')
    (home/'state/holder.meta').write_text(f'kind=ship\nproject={project}\n')
    (home/'data/new').mkdir()
    (home/'data/new/brief.md').write_text("# Task\n## Captain's intent\nExercise capacity refusal only.\n\n## Firstmate spec\nLeave the lab unchanged.\n\n# Definition of done\nDelivery contract: mode=direct-PR yolo=off\n")
    session=run(['bash',helper,'name','capacity'])
    prepared=True
    run(['bash',helper,'provision',session])
    baseline=run(['bash',helper,'run',session,'pane','list'])
    fakebin=lab/'bin'
    fakebin.mkdir()
    (fakebin/'herdr').write_text('#!/usr/bin/env bash\nargs=("$@")\nn=${#args[@]}\nif [ "$n" -ge 2 ] && [ "${args[$((n-2))]}" = --session ]; then\n [ "${args[$((n-1))]}" = '+shlex.quote(session)+' ] || exit 97\n args=("${args[@]:0:$((n-2))}")\nfi\nexec env PATH='+shlex.quote(env['PATH'])+' '+shlex.quote(str(helper))+' run '+shlex.quote(session)+' "${args[@]}"\n')
    (fakebin/'herdr').chmod(0o755)
    env.update(PATH=str(fakebin)+':'+str(root/'.no-mistakes/live-tools/command-code/node_modules/.bin')+':'+env['PATH'],HERDR_SESSION=session,FM_SPAWN_NO_GUARD='1')
    run(['bash',root/'bin/fm-spawn.sh','new',project,'--harness','commandcode','--backend','herdr','--mode','direct-PR','--yolo','off'],75,True)
    assert not (home/'state/new.meta').exists()
    assert not (home/'data/new/launch-brief.md').exists()
    after=run(['bash',helper,'run',session,'pane','list'])
    assert baseline==after,(baseline,after)
    print('No task record, launch brief, or endpoint was created.',flush=True)
finally:
    env['PATH']=os.environ['PATH']
    if prepared:
        run(['bash',helper,'teardown',session])
    shutil.rmtree(lab)
