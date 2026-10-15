#!/usr/bin/env python3
import base64
import concurrent.futures
import hashlib
import hmac
import http.client
import http.server
import json
import os
from pathlib import Path
import secrets
import socket
import ssl
import stat
import subprocess
import tempfile
import threading
import time

ROOT = Path.cwd()
EVIDENCE = Path('/home/bohn/.no-mistakes/evidence/01M4Z12PM14DH6A9P1CQJ6M5SS')
TRANSCRIPT = (EVIDENCE / 'live-mailbox-transcript.jsonl').open('w')
RESULTS = []
START = time.monotonic()
KEYS = [secrets.token_bytes(32), secrets.token_bytes(32)]
SECRETS = ['whsec_' + base64.b64encode(key).decode() for key in KEYS]
RELEASE = threading.Event()
GUARD = threading.RLock()
RECEIVED = []
COUNTS = {}
RECOVER = False
SERVER = None
SERVER_LOG = None


def compact(value):
    if isinstance(value, str) and len(value) > 400:
        return {'utf8_bytes': len(value.encode()), 'sha256': hashlib.sha256(value.encode()).hexdigest()}
    if isinstance(value, list) and len(value) > 6:
        return {'count': len(value), 'first': compact(value[0]), 'last': compact(value[-1])}
    if isinstance(value, dict):
        return {k: ('<disposable signing secret>' if k == 'secret' else compact(v)) for k, v in value.items()}
    if isinstance(value, list):
        return [compact(v) for v in value]
    return value


def record(kind, **value):
    TRANSCRIPT.write(json.dumps({'seconds': round(time.monotonic() - START, 3), 'kind': kind, **compact(value)}) + '\n')
    TRANSCRIPT.flush()


def passed(name, **details):
    RESULTS.append({'name': name, 'result': 'pass', 'details': details})
    record('scenario', name=name, result='pass', **details)
    print('PASS ' + name, flush=True)


def wait_for(callback, timeout=12):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        result = callback()
        if result:
            return result
        time.sleep(.05)
    raise AssertionError('Timed out waiting for ' + repr(callback))


