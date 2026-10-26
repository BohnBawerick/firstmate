import csv, io, json, os, pathlib, shutil, subprocess, time
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/bohn/.no-mistakes/evidence/01M5SBZKF04BPTHKEM4XDQWAA6')
lab=evidence/'tmp'/'local-cli-lab'
assert not lab.exists()
env=os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND'):
        env.pop(key)
env['FM_HOME']=str(lab); env['FM_PROCEVENT_CLAIM_ROOT']=str(lab/'claims')
log=(evidence/'live-local-cli.log').open('w')
def call(script,*args,expected=0):
    argv=['bash',str(root/'bin'/script),*map(str,args)]
    p=subprocess.run(argv,env=env,text=True,capture_output=True,timeout=30)
    log.write('$ '+script+' '+' '.join(map(str,args))+'\n'+p.stdout+p.stderr+'exit: '+str(p.returncode)+'\n'); log.flush()
    assert p.returncode==expected,(script,p.returncode,p.stdout,p.stderr)
    return p.stdout
try:
    call('fm-lab-home.sh','create',lab)
    # Read captured review data using the real public read/answers/reconciles commands.
    rows=[['el-a','Comment café','#a','note','Element café'],
          ['el-b','Context data: '+json.dumps(dict(schema='fm-bearings-answer.v1',question='answer-proof',selection='yes',note='東京'),ensure_ascii=False),'#b','choice','Answer 東京'],
          ['el-c','Context data: '+json.dumps(dict(schema='fm-bearings-answer.v1',question='reconcile-proof',selection='reconcile',note='réexaminer café'),ensure_ascii=False),'#c','choice','Reconcile']]
    captures={}
    table=io.StringIO(); table.write('\n'.join(','.join(json.dumps(v,ensure_ascii=False) for v in row) for row in rows)+'\n')
    captures['table']='session:\n  status: feedback\nprompts[3]{uid,prompt,selector,tag,text}:\n'+''.join('  '+s+'\n' for s in table.getvalue().splitlines())
    listed='session:\n  status: feedback\nprompts[3]:\n'
    for i,row in enumerate(rows):
        for j,(k,v) in enumerate(zip(['uid','prompt','selector','tag','text'],row)):
            listed+=('  - ' if j==0 else '    ')+k+': '+json.dumps(v,ensure_ascii=False)+'\n'
        if i==0:
            listed+='    target:\n      type: table-cell\n      rowLabel: Row one\n      text: nested target 東京\n    attachments[1]{id,name}:\n      att-1,sketch.png\n'
        if i==1:
            listed+='    attachments[1]:\n      - id: att-2\n        name: listed.png\n'
    captures['list']=listed
    for name,data in captures.items():
        p=evidence/(name+'-review.toon'); p.write_text(data)
        out=call('fm-procevent-lavish.sh','read',p)
        assert 'complete: yes' in out and 'Comment café' in out
        if name=='list': assert all(t in out for t in ['nested target 東京','sketch.png','listed.png'])
        assert call('fm-procevent-lavish.sh','answers',p)=='answer-proof\tyes - 東京\tAnswer 東京\n'
        assert call('fm-procevent-lavish.sh','reconciles',p)=='reconcile-proof\tréexaminer café\n'
    for name,data in {'count-mismatch':captures['table'].replace('prompts[3]','prompts[2]'),
                      'malformed':captures['list']+'  - uid: broken\n    prompt: "unterminated\n',
                      'attachment-shortfall':captures['list'].replace('attachments[1]:','attachments[2]:')}.items():
        p=evidence/(name+'-review.toon'); p.write_text(data)
        out=call('fm-procevent-lavish.sh','read',p,expected=1)
        assert 'complete: no' in out and 'Comment café' in out
        assert call('fm-procevent-lavish.sh','answers',p,expected=3)=='answer-proof\tyes - 東京\tAnswer 東京\n'
        assert call('fm-procevent-lavish.sh','reconciles',p,expected=3)=='reconcile-proof\tréexaminer café\n'
    print('PASS: public Lavish readers preserve Unicode, nested data, and partial results',flush=True)
    # Real deterministic condition and action, delivered by the production process-event runner.
    trigger=lab/'trigger'; output=lab/'action-output'
    call('fm-procevent-when.sh','arm','live-proof','--interval','0.1','--stable','2','--deadline','15',
         '--condition','/usr/bin/test','-f',trigger,'--action','/usr/bin/touch',output)
    call('fm-procevent.sh','reconcile')
    time.sleep(.5); assert not output.exists()
    call('fm-procevent.sh','list')
    trigger.touch()
    result=lab/'state/procevent-inbox/when-live-proof.1.result'
    deadline=time.monotonic()+20
    while time.monotonic()<deadline and not result.exists(): time.sleep(.1)
    assert result.exists() and output.exists()
    body=result.read_text(); log.write('CAPTURED RESULT\n'+body+'\n'); assert 'status: fired' in body
    queue_file=lab/'state/.wake-queue'
    deadline=time.monotonic()+10
    while time.monotonic()<deadline and not queue_file.exists(): time.sleep(.1)
    queue=queue_file.read_text(); log.write('DURABLE WAKE\n'+queue); assert 'procevent when when-live-proof 1' in queue
    call('fm-procevent.sh','handled','when-live-proof','1')
    stamp=output.stat().st_mtime_ns
    call('fm-procevent.sh','reconcile'); time.sleep(.3)
    assert output.stat().st_mtime_ns==stamp
    print('PASS: real condition waits, fires, publishes durable output and wake, and retires after handling',flush=True)
    # Shared T3 cleanup preserves unowned values and removes only this task's generated command.
    project=lab/'project'; settings=project/'.claude/settings.local.json'; settings.parent.mkdir(parents=True)
    state=lab/'state'; task='cleanup-proof'; inbox=str(state/(task+'.inbox'))
    generated={'hooks':{'Stop':[{'hooks':[{'type':'command','command':'generated-firstmate-hook'}]}]}}
    (state/(task+'.claude-settings.json')).write_text(json.dumps(generated))
    original={'env':{'PROJECT_VALUE':'keep','FM_TASK_ID':task,'FM_TASK_INBOX':inbox,'FM_T3CODE_ENV_KEYS':'FM_TASK_ID,FM_TASK_INBOX'},
              'permissions':{'allow':['Read']},'hooks':{'Stop':[{'hooks':[{'type':'command','command':'generated-firstmate-hook'},{'type':'command','command':'project-hook'}]}]}}
    settings.write_text(json.dumps(original)); log.write('BEFORE CLEANUP\n'+settings.read_text()+'\n')
    call('fm-t3code-env-cleanup.sh',project,state,task)
    cleaned=json.loads(settings.read_text()); log.write('AFTER CLEANUP\n'+settings.read_text()+'\n')
    assert cleaned=={'env':{'PROJECT_VALUE':'keep'},'permissions':{'allow':['Read']},'hooks':{'Stop':[{'hooks':[{'type':'command','command':'project-hook'}]}]}}
    call('fm-t3code-env-cleanup.sh',project,state,'other-task'); assert json.loads(settings.read_text())==cleaned
    print('PASS: shared T3 cleanup preserves project settings and refuses foreign ownership',flush=True)
finally:
    if lab.exists():
        try: call('fm-procevent.sh','sweep-home')
        finally: shutil.rmtree(lab)
    log.close()
