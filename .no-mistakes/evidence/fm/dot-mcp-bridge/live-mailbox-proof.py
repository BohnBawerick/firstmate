#!/usr/bin/env python3
import base64
import datetime as dt
import fcntl
import hashlib
import hmac
import http.client
import http.server
import json
import os
from pathlib import Path
import pty
import select
import shutil
import socket
import sqlite3
import struct
import subprocess
import tempfile
import termios
import threading
import time
import uuid

ROOT = Path('/home/bohn/.no-mistakes/worktrees/842a31c92d33/01M50DPBG3H9SMSTA1C87NNP2P')
EVIDENCE = Path('/home/bohn/.no-mistakes/evidence/01M50DPBG3H9SMSTA1C87NNP2P')
LAB = Path(tempfile.mkdtemp(prefix='proof-', dir=EVIDENCE / '.tmp'))
ENV = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_', 'CLAUDE_'))}
ENV.update(FM_HOME=str(LAB / 'parent'), PYTHONDONTWRITEBYTECODE='1', TMPDIR=str(LAB), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
DB = LAB / 'private' / 'mailbox.sqlite3'
transcript = (EVIDENCE / 'live-mailbox-transcript.txt').open('w')
logfile = (EVIDENCE / 'live-mailbox-server.log').open('w')
key = os.urandom(32)
secret = 'whsec_' + base64.b64encode(key).decode()
received = []
verification_count = 0
receive_status = 202
process = None

def log(label, data):
    transcript.write(label + '\n' + (data if isinstance(data, str) else json.dumps(data, indent=2)) + '\n\n')
    transcript.flush()

def run(script, *args, ok=True):
    result = subprocess.run(['bash', str(ROOT / 'bin' / script), *map(str, args)], env=ENV, cwd=ROOT, text=True, capture_output=True, timeout=45)
    log('$ ' + script + ' ' + ' '.join(map(str, args)), result.stdout)
    if ok:
        assert result.returncode == 0, result.stderr
    return result

class Receiver(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'ready')
    def do_POST(self):
        global verification_count
        body = self.rfile.read(int(self.headers['Content-Length']))
        identity, stamp = self.headers['webhook-id'], self.headers['webhook-timestamp']
        signature = 'v1,' + base64.b64encode(hmac.new(key, f'{identity}.{stamp}.'.encode() + body, hashlib.sha256).digest()).decode()
        assert hmac.compare_digest(signature, self.headers['webhook-signature'])
        payload = json.loads(body)
        if payload.get('type') == 'verification':
            verification_count += 1
            self.send_response(200)
            self.end_headers()
            self.wfile.write(json.dumps({'challenge': payload['challenge']}).encode())
        else:
            received.append({'event': payload, 'signature_valid': True, 'http_status': receive_status})
            self.send_response(receive_status)
            self.end_headers()

receiver = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Receiver)
threading.Thread(target=receiver.serve_forever, daemon=True).start()
probe = socket.socket(); probe.bind(('127.0.0.1', 0)); port = probe.getsockname()[1]; probe.close()

def start():
    global process
    process = subprocess.Popen(['bash', str(ROOT / 'bin/fm-dot-mailbox.sh'), '--db', str(DB), 'serve', '--port', str(port), '--allow-local-callbacks'], env=ENV, cwd=ROOT, stdout=logfile, stderr=logfile)
    for _ in range(150):
        try:
            connection = http.client.HTTPConnection('127.0.0.1', port, timeout=2)
            connection.request('GET', '/health'); response = connection.getresponse()
            body = response.read(); connection.close()
            if response.status == 200:
                log('Mailbox HTTP health', json.loads(body)); return
        except OSError:
            pass
        assert process.poll() is None, 'mailbox exited during startup'
        time.sleep(.05)
    raise RuntimeError('mailbox startup timeout')

def stop():
    global process
    if process:
        process.terminate(); process.wait(timeout=10); process = None

def rpc(method, params=None, record=True):
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
    try:
        connection.request('POST', '/mcp', json.dumps({'jsonrpc':'2.0', 'id':1, 'method':method, 'params':params or {}}), {'Content-Type':'application/json'})
        response = connection.getresponse(); result = json.loads(response.read())
        assert response.status == 200
    finally:
        connection.close()
    if record:
        log('MCP ' + method, result)
    return result

def tool(name, args, ok=True):
    response = rpc('tools/call', {'name':name, 'arguments':args})
    if ok:
        assert 'error' not in response, response
        result = response['result']; assert not result.get('isError'), result
        return json.loads(result['content'][0]['text'])
    return response

def wait_for(predicate, description):
    for _ in range(150):
        if predicate(): return
        time.sleep(.1)
    raise AssertionError(description)

