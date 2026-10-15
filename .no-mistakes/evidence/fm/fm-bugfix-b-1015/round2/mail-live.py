import os, pathlib, socketserver, ssl, subprocess, sys, threading, time
root = pathlib.Path(sys.argv[1])
work = root / '.test-phase/mail-live'
work.mkdir(exist_ok=True)
mode = {'delay': 0, 'mail': False, 'fetch_delay': 0}
class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        settings = dict(mode)
        def send(s):
            self.wfile.write(s.encode()); self.wfile.flush()
        try:
            time.sleep(settings['delay'])
            send('* OK disposable IMAP ready\r\n')
            while row := self.rfile.readline():
                words = row.decode().strip().split()
                if len(words) < 2: return
                tag, cmd = words[:2]; cmd = cmd.upper()
                print('imap command:', cmd, flush=True)
                if cmd == 'CAPABILITY':
                    send('* CAPABILITY IMAP4rev1\r\n' + tag + ' OK capability\r\n')
                elif cmd == 'LOGIN': send(tag + ' OK login\r\n')
                elif cmd in ('SELECT', 'EXAMINE'):
                    send('* 2 EXISTS\r\n* OK [UIDVALIDITY 12345]\r\n' + tag + ' OK selected\r\n')
                elif cmd == 'UID' and words[2].upper() == 'SEARCH':
                    send('* SEARCH' + (' 42 43' if settings['mail'] else '') + '\r\n' + tag + ' OK search\r\n')
                elif cmd == 'UID' and words[2].upper() == 'FETCH':
                    uid = words[3]
                    if uid == '43': time.sleep(settings['fetch_delay'])
                    data = f'From: lab@example.invalid\r\nSubject: disposable mail {uid}\r\nDate: Fri, 16 Oct 2026 03:00:00 +0000\r\n\r\n'
                    send(f'* 1 FETCH (UID {uid} BODY[HEADER] {{{len(data)}}}\r\n{data})\r\n{tag} OK fetch\r\n')
                elif cmd == 'LOGOUT': send('* BYE logout\r\n' + tag + ' OK logout\r\n'); return
                else: send(tag + ' BAD unsupported\r\n')
        except (OSError, ssl.SSLError): pass
class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    def get_request(self):
        conn, addr = super().get_request()
        return tls.wrap_socket(conn, server_side=True), addr

tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(root / '.test-phase/imap.crt', root / '.test-phase/imap.key')
server = Server(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI'))}
env.update(FM_MAIL_USER='lab@example.invalid', FM_MAIL_PASS='disposable', FM_IMAP_HOST='localhost', FM_SMTP_HOST='localhost', FM_IMAP_PORT=str(server.server_address[1]), SSL_CERT_FILE=str(root / '.test-phase/imap.crt'), TMPDIR=str(root / '.test-phase/runtime'))
def check(name, home, **settings):
    mode.update(delay=0, mail=False, fetch_delay=0)
    mode.update(settings)
    home = work / home
    home.mkdir(exist_ok=True)
    e = dict(env, FM_HOME=str(home))
    if name != 'healthy-nine-seconds': e['FM_MAIL_CHECK_BUDGET'] = '5'
    start = time.monotonic()
    result = subprocess.run(['bash', str(root/'bin/fm-mail-check.sh'), 'check'], env=e, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=35)
    elapsed = time.monotonic()-start
    print(f'{name}: rc={result.returncode} elapsed={elapsed:.2f}s output={result.stdout.strip()!r}', flush=True)
    record = home/'state/.mail-check'
    if record.exists(): print(record.read_text(), end='', flush=True)
    assert result.returncode == 0
    return result.stdout, home
try:
    out,_ = check('healthy-nine-seconds','healthy',delay=9)
    assert not out, out
    out,_ = check('one-deadline-miss','transient',delay=6)
    assert not out, out
    out,_ = check('healthy-recovery','transient')
    assert not out, out
    out,_ = check('new-first-miss','repeated',delay=6)
    assert not out, out
    out,_ = check('second-consecutive-miss','repeated',delay=6)
    assert 'mail poll deadline reached' in out, out
    out,_ = check('already-reported-miss','repeated',delay=6)
    assert not out, out
    out, home = check('queued-mail-and-slow-header','new-mail',mail=True,fetch_delay=6)
    assert 'new mail: woke for' in out, out
    queue=(home/'state/.wake-queue').read_text()
    print('published queue:\n' + queue, flush=True)
    assert 'disposable mail 42' in queue
    server.shutdown(); server.server_close()
    out,_ = check('connection-refused-reports-immediately','outage')
    assert 'Connection refused' in out or 'connection refused' in out, out
    print('LIVE MAIL SCENARIOS PASSED',flush=True)
finally:
    server.shutdown(); server.server_close()