class Receiver(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        payload = json.loads(body)
        event_id, stamp = self.headers['webhook-id'], self.headers['webhook-timestamp']
        signatures = self.headers['webhook-signature'].split()
        signed = f'{event_id}.{stamp}.'.encode() + body
        valid_keys = [index for index, key in enumerate(KEYS) if 'v1,' + base64.b64encode(hmac.new(key, signed, hashlib.sha256).digest()).decode() in signatures]
        verification = payload.get('type') == 'verification'
        with GUARD:
            counter_key = (self.path, verification)
            COUNTS[counter_key] = COUNTS.get(counter_key, 0) + 1
            attempt = COUNTS[counter_key]
        status = 200
        response = json.dumps({'challenge': 'incorrect' if self.path == '/bad-echo' else payload.get('challenge')}).encode() if verification else b''
        if self.path == '/redirect':
            status = 302
        elif not verification:
            if self.path == '/exhaust' or self.path == '/recover' and not RECOVER or self.path == '/retry' and attempt <= 2:
                status = 503
            elif self.path == '/gone':
                status = 410
            elif self.path == '/oversized':
                status = 413
            else:
                status = 202
        entry = {'path': self.path, 'payload': payload, 'webhook_id': event_id, 'timestamp': stamp, 'signature_valid_keys': valid_keys, 'body_bytes': len(body), 'receiver_status': status}
        with GUARD:
            RECEIVED.append(entry)
        record('callback', **entry)
        if not valid_keys:
            status = 401
        self.send_response(status)
        if self.path == '/redirect':
            self.send_header('Location', '/redirect-target')
        if self.path == '/stall' and not verification:
            self.send_header('Content-Length', '9999')
        else:
            self.send_header('Content-Length', str(len(response)))
        self.end_headers()
        self.wfile.flush()
        if self.path == '/stall' and not verification:
            RELEASE.wait(15)
        elif response:
            self.wfile.write(response)


def events(path=None, message_id=None, verification=False):
    with GUARD:
        return [r for r in RECEIVED if (path is None or r['path'] == path) and (r['payload'].get('type') == 'verification') == verification and (message_id is None or r['payload'].get('data', {}).get('message_id') == message_id)]


def http_request(method, path, body=None):
    connection = http.client.HTTPConnection('127.0.0.1', PORT, timeout=15)
    try:
        connection.request(method, path, body=json.dumps(body).encode() if body is not None else None, headers={'Content-Type': 'application/json'})
        response = connection.getresponse()
        data = response.read()
        return response.status, data
    finally:
        connection.close()


def rpc(method, params=None, allow_error=False):
    request = {'jsonrpc': '2.0', 'id': secrets.token_hex(4), 'method': method, 'params': params or {}}
    status, data = http_request('POST', '/mcp', request)
    result = json.loads(data)
    record('mcp', request=request, http_status=status, response=result, response_bytes=len(data))
    assert status == 200
    if not allow_error:
        assert 'error' not in result, result
    return result


def tool(name, arguments, allow_error=False):
    result = rpc('tools/call', {'name': name, 'arguments': arguments}, allow_error)
    if 'error' in result:
        return result
    return json.loads(result['result']['content'][0]['text'])


def cli(*args, success=True, input=None, override=None):
    result = subprocess.run(['bin/fm-dot-mailbox.sh', *args], input=input, capture_output=True, text=True, env=override or ENV, timeout=15)
    try:
        output = json.loads(result.stdout)
    except ValueError:
        output = result.stdout.strip()
    record('operator', argv=list(args), exit=result.returncode, stdout=output, stderr=result.stderr.strip())
    assert (result.returncode == 0) == success, result.stderr
    return output


def launch(local):
    global SERVER, SERVER_LOG
    SERVER_LOG = (EVIDENCE / 'live-server.log').open('a')
    command = ['bin/fm-dot-mailbox.sh', 'serve', '--port', str(PORT)] + (['--allow-local-callbacks'] if local else [])
    SERVER = subprocess.Popen(command, env=ENV, stdout=SERVER_LOG, stderr=SERVER_LOG)
    def ready():
        if SERVER.poll() is not None:
            raise AssertionError('Mailbox server exited; see live-server.log')
        try:
            return http_request('GET', '/health')[0] == 200
        except OSError:
            return False
    wait_for(ready)
    record('server_started', command=command, pid=SERVER.pid, local_callbacks=local)


def stop():
    global SERVER
    if SERVER is not None:
        SERVER.terminate()
        SERVER.wait(timeout=15)
        record('server_stopped', pid=SERVER.pid)
        SERVER = None
        SERVER_LOG.close()


def subscribe(queue, path='/callback', secret=0, ttl=None, url=None, error=False):
    params = {'name': 'message.created', 'arguments': {'queue': queue}, 'delivery': {'mode': 'webhook', 'url': url or BASE + path, 'secret': SECRETS[secret]}}
    if ttl is not None:
        params['ttlMs'] = ttl
    return rpc('events/subscribe', params, error)


def unsubscribe(queue, path='/callback'):
    return rpc('events/unsubscribe', {'name': 'message.created', 'arguments': {'queue': queue}, 'delivery': {'mode': 'webhook', 'url': BASE + path}})


try:
    with tempfile.TemporaryDirectory(prefix='.dot-live.', dir=ROOT) as temp:
        LAB = Path(temp)
        ENV = dict(os.environ, FM_HOME=str(LAB / 'home'), FM_DOT_MAILBOX_DB=str(LAB / 'ignored.sqlite3'), FM_DOT_MCP_HOST='203.0.113.1', FM_DOT_MCP_PORT='', FM_DOT_MCP_ALLOW_LOCAL_CALLBACK='1', PYTHONDONTWRITEBYTECODE='1')
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            PORT = probe.getsockname()[1]
        receiver = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Receiver)
        thread = threading.Thread(target=receiver.serve_forever, daemon=True)
        thread.start()
        BASE = f'http://127.0.0.1:{receiver.server_port}'
        try:
            launch(False)
            discovery = rpc('server/discover')['result']
            assert discovery['supportedVersions'] == ['2026-07-28']
            names = {t['name'] for t in rpc('tools/list')['result']['tools']}
            assert names == {'submit_message', 'get_messages', 'reply'}
            assert rpc('events/list')['result']['events'][0]['name'] == 'message.created'
            assert 'error' in tool('shell', {'command': 'true'}, True)
            for url in (BASE + '/blocked', f'https://127.0.0.1:{receiver.server_port}/blocked', 'https://100.64.0.1/callback', 'https://169.254.169.254/callback'):
                result = subscribe('blocked', url=url, error=True)
                assert result['error']['code'] == -32015
            assert not RECEIVED
            stop()
            launch(True)
            passed('Default loopback service exposes mailbox tools only and ignores inherited callback opt-in', tools=sorted(names), blocked_destinations=4)

            cache_start = time.monotonic()
            original = subscribe('cache', '/cache')['result']
            assert len(events('/cache', verification=True)) == 1
            subscribe('cache', '/cache', secret=1)
            subscribe('cache-other-filter', '/cache')
            assert len(events('/cache', verification=True)) == 1

            subscribe('roundtrip')
            nonce = 'hello-' + secrets.token_hex(12)
            message = cli('submit', '--queue', 'roundtrip', '--correlation-id', nonce, '--idempotency-key', nonce, nonce)
            received = wait_for(lambda: events('/callback', message['id']))[0]
            assert received['payload']['data']['content'] == nonce and received['signature_valid_keys'] == [0]
            assert tool('get_messages', {'queue': 'roundtrip', 'status': 'pending'})['messages'][0]['id'] == message['id']
            assert 'error' in tool('reply', {'message_id': message['id'], 'correlation_id': 'wrong-correlation', 'reply': 'bad'}, True)
            assert tool('reply', {'message_id': message['id'], 'correlation_id': nonce, 'reply': 'done ' + nonce})['status'] == 'ok'
            assert tool('reply', {'message_id': message['id'], 'correlation_id': nonce, 'reply': 'done ' + nonce})['idempotent']
            assert cli('get', message['id'])['reply'] == 'done ' + nonce
            with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
                duplicates = list(pool.map(lambda _: tool('submit_message', {'content': nonce, 'queue': 'roundtrip', 'idempotency_key': nonce}), range(24)))
            assert {m['id'] for m in duplicates} == {message['id']}
            assert len(events('/callback', message['id'])) == 1
            passed('Unique hello travels operator to signed callback to MCP reply and back without concurrent duplicates', message_id=message['id'], nonce=nonce, duplicate_submissions=24)

            stop()
            queued = cli('submit', '--queue', 'roundtrip', '--idempotency-key', 'offline-message', 'submitted while server is stopped')
            assert queued['delivery']['pending'] == 1
            launch(True)
            wait_for(lambda: events('/callback', queued['id']))
            assert cli('submit', '--queue', 'roundtrip', '--idempotency-key', 'offline-message', 'retry')['id'] == queued['id']
            assert cli('get', message['id'])['reply'] == 'done ' + nonce
            assert subscribe('cache', '/cache', secret=1)['result']['id'] == original['id']
            assert len(events('/cache', verification=True)) == 1
            passed('Restart retains assignments replies subscriptions and recovers an offline assignment exactly once', recovered_message_id=queued['id'])

            # Correlation is optional; key rotation must sign with both live keys.
            sub = subscribe('rotate', '/rotation')
            assert subscribe('rotate', '/rotation', secret=1)['result']['id'] == sub['result']['id']
            rotated = tool('submit_message', {'queue': 'rotate', 'content': 'rotation proof'})
            delivery = wait_for(lambda: events('/rotation', rotated['id']))[0]
            assert sorted(delivery['signature_valid_keys']) == [0, 1]
            assert 'correlation_id' not in delivery['payload']['data']
            expiry_start = time.monotonic()
            short = subscribe('short', '/short', ttl=800)['result']
            assert short['refreshBefore']
            time.sleep(1)
            expired = cli('submit', '--queue', 'short', 'after expiration')
            assert sum(expired['delivery'].values()) == 0
            unsubscribe('roundtrip')
            filtered = cli('submit', '--queue', 'roundtrip', 'after unsubscribe')
            assert sum(filtered['delivery'].values()) == 0
            assert not events('/callback', filtered['id'])
            passed('Renewal rotates signatures optional correlation is omitted and expired or removed subscriptions stop events', subscription_id=sub['result']['id'])

            for queue, path in [('retry', '/retry'), ('exhaust', '/exhaust'), ('gone', '/gone'), ('oversized', '/oversized'), ('recover', '/recover'), ('stall', '/stall')]:
                subscribe(queue, path)
            retry = cli('submit', '--queue', 'retry', 'temporary receiver failure')
            wait_for(lambda: cli('get', retry['id'])['delivery']['delivered'] == 1, 12)
            attempts = events('/retry', retry['id'])
            assert [a['receiver_status'] for a in attempts] == [503, 503, 202]
            assert len({a['webhook_id'] for a in attempts}) == 1
            assert len({json.dumps(a['payload'], sort_keys=True) for a in attempts}) == 1
            exhausted = cli('submit', '--queue', 'exhaust', 'permanent receiver failure')
            wait_for(lambda: cli('get', exhausted['id'])['delivery']['undelivered'] == 1, 15)
            assert len(events('/exhaust', exhausted['id'])) == 4
            for queue, path in [('gone', '/gone'), ('oversized', '/oversized')]:
                msg = cli('submit', '--queue', queue, 'terminal receiver response')
                wait_for(lambda: cli('get', msg['id'])['delivery']['undelivered'] == 1)
                assert len(events(path, msg['id'])) == 1
            recover = cli('submit', '--queue', 'recover', 'retry survives restart')
            wait_for(lambda: events('/recover', recover['id']))
            stop()
            RECOVER = True
            launch(True)
            wait_for(lambda: cli('get', recover['id'])['delivery']['delivered'] == 1, 15)
            attempts = events('/recover', recover['id'])
            assert len(attempts) == 2 and len({a['webhook_id'] for a in attempts}) == 1
            before = time.monotonic()
            stall = cli('submit', '--queue', 'stall', 'ack without response body')
            wait_for(lambda: cli('get', stall['id'])['delivery']['delivered'] == 1, 3)
            elapsed = time.monotonic() - before
            assert len(events('/stall', stall['id'])) == 1 and elapsed < 3
            cli('status')
            passed('Delivery retries stable events survives restart exhausts visibly and accepts a stalled-body 202 immediately', retry_statuses=[503, 503, 202], exhausted_attempts=4, stalled_ack_seconds=round(elapsed, 3))

            for path in ['/bad-echo', '/redirect']:
                assert subscribe('invalid', path, error=True)['error']['code'] == -32015
            assert not events('/redirect-target', verification=True)
            for url in ['https://192.168.1.1/callback', 'https://100.64.0.1/callback', 'https://[::ffff:100.64.0.1]/callback', BASE.replace('127.0.0.1', 'user:pass@127.0.0.1') + '/callback', BASE + '/callback#fragment']:
                assert subscribe('invalid', url=url, error=True)['error']['code'] == -32015
            passed('Invalid challenge echoes redirects credential URLs and non-public addresses are rejected', redirect_target_requests=0)

            # Use the real resolver and TLS stack with an isolated trusted certificate.
            cert, key = LAB / 'cert.pem', LAB / 'key.pem'
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost', '-keyout', str(key), '-out', str(cert)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            tls_receiver = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Receiver)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(cert, key)
            tls_receiver.socket = context.wrap_socket(tls_receiver.socket, server_side=True)
            tls_thread = threading.Thread(target=tls_receiver.serve_forever, daemon=True)
            tls_thread.start()
            try:
                stop()
                ENV['SSL_CERT_FILE'] = str(cert)
                # An invalid inherited proxy cannot intercept callback connections.
                ENV['HTTPS_PROXY'] = ENV['HTTP_PROXY'] = 'http://127.0.0.1:1'
                launch(True)
                addresses = [item[4][0] for item in socket.getaddrinfo('localhost', tls_receiver.server_port, type=socket.SOCK_STREAM, proto=socket.IPPROTO_TCP)]
                tls_url = f'https://localhost:{tls_receiver.server_port}/tls'
                subscribe('tls', url=tls_url)
                tls_msg = cli('submit', '--queue', 'tls', 'verified TLS hostname')
                wait_for(lambda: events('/tls', tls_msg['id']))
                assert subscribe('mismatch', url=f'https://127.0.0.1:{tls_receiver.server_port}/mismatch', error=True)['error']['code'] == -32015
                passed('Real TLS callbacks validate the hostname ignore proxy settings and try available localhost candidates', resolved_candidates=addresses, receiver_bound='IPv4 only')
            finally:
                tls_receiver.shutdown()
                tls_receiver.server_close()
                tls_thread.join(timeout=5)

            # Byte bounds are checked through both public write interfaces.
            for name, arguments in [('submit_message', {'content': 'x' * 16385}), ('submit_message', {'content': 'ok', 'queue': 'q' * 257}), ('submit_message', {'content': 'ok', 'correlation_id': 'c' * 257}), ('submit_message', {'content': 'ok', 'idempotency_key': 'k' * 257}), ('reply', {'message_id': message['id'], 'reply': 'r' * 16385})]:
                assert 'error' in tool(name, arguments, True)
            cli('submit', '-', input='x' * 16385, success=False)
            pagination_ids = [tool('submit_message', {'queue': 'pagination', 'content': 'page ' + str(i)})['id'] for i in range(55)]
            pages, cursor, sizes = [], None, []
            while True:
                args = {'queue': 'pagination', 'limit': 1000}
                if cursor:
                    args['cursor'] = cursor
                page = tool('get_messages', args)
                if not page['messages']:
                    break
                assert len(page['messages']) <= 50
                sizes.append(len(page['messages']))
                pages.extend(m['id'] for m in page['messages'])
                cursor = page['next_cursor']
            assert pages == pagination_ids
            for index in range(4):
                msg = tool('submit_message', {'queue': 'byte-pages', 'content': '\x00' * 16384})
                tool('reply', {'message_id': msg['id'], 'reply': '\x00' * 16384})
            data = rpc('tools/call', {'name': 'get_messages', 'arguments': {'queue': 'byte-pages', 'limit': 50}})
            assert len(json.dumps(data, ensure_ascii=False).encode()) <= 262144
            byte_page = json.loads(data['result']['content'][0]['text'])
            assert 0 < len(byte_page['messages']) < 4
            assert http_request('POST', '/mcp', {'x': 'x' * 262145})[0] == 413
            db = LAB / 'home/data/dot-mcp/mailbox.sqlite3'
            permissions = {path.name: oct(stat.S_IMODE(path.stat().st_mode)) for path in db.parent.iterdir()}
            assert stat.S_IMODE(db.parent.stat().st_mode) == 0o700
            assert all(stat.S_IMODE(path.stat().st_mode) == 0o600 for path in db.parent.iterdir())
            assert not (LAB / 'ignored.sqlite3').exists()
            cli('--db', str(db), 'status', override={k: v for k, v in ENV.items() if k != 'FM_HOME'})
            cli('status', success=False, override={k: v for k, v in ENV.items() if k != 'FM_HOME'})
            unsafe = LAB / 'unsafe'
            unsafe.mkdir(mode=0o755)
            cli('--db', str(unsafe / 'db.sqlite3'), 'status', success=False)
            passed('CLI and MCP enforce byte bounds cursor pagination private storage and explicit database ownership', record_pages=sizes, escaped_response_records=len(byte_page['messages']), storage_modes=permissions)

            # Wait out the actual fixed cache period, with a cache hit near expiry.
            while time.monotonic() - cache_start < 295:
                remaining = 295 - (time.monotonic() - cache_start)
                print(f'Waiting for real verification-cache expiry: {remaining:.0f}s', flush=True)
                time.sleep(min(25, remaining))
            subscribe('cache', '/cache')
            subscribe('cache-near-expiry', '/cache')
            assert len(events('/cache', verification=True)) == 1
            while time.monotonic() - cache_start < 302:
                time.sleep(.2)
            subscribe('cache', '/cache')
            assert len(events('/cache', verification=True)) == 2
            subscribe('cache', '/cache')
            assert len(events('/cache', verification=True)) == 2
            passed('Verification cache survives retries filter changes renewal and restarts but expires five minutes after the original challenge', elapsed_seconds=round(time.monotonic() - cache_start, 2), challenges=2)
        finally:
            stop()
            RELEASE.set()
            receiver.shutdown()
            receiver.server_close()
            thread.join(timeout=5)
        record('cleanup', result='servers stopped; isolated mailbox, TLS keys, and fixture home removed on context exit')
except BaseException as error:
    record('failure', error=repr(error))
    print('FAIL ' + repr(error), flush=True)
    raise
finally:
    (EVIDENCE / 'live-mailbox-results.json').write_text(json.dumps(RESULTS, indent=2) + '\n')
    TRANSCRIPT.close()