def reply(assignment, text):
    return tool('reply', {'message_id':assignment['id'], 'correlation_id':assignment['correlation_id'], 'reply':text})

def stamp():
    return dt.datetime.now(dt.timezone.utc).isoformat()

try:
    run('fm-lab-home.sh', 'create', LAB / 'parent')
    start()
    nonce = 'hello-' + uuid.uuid4().hex
    args = ('--db', DB, 'submit', '--queue', 'hello', '--correlation-id', nonce, '--idempotency-key', nonce, nonce)
    first = json.loads(run('fm-dot-mailbox.sh', *args).stdout)
    duplicate = json.loads(run('fm-dot-mailbox.sh', *args).stdout)
    assert first['id'] == duplicate['id']
    messages = tool('get_messages', {'queue':'hello'})['messages']
    assert len(messages) == 1 and messages[0]['content'] == nonce
    reply(first, 'done: ' + nonce)
    readback = json.loads(run('fm-dot-mailbox.sh', '--db', DB, 'get', first['id']).stdout)
    assert readback['reply'] == 'done: ' + nonce
    stop(); start()
    assert json.loads(run('fm-dot-mailbox.sh', *args).stdout)['id'] == first['id']
    assert json.loads(run('fm-dot-mailbox.sh', '--db', DB, 'get', first['id']).stdout)['reply'] == 'done: ' + nonce

    charter = LAB / 'charter.md'
    charter.write_text('Idle until routed work. Report only through the mailbox.\n')
    run('fm-dot-secondmate.sh', 'register', 'dot-proof', DB, LAB / 'mate', 'work', f'http://127.0.0.1:{port}/health', f'http://127.0.0.1:{receiver.server_port}/readyz', 'Disposable local proof', charter)
    subscription = {'name':'message.created', 'arguments':{'queue':'work'}, 'delivery':{'mode':'webhook', 'url':f'http://127.0.0.1:{receiver.server_port}/callback', 'secret':secret}}
    rpc('events/subscribe', subscription)
    rpc('events/subscribe', subscription)
    assert verification_count == 1
    stop(); start()
    rpc('events/subscribe', subscription)
    assert verification_count == 1
    log('Receiver verification', {'signature_valid':True, 'challenge_echoed':True, 'duplicate_subscribe_challenges':verification_count})
    run('fm-send.sh', 'dot-proof', 'Subject: Visible corpus read-only feasibility comparison\nReturn the synthetic proof nonce only.')
    assignment = tool('get_messages', {'queue':'work'})['messages'][0]
    wait_for(lambda: received, 'signed assignment event did not arrive')
    log('Local controlled receiver, not a hosted dot wake', received)
    reply(assignment, 'done: turn A completed')
    status_file = LAB / 'parent/state/dot-proof.status'
    wait_for(lambda: status_file.exists() and 'turn A completed' in status_file.read_text(), 'parent result missing')
    log('Parent wake drain', run('fm-wake-drain.sh').stdout)

    def observe(event, kind, turn, title=None):
        note = {'schema':'fm.activity-note.v1', 'event_id':event, 'kind':kind, 'observed_at':stamp(), 'summary':'Synthetic local reported observation', 'task_id':'fixture-native-thread', 'turn_id':turn}
        if title: note['task_title'] = title
        return note, reply(assignment, 'activity-note: ' + json.dumps(note))

    observe('turn-A-done', 'done', 'turn-A')
    wait_for(lambda: 'turn A completed' in status_file.read_text(), 'status not delivered')
    def outbox_empty():
        with sqlite3.connect(DB) as database:
            return database.execute('SELECT COUNT(*) FROM mate_replies WHERE published=0').fetchone()[0] == 0
    wait_for(outbox_empty, 'terminal parent delivery did not complete')
    before = status_file.read_bytes()
    note, result = observe('turn-B-created', 'task-created', 'turn-B', 'Visible corpus comparison with full native task title')
    retry = reply(assignment, 'activity-note: ' + json.dumps(note))
    assert retry['revision'] == result['revision']
    time.sleep(.5)
    assert status_file.read_bytes() == before, 'routine note created parent wake'
    log('Exact activity retry', {'first_revision': result['revision'], 'retry_revision':retry['revision'], 'routine_parent_status_unchanged':True})
    run('fm-crew-state.sh', 'dot-proof')
    fleet = json.loads(run('fm-fleet-snapshot.sh', '--json').stdout)
    task = next(x for x in fleet['tasks'] if x['id'] == 'dot-proof')
    mate = next(x for x in fleet['secondmate_current']['records'] if x['id'] == 'dot-proof')
    assert task['current_state']['state'] == 'working'
    assert mate['current']['state'] == 'active_child_work'
    log('Fresh turn B reconciles older turn A', {'tasks.current_state':task['current_state'], 'secondmate_current':mate['current']})

    # Age persisted fixture observations to exercise the public stale-state reads.
    with sqlite3.connect(DB) as db:
        for seq, activity in db.execute('SELECT seq,activity FROM mate_replies WHERE activity IS NOT NULL').fetchall():
            value = json.loads(activity)
            value['observed_at'] = (dt.datetime.fromisoformat(value['observed_at'].replace('Z','+00:00')) - dt.timedelta(seconds=1000)).isoformat()
            db.execute('UPDATE mate_replies SET activity=? WHERE seq=?', (json.dumps(value), seq))
    run('fm-crew-state.sh', 'dot-proof')
    fleet = json.loads(run('fm-fleet-snapshot.sh', '--json').stdout)
    task = next(x for x in fleet['tasks'] if x['id'] == 'dot-proof')
    mate = next(x for x in fleet['secondmate_current']['records'] if x['id'] == 'dot-proof')
    assert task['current_state']['state'] == 'unknown' and mate['current']['state'] == 'unknown'
    log('Aged persisted observations, live public reads', {'tasks.current_state':task['current_state'], 'secondmate_current':mate['current']})

    observe('turn-C-failed', 'failed', 'turn-C')
    wait_for(outbox_empty, 'failed turn parent delivery did not complete')
    assert 'state: failed' in run('fm-crew-state.sh', 'dot-proof').stdout
    failed_before = status_file.read_bytes()
    observe('turn-D-created', 'task-created', 'turn-D')
    wait_for(outbox_empty, 'routine turn D processing did not complete')
    assert status_file.read_bytes() == failed_before
    fleet = json.loads(run('fm-fleet-snapshot.sh', '--json').stdout)
    task = next(x for x in fleet['tasks'] if x['id'] == 'dot-proof')
    mate = next(x for x in fleet['secondmate_current']['records'] if x['id'] == 'dot-proof')
    assert task['current_state']['state'] == 'working' and mate['current']['state'] == 'active_child_work'
    log('Fresh turn D reconciles older failed turn C', {'tasks.current_state':task['current_state'], 'secondmate_current':mate['current']})
    with sqlite3.connect(DB) as db:
        for seq, activity in db.execute('SELECT seq,activity FROM mate_replies WHERE activity IS NOT NULL').fetchall():
            value = json.loads(activity)
            value['observed_at'] = (dt.datetime.fromisoformat(value['observed_at'].replace('Z','+00:00')) - dt.timedelta(seconds=1000)).isoformat()
            db.execute('UPDATE mate_replies SET activity=? WHERE seq=?', (json.dumps(value), seq))
    fleet = json.loads(run('fm-fleet-snapshot.sh', '--json').stdout)
    task = next(x for x in fleet['tasks'] if x['id'] == 'dot-proof')
    mate = next(x for x in fleet['secondmate_current']['records'] if x['id'] == 'dot-proof')
    assert task['current_state']['state'] == 'unknown' and mate['current']['state'] == 'unknown'
    log('Stale turn D remains unknown after failed turn C', {'tasks.current_state':task['current_state'], 'secondmate_current':mate['current']})
    observe('turn-D-milestone', 'milestone', 'turn-D', 'Visible corpus comparison with full native task title')
    blocker = reply(assignment, 'blocked: synthetic dependency unavailable')
    wait_for(lambda: 'synthetic dependency unavailable' in status_file.read_text(), 'blocker missing')
    assert 'state: blocked' in run('fm-crew-state.sh','dot-proof').stdout
    observe('turn-D-routine', 'milestone', 'turn-D')
    assert 'state: blocked' in run('fm-crew-state.sh','dot-proof').stdout
    reply(assignment, f"resolved: [key={blocker['blocker_key']}] fixture dependency repaired")
    wait_for(lambda: 'fixture dependency repaired' in status_file.read_text(), 'explicit blocker resolution missing')
    assert 'state: working' in run('fm-crew-state.sh','dot-proof').stdout
    reply(assignment, 'needs-decision: synthetic owner choice')
    wait_for(lambda: 'synthetic owner choice' in status_file.read_text(), 'decision missing')
    assert 'state: parked' in run('fm-crew-state.sh','dot-proof').stdout
    fleet = json.loads(run('fm-fleet-snapshot.sh', '--json').stdout)
    mate = next(x for x in fleet['secondmate_current']['records'] if x['id'] == 'dot-proof')
    assert mate['current']['state'] == 'captain_decision'
    assert mate['counts']['decisions_open'] == 1
    log('Folded owner decision remains waiting', {'current':mate['current'], 'decisions_open':mate['decisions_open']})
    snapshot = json.loads(run('fm-dot-secondmate.sh', 'snapshot','dot-proof').stdout)
    assert snapshot['ready'] and snapshot['children'][0]['current_state'] == 'working'
    run('fm-dot-secondmate.sh','history','dot-proof','--limit','50')
    log('Final parent status log', status_file.read_text())
    recovery_sub = dict(subscription, arguments={'queue':'recovery'})
    rpc('events/subscribe', recovery_sub)
    receive_status = 503
    recovered_message = json.loads(run('fm-dot-mailbox.sh','--db',DB,'submit','--queue','recovery','--correlation-id','recovery-nonce','Subject: Recover a pending callback').stdout)
    def recovery_events():
        return [x for x in received if x['event']['data']['message_id'] == recovered_message['id']]
    wait_for(recovery_events, '503 event delivery not attempted')
    stop()
    receive_status = 202
    start()
    wait_for(lambda: any(x['http_status'] == 202 for x in recovery_events()), 'pending delivery not recovered after restart')
    assert len({x['event']['eventId'] for x in recovery_events()}) == 1
    readback = json.loads(run('fm-dot-mailbox.sh','--db',DB,'get',recovered_message['id']).stdout)
    wait_for(lambda: json.loads(run('fm-dot-mailbox.sh','--db',DB,'get',recovered_message['id']).stdout)['delivery']['delivered'] == 1, 'delivery acknowledgement not durable')
    log('503 then server restart then 202, stable event identity', recovery_events())

    # Capture the live terminal process through a standard terminal emulator.
    assets = ROOT / '.test-phase/terminal/node_modules/@xterm/xterm'
    output = bytearray()
    class TerminalHost(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            if self.path == '/output':
                data, mime = bytes(output), 'application/octet-stream'
            elif self.path in ('/terminal.js','/terminal.css'):
                relative = 'lib/xterm.js' if self.path.endswith('.js') else 'css/xterm.css'
                data, mime = (assets / relative).read_bytes(), 'text/javascript' if self.path.endswith('.js') else 'text/css'
            else:
                data = ('''<!doctype html><meta charset="utf-8"><link rel="stylesheet" href="/terminal.css"><style>body{margin:0;background:#000}#terminal{padding:12px}</style><div id="terminal"></div><script src="/terminal.js"></script><script>const term=new Terminal({cols:COLS,rows:ROWS,fontSize:16,convertEol:false,allowProposedApi:false});term.open(document.getElementById('terminal'));fetch('/output').then(x=>x.arrayBuffer()).then(x=>term.write(new Uint8Array(x)));</script>'''.replace('COLS',str(columns)).replace('ROWS',str(rows))).encode()
                mime = 'text/html'
            self.send_response(200); self.send_header('Content-Type',mime); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    host = http.server.ThreadingHTTPServer(('127.0.0.1',0),TerminalHost)
    threading.Thread(target=host.serve_forever,daemon=True).start()
    try:
        for columns, rows, name, extra in [(40,24,'console-narrow',[]),(100,24,'child-detail',['--child',snapshot['children'][0]['id']])]:
            output.clear()
            master, slave = pty.openpty()
            fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',rows,columns,0,0))
            viewer = subprocess.Popen(['python3',str(ROOT/'bin/fm-dot-view.py'),'--db',str(DB),'dot-proof',*extra],env=ENV,cwd=ROOT,stdin=slave,stdout=slave,stderr=slave,close_fds=True)
            os.close(slave)
            try:
                end = time.monotonic()+1.5
                while time.monotonic()<end:
                    if select.select([master],[],[],.1)[0]: output.extend(os.read(master,65536))
                assert b'Activity' in output and b'read-only' in output
                (EVIDENCE / (name+'.ansi')).write_bytes(output)
                browser = subprocess.run(['chromium','--headless','--no-sandbox','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-background-networking',f'--user-data-dir={ROOT}/.test-phase/chrome',f'--screenshot={EVIDENCE}/{name}.png',f'--window-size={columns*10+25},{rows*20+25}','--virtual-time-budget=1500',f'http://127.0.0.1:{host.server_port}/'],cwd=ROOT,capture_output=True,text=True,timeout=30)
                assert browser.returncode == 0 and (EVIDENCE/(name+'.png')).exists(),browser.stderr
                log('Live terminal capture',{'artifact':name+'.png','pty_columns':columns,'pty_rows':rows,'process':'bin/fm-dot-view.py','fixture_native_ids':True})
            finally:
                viewer.terminate(); viewer.wait(timeout=10); os.close(master)
    finally:
        host.shutdown(); host.server_close()
    log('RESULT','Local executable/MCP round trip, signed local callback, routing/drain, retry deduplication, current-state reconciliation, explicit blocker resolution, and terminal capture completed.')
finally:
    stop(); receiver.shutdown(); receiver.server_close(); logfile.close(); transcript.close(); shutil.rmtree(LAB)
