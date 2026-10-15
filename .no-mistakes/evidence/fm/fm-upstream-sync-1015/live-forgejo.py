import base64
import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request

root = Path.cwd()
lab = Path(tempfile.mkdtemp(prefix='forgejo.', dir=root / '.no-mistakes/test-tmp'))
tools = root / '.no-mistakes/live-tools'
evidence = Path('/home/bohn/.no-mistakes/evidence/01M4ZWV8H0KM2V907GBD81WBZV')
env = dict(os.environ)
for key in ['GIT_DIR', 'GIT_COMMON_DIR', 'GIT_WORK_TREE', 'FM_ROOT_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE']:
    env.pop(key, None)
env.update(HOME=str(lab / 'user'), XDG_CONFIG_HOME=str(lab / 'user/config'), GIT_CONFIG_GLOBAL=str(lab / 'user/.gitconfig'), GIT_CONFIG_SYSTEM='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid', GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid', PATH=str(tools) + ':' + env['PATH'])
(lab / 'user').mkdir()
server = None
proxy = None
fault = None
requests = []

def run(args, expected=0, visible=False):
    p = subprocess.run([str(x) for x in args], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=80)
    if visible:
        print('$ ' + ' '.join(str(x) for x in args), flush=True)
        print(p.stdout.rstrip(), flush=True)
        print('exit=' + str(p.returncode), flush=True)
    assert p.returncode == expected, (args, p.returncode, p.stdout)
    return p.stdout.strip()

def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]

port = free_port()
url = f'http://127.0.0.1:{port}'
auth = 'Basic ' + base64.b64encode(b'fixture:FixturePassword123!').decode()

def api(path, data=None, method=None):
    headers = {'Authorization': auth, 'Content-Type': 'application/json'}
    req = urllib.request.Request(url + '/api/v1' + path, data=json.dumps(data).encode() if data is not None else None, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read() or b'null')

