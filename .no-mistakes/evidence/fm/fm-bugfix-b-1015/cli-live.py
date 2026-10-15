import base64,json,os,pathlib,subprocess,sys
root=pathlib.Path(sys.argv[1]); work=root/'.test-phase/cli-live';work.mkdir(exist_ok=True)
e={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI','LAVISH_AXI'))}
e.update(TMPDIR=str(root/'.test-phase/runtime'),FM_PROCEVENT_CLAIM_ROOT=str(work/'claims'),LAVISH_AXI_STATE_DIR=str(work/'lavish-state'))
def run(args,env=None):
    r=subprocess.run(args,cwd=root,env=env or e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
    print('$', ' '.join(str(a) for a in args), '\n',r.stdout, 'exit=',r.returncode,flush=True)
    return r
home=work/'home';assert run(['bash','bin/fm-lab-home.sh','create',str(home)]).returncode==0
e['FM_HOME']=str(home)
r=run(['bash','bin/fm-brief.sh','probe','disposable','--scout','--herdr-lab']);assert r.returncode==0
brief=home/'data/probe/brief.md'
text=brief.read_text();print('EMITTED WORKTREE RULE:')
for line in text.splitlines():
    if 'worktree' in line.lower() or 'traverse' in line.lower(): print(line)
assert 'search' in text and 'read only' in text
pathlib.Path(sys.argv[2]+'/generated-scout-brief.md').write_text(text)
brief.write_text(text.replace('{TASK}','Check the raw account guard.').replace('{FIRSTMATE_SPEC}','Refuse ambiguous runners before launch.'))
proj=work/'project';proj.mkdir(exist_ok=True)
for args in (['git','init','-q','-b','main',str(proj)],['git','-C',str(proj),'-c','user.name=fixture','-c','user.email=fixture@example.invalid','commit','-q','--allow-empty','-m','fixture']):assert run(args).returncode==0
(home/'config/claude-account').write_text('default\n')
for raw in ('env claude','command claude','exec claude','bash -c "claude"','true; claude','A=1 env claude'):
    r=run(['bash','bin/fm-spawn.sh','probe',str(proj),raw,'--scout','--backend','tmux'])
    assert r.returncode != 0 and 'cannot prove which runner' in r.stdout,r.stdout
assert not list((home/'state').glob('*.meta'))
print('All wrapped launches refused before endpoint or task metadata creation',flush=True)
encode=lambda s:base64.b64encode(s.encode()).decode()
r=run(['bash','bin/fm-remote-entrypoint.sh','1',encode(str(root)),encode(str(work/'absent-parent/mate')),encode('fm-remote-secondmate-control.sh\0state\0mate\0')])
assert r.returncode != 0 and "parent directory does not exist" in r.stdout
payload='''session:\n  status: feedback\nprompts[1]:\n  - uid: "text-a"\n    prompt: "Change this phrase"\n    selector: "#intro"\n    tag: text\n    text: "Selected phrase"\n    target:\n      type: text-range\n      text: "Selected phrase"\n      selector: "#intro"\n      start:\n        selector: "#intro"\n        path[2]: 0,1\n        offset: 2\n      end:\n        selector: "#intro"\n        path[2]: 0,1\n        offset: 17\n'''
source=work/'feedback.txt';source.write_text(payload)
cap=len(payload[:payload.index('      selector: "#intro"')].encode())
for name,bound in [('cut',cap),('whole',len(payload.encode())+100)]:
    assert run(['bash','bin/fm-procevent.sh','register','lavish',name,'--','/bin/cat',str(source)]).returncode==0
    en=dict(e,FM_PROCEVENT_MAX_OUTPUT_BYTES=str(bound))
    assert run(['bash','bin/fm-procevent.sh','start',name],en).returncode==0
    result=next((home/'state/procevent-inbox').glob(name+'.*.result'),None)
    if result is None:result=next((home/'state').rglob(name+'.*.result'))
    print('captured bytes:',result.stat().st_size, 'limit:',bound,flush=True)
    r=run(['bash','bin/fm-procevent-lavish.sh','read',str(result)])
    if name=='cut': assert r.returncode!=0 and 'truncated: yes' in r.stdout and 'complete: no' in r.stdout and 'malformed_items: 0' in r.stdout
    else: assert r.returncode==0 and 'truncated: no' in r.stdout and 'complete: yes' in r.stdout
    run(['bash','bin/fm-procevent.sh','retire',name])
run(['bash','bin/fm-procevent.sh','sweep-home'])
print('LIVE CLI SCENARIOS PASSED',flush=True)
