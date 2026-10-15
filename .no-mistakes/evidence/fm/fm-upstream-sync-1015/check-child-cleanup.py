import os
from pathlib import Path
import subprocess

root = Path.cwd()
evidence = Path('/home/bohn/.no-mistakes/evidence/01M4ZWV8H0KM2V907GBD81WBZV')
cases = [('project-capacity','test_orca_spawn_is_admitted_under_the_shared_project_lock',1), ('watcher-lock','test_lock_stale_steal_single_winner_under_concurrency',40), ('wake-queue','test_term_stops_a_watcher_blocked_in_the_drain_ring_idle_capture',1)]
for stem, selector, count in cases:
    for mode in ['assertion','signal']:
        pids = evidence / f'cleanup-{stem}-{mode}.pids'
        env = dict(os.environ, TMPDIR=str(root / '.no-mistakes/test-tmp'), FM_GATE_INJECT_AFTER=str(count), FM_GATE_INJECT_MODE=mode, FM_GATE_PID_EVIDENCE=str(pids))
        p = subprocess.run(['bash','.no-mistakes/select-tests.sh',f'tests/fm-{stem}.test.sh',selector],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
        (evidence / f'cleanup-{stem}-{mode}.log').write_text(p.stdout)
        assert p.returncode != 0, (stem,mode,p.stdout)
        assert pids.exists(), (stem,mode,p.stdout)
        tracked = [int(x) for x in pids.read_text().split()]
        assert len(tracked) == count, (stem,mode,tracked,p.stdout)
        for pid in tracked:
            stat = subprocess.run(['ps','-o','stat=','-p',str(pid)],text=True,capture_output=True).stdout.strip()
            assert not stat or stat.startswith('Z'), (stem,mode,pid,stat)
        for line in p.stdout.splitlines():
            if line.startswith(('cleanup_registry=','pid_registry=')):
                assert not Path(line.split('=',1)[1]).exists(), line
        print(f'{stem}: {mode} after registration reaped all {len(tracked)} children and removed both registries. exit={p.returncode}', flush=True)
