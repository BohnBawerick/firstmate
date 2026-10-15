import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root=Path.cwd()
lab=Path(tempfile.mkdtemp(prefix='landing.',dir=root/'.no-mistakes/test-tmp'))
env=dict(os.environ)
for key in ['GIT_DIR','GIT_COMMON_DIR','GIT_WORK_TREE','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:
    env.pop(key,None)
env.update(PATH='/usr/bin:/bin',HOME=str(lab/'user'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_SYSTEM='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Fixture',GIT_AUTHOR_EMAIL='fixture@example.invalid',GIT_COMMITTER_NAME='Fixture',GIT_COMMITTER_EMAIL='fixture@example.invalid',FM_SPAWN_NO_GUARD='1')
def run(args,expected=0,visible=False):
    p=subprocess.run([str(x) for x in args],env=env,text=True,capture_output=True,timeout=40)
    if visible:
        print('$ '+' '.join(str(x) for x in args),flush=True)
        print((p.stdout+p.stderr).strip(),flush=True)
        print('exit='+str(p.returncode),flush=True)
    assert p.returncode==expected,(args,p.returncode,p.stdout,p.stderr)
    return (p.stdout+p.stderr).strip()
try:
    for form in ['ancestry','squash']:
        case=lab/form
        case.mkdir()
        home=case/'home'
        run(['bash',root/'bin/fm-lab-home.sh','create',home])
        env['FM_HOME']=str(home)
        bindir=case/'bin'
        bindir.mkdir()
        (bindir/'tmux').write_text('#!/bin/sh\nexec /usr/bin/tmux -S .no-mistakes/landing-private.sock \"$@\"\n')
        (bindir/'tmux').chmod(0o755)
        (bindir/'treehouse').symlink_to('/home/bohn/.local/bin/treehouse')
        env['PATH']=str(bindir)+':/usr/bin:/bin'
        origin,project,wt=case/'origin.git',case/'project',case/'worktree'
        run(['git','init','--bare','-q',origin])
        run(['git','init','-q','-b','main',project])
        run(['git','-C',project,'commit','-qm','baseline','--allow-empty'])
        run(['git','-C',project,'remote','add','origin',origin])
        run(['git','-C',project,'push','-q','origin','main','main:feature/hub'])
        run(['git','-C',project,'symbolic-ref','refs/remotes/origin/HEAD','refs/remotes/origin/main'])
        env['TREEHOUSE_ROOT']=str(case/'pool')
        wt=Path(run(['bash','-c','cd "$1" && treehouse get --lease --no-fetch -b task','_',project]).splitlines()[0])
        (wt/'unlanded.txt').write_text('keep this work\n')
        run(['git','-C',wt,'add','.'])
        run(['git','-C',wt,'commit','-qm','task work'])
        head=run(['git','-C',wt,'rev-parse','HEAD'])
        landed=head if form=='ancestry' else run(['git','-C',project,'commit-tree',head+'^{tree}','-p','main','-m','squash task work'])
        run(['git','-C',project,'update-ref','refs/heads/main',landed])
        run(['git','-C',project,'reset','--hard','main'])
        meta=home/'state/task.meta'
        meta.write_text(f'window=firstmate:fm-task\nkind=ship\nmode=direct-PR\nyolo=off\nproject={project}\nworktree={wt}\nbranch=task\nbase_branch=feature/hub\n')
        print('\nOnly local main contains the task work: '+form,flush=True)
        p=run(['bash',root/'bin/fm-teardown.sh','task','--legacy-record'],1,True)
        assert 'REFUSED' in p and 'unpushed' in p,p
        assert meta.exists() and (wt/'unlanded.txt').read_text()=='keep this work\n'
        assert run(['git','-C',wt,'rev-parse','HEAD'])==head
        assert run(['git','-C',project,'rev-parse','main'])==landed
        print('Task record, branch, working copy, and local main were retained.',flush=True)
        meta.write_text(meta.read_text().replace('base_branch=feature/hub\n',''))
        print('An ordinary task may use the fork local-default fallback: '+form,flush=True)
        run(['bash',root/'bin/fm-teardown.sh','task','--legacy-record'],0,True)
        assert not meta.exists()
        run(['git','-C',project,'show-ref','--verify','--quiet','refs/heads/task'],1)
        assert run(['git','-C',project,'rev-parse','main'])==landed
        print('The ordinary landed task was cleaned; local main was retained.',flush=True)
finally:
    shutil.rmtree(lab)
