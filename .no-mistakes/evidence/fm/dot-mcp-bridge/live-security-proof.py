import http.client
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import subprocess
import tempfile
import time
root=Path('/home/bohn/.no-mistakes/worktrees/842a31c92d33/01M50DPBG3H9SMSTA1C87NNP2P')
evidence=Path('/home/bohn/.no-mistakes/evidence/01M50DPBG3H9SMSTA1C87NNP2P')
lab=Path(tempfile.mkdtemp(prefix='security-',dir=evidence/'.tmp'))
record=(evidence/'live-security-transcript.jsonl').open('w')
serverlog=(evidence/'live-security-server.log').open('w')
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_','CLAUDE_'))}
env.update(FM_HOME=str(lab),PYTHONDONTWRITEBYTECODE='1',TMPDIR=str(lab))
sock=socket.socket(); sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]; sock.close()
process=subprocess.Popen(['bash',str(root/'bin/fm-dot-mailbox.sh'),'serve','--port',str(port)],cwd=root,env=env,stdout=serverlog,stderr=serverlog)
def rpc(method,params=None):
    connection=http.client.HTTPConnection('127.0.0.1',port,timeout=5)
    try:
        connection.request('POST','/mcp',json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params or {}}),{'Content-Type':'application/json'})
        response=connection.getresponse(); value=json.loads(response.read())
        assert response.status==200
        return value
    finally: connection.close()
def log(label,value):
    record.write(json.dumps({'check':label,'response':value})+'\n'); record.flush()
try:
    for _ in range(100):
        try:
            discovery=rpc('server/discover'); break
        except OSError: time.sleep(.05)
    else: raise AssertionError('strict server did not start')
    log('discovery',discovery)
    tools=rpc('tools/list'); log('only mailbox tools',tools)
    assert {x['name'] for x in tools['result']['tools']}=={'submit_message','get_messages','reply'}
    forbidden=rpc('tools/call',{'name':'shell','arguments':{'command':f'touch {lab}/forbidden'}})
    log('shell tool refusal',forbidden)
    assert 'error' in forbidden and not (lab/'forbidden').exists()
    oversized=rpc('tools/call',{'name':'submit_message','arguments':{'content':'x'*16385,'queue':'proof'}})
    log('oversized message refusal',oversized)
    assert 'error' in oversized or oversized['result'].get('isError')
    for url in ('http://example.test/callback','https://127.0.0.1/callback','https://169.254.169.254/callback','https://100.64.0.1/callback'):
        value=rpc('events/subscribe',{'name':'message.created','arguments':{'queue':'proof'},'delivery':{'mode':'webhook','url':url,'secret':'whsec_MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIz'}})
        log('callback refusal '+url,value)
        assert value['error']['code']==-32015
    messages=rpc('tools/call',{'name':'get_messages','arguments':{'queue':'proof'}})
    log('rejected submissions leave mailbox empty',messages)
    assert json.loads(messages['result']['content'][0]['text'])['messages']==[]
    for db in lab.rglob('*.sqlite3'):
        log('private database mode',{'path':str(db.relative_to(lab)),'mode':oct(stat.S_IMODE(db.stat().st_mode))})
        assert stat.S_IMODE(db.stat().st_mode)==0o600
finally:
    process.terminate(); process.wait(timeout=10); record.close(); serverlog.close(); shutil.rmtree(lab)
