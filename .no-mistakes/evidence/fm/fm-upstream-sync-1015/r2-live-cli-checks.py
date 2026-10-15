import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path.cwd()
lab = Path(tempfile.mkdtemp(prefix='cli.', dir=root / '.no-mistakes/test-tmp'))
env = dict(os.environ)
for name in ['GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_PROJECTS_OVERRIDE']:
    env.pop(name, None)
env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid', GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid')

def run(args, expected=0, visible=False, extra=None):
    p = subprocess.run([str(x) for x in args], env=env | (extra or {}), text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=40)
    if visible:
        print('$ ' + ' '.join(str(x) for x in args), flush=True)
        print(p.stdout.rstrip(), flush=True)
        print('exit=' + str(p.returncode), flush=True)
    assert p.returncode == expected, (args, p.returncode, p.stdout)
    return p.stdout.strip()

def git(repo, *args):
    return run(['git', '-C', repo, *args])

try:
    fork, parent, home = lab / 'fork', lab / 'original', lab / 'home'
    run(['bash', root / 'bin/fm-lab-home.sh', 'create', home])
    git(lab, 'init', '-q', '-b', 'main', str(fork))
    git(fork, 'commit', '--allow-empty', '-qm', 'fixture root')
    git(fork, 'remote', 'add', 'origin', 'https://github.com/BohnBawerick/firstmate')
    git(fork, 'remote', 'add', 'upstream', 'https://github.com/kunchenguid/firstmate')
    git(lab, 'clone', '-q', str(fork), str(parent))
    git(parent, 'remote', 'set-url', 'origin', 'https://github.com/kunchenguid/firstmate')
    for key, value in [('checkout.defaultRemote', 'origin'), ('remote.pushDefault', 'origin'), ('remote.origin.gh-resolved', 'base')]:
        git(fork, 'config', key, value)
    role_env = {'FM_ROOT_OVERRIDE': str(fork), 'FM_HOME': str(home)}
    print('Publication authority through the real fm-role CLI', flush=True)
    for project, consent, status in [(fork, None, 1), (fork, 'github.com/BohnBawerick/firstmate', 0), (fork, 'github.com/kunchenguid/firstmate', 1), (parent, 'github.com/BohnBawerick/firstmate', 1), (parent, 'github.com/kunchenguid/firstmate', 0)]:
        args = ['bash', root / 'bin/fm-role.sh', 'check', project]
        if consent:
            args += ['upstream-consent', consent]
        run(args, status, True, role_env)
    git(fork, 'config', 'remote.pushDefault', 'upstream')
    run(['bash', root / 'bin/fm-role.sh', 'check', fork, 'upstream-consent', 'github.com/kunchenguid/firstmate'], 1, True, role_env)

    print('\nReview the terminal PR route against real fetched Git refs', flush=True)
    remote, project, wt = lab / 'remote.git', lab / 'project', lab / 'task'
    git(lab, 'init', '--bare', '-q', str(remote))
    git(remote, 'symbolic-ref', 'HEAD', 'refs/heads/main')
    git(lab, 'init', '-q', '-b', 'main', str(project))
    (project / 'feature.txt').write_text('base\n')
    git(project, 'add', 'feature.txt')
    git(project, 'commit', '-qm', 'baseline')
    git(project, 'remote', 'add', 'origin', str(remote))
    git(project, 'push', '-q', 'origin', 'main')
    git(project, 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')
    git(project, 'worktree', 'add', '-qb', 'fm/review', str(wt), 'main')
    for branch, text, number in [('correct', 'correct terminal route', 7), ('wrong', 'wrong earlier route', 123)]:
        git(project, 'checkout', '-qb', branch, 'main')
        (project / 'feature.txt').write_text(text + '\n')
        git(project, 'commit', '-qam', text)
        git(project, 'push', '-q', 'origin', f'HEAD:refs/pull/{number}/head')
    git(project, 'checkout', '-q', 'main')
    for url in ['https://forgejo.example/pull/123/pulls/7', 'https://github.com/pulls/123/pull/7']:
        (home / 'state/review.meta').write_text(f'window=\nproject={project}\nworktree={wt}\nbranch=fm/review\npr={url}\n')
        print('Recorded PR: ' + url, flush=True)
        out = run(['bash', root / 'bin/fm-review-diff.sh', 'review'], 0, True, {'FM_HOME': str(home), 'FM_SPAWN_NO_GUARD': '1'})
        assert '+correct terminal route' in out and '+wrong earlier route' not in out
    print('\nBoth route collisions selected PR 7, and all authority boundaries held.', flush=True)
finally:
    shutil.rmtree(lab)