class Proxy(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.forward()
    def do_POST(self):
        self.forward()
    def log_message(self, *args):
        pass
    def forward(self):
        requests.append([self.command, self.path])
        if fault and '/status?' in self.path and 'page=3' in self.path:
            body = json.dumps(fault).encode()
            status = 200
        else:
            body_in = self.rfile.read(int(self.headers.get('Content-Length', 0)))
            req = urllib.request.Request(url + self.path, data=body_in if body_in else None, headers={k:v for k,v in self.headers.items() if k.lower() not in ['host','content-length']}, method=self.command)
            try:
                with urllib.request.urlopen(req, timeout=15) as response:
                    body, status = response.read(), response.status
            except urllib.error.HTTPError as response:
                body, status = response.read(), response.code
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

try:
    cfg = lab / 'app.ini'
    cfg.write_text(f'''APP_NAME = Firstmate disposable verification
RUN_MODE = prod
RUN_USER = {os.environ['USER']}
WORK_PATH = {lab}
[database]
DB_TYPE = sqlite3
PATH = {lab}/forgejo.db
[repository]
ROOT = {lab}/repos
DEFAULT_BRANCH = main
[server]
APP_DATA_PATH = {lab}/data
HTTP_ADDR = 127.0.0.1
HTTP_PORT = {port}
ROOT_URL = {url}/
DISABLE_SSH = true
OFFLINE_MODE = true
[security]
INSTALL_LOCK = true
[service]
DISABLE_REGISTRATION = true
[log]
MODE = file
ROOT_PATH = {lab}/logs
LEVEL = Error
[actions]
ENABLED = false
[cron]
ENABLED = false
''')
    common = ['--work-path', lab, '--config', cfg]
    print(run([tools / 'forgejo', '--version']), flush=True)
    print(run([tools / 'tea', '--version']), flush=True)
    run([tools / 'forgejo', 'migrate', *common])
    run([tools / 'forgejo', 'admin', 'user', 'create', *common, '--username', 'fixture', '--password', 'FixturePassword123!', '--email', 'fixture@example.invalid', '--admin', '--must-change-password=false'])
    log = open(lab / 'server.log', 'w')
    server = subprocess.Popen([str(tools / 'forgejo'), 'web', *map(str, common)], env=env, stdout=log, stderr=subprocess.STDOUT)
    for _ in range(120):
        try:
            api('/version')
            break
        except Exception:
            assert server.poll() is None, (lab / 'server.log').read_text()
            time.sleep(.25)
    else:
        raise AssertionError('Forgejo did not start')
    proxy = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Proxy)
    threading.Thread(target=proxy.serve_forever, daemon=True).start()
    proxy_url = f'http://localhost:{proxy.server_address[1]}'
    token = api('/users/fixture/tokens', {'name':'test-only','scopes':['all']})['sha1']
    run([tools / 'tea', 'login', 'add', '--name', 'lab', '--url', proxy_url, '--token', token])
    run([tools / 'tea', 'login', 'list', '--output', 'json'], visible=True)
    api('/user/repos', {'name':'repo', 'default_branch':'main', 'auto_init':False})
    repo = lab / 'checkout'
    run(['git','init','-q','-b','main',repo])
    (repo / 'feature.txt').write_text('base\n')
    run(['git','-C',repo,'add','.'])
    run(['git','-C',repo,'commit','-qm','baseline'])
    remote = f'http://fixture:FixturePassword123!@127.0.0.1:{port}/fixture/repo.git'
    run(['git','-C',repo,'remote','add','origin',remote])
    run(['git','-C',repo,'push','-q','origin','main'])
    run(['git','-C',repo,'checkout','-qb','task'])
    (repo / 'feature.txt').write_text('task\n')
    run(['git','-C',repo,'commit','-qam','task'])
    run(['git','-C',repo,'push','-q','origin','task'])
    head = run(['git','-C',repo,'rev-parse','HEAD'])
    pr = api('/repos/fixture/repo/pulls', {'head':'task','base':'main','title':'Disposable verification'})
    number = pr['number']
    for _ in range(60):
        pr = api(f'/repos/fixture/repo/pulls/{number}')
        if pr['mergeable']:
            break
        time.sleep(.25)
    assert pr['mergeable'], pr
    home = lab / 'home'
    run(['bash', root / 'bin/fm-lab-home.sh','create',home])
    env['FM_HOME'] = str(home)
    (home / 'state/task.meta').write_text(f'kind=ship\nmode=direct-PR\nyolo=on\nproject={repo}\nworktree={repo}\npr=https://localhost/fixture/repo/pulls/{number}\npr_head={head}\n')
    merge = ['bash', root / 'bin/fm-pr-merge.sh', 'task', f'https://localhost/fixture/repo/pulls/{number}', '--attended-override']
    for i in range(51):
        api(f'/repos/fixture/repo/statuses/{head}', {'state':'failure' if i==0 else 'success','context':f'check-{i:02}','description':'disposable'})
    requests.clear()
    print('\nA failing status on page 2 must refuse the merge', flush=True)
    run(merge, expected=1, visible=True)
    assert not any(m=='POST' and p.endswith('/merge') for m,p in requests), requests
    assert not api(f'/repos/fixture/repo/pulls/{number}')['merged']
    print('PR remains unmerged; no merge request was sent.', flush=True)
    api(f'/repos/fixture/repo/statuses/{head}', {'state':'success','context':'check-00','description':'disposable'})
    for payload in [{'message':'unavailable'}, {'statuses':[]}, {'statuses':[], 'state':'success'}]:
        fault = payload
        requests.clear()
        print('\nFault injected after two real successful status pages: '+json.dumps(payload), flush=True)
        run(merge, expected=1, visible=True)
        assert any('/status?' in p and 'page=3' in p for m,p in requests), requests
        assert not any(m=='POST' and p.endswith('/merge') for m,p in requests), requests
        assert not api(f'/repos/fixture/repo/pulls/{number}')['merged']
        print('PR remains unmerged; no merge request was sent.', flush=True)
    fault = None
    requests.clear()
    print('\nEvery status page is valid and green', flush=True)
    run(merge, visible=True)
    final = api(f'/repos/fixture/repo/pulls/{number}')
    assert final['merged'] is True
    print(json.dumps({'number':number, 'state':final['state'], 'merged':final['merged'], 'head':final['head']['sha'], 'merge_commit_sha':final['merge_commit_sha']}, indent=2), flush=True)
    print('Real Forgejo read-back confirms the merge.', flush=True)
finally:
    if proxy:
        proxy.shutdown()
        proxy.server_close()
    if server:
        server.terminate()
        try:
            server.wait(15)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
    if (lab / 'server.log').exists():
        shutil.copyfile(lab / 'server.log', evidence / 'forgejo-server.log')
    shutil.rmtree(lab)
