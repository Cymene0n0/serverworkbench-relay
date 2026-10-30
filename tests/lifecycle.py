#!/usr/bin/env python3
"""Unprivileged Linux tests. Every managed path is under a marked /tmp fixture."""
import hashlib
import fcntl
import json
import os
from pathlib import Path
import re
import socket
import socketserver
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import time

PROJECT=Path(__file__).resolve().parents[1]
ARCHIVE=Path(sys.argv[1]).resolve() if len(sys.argv)==2 else None
PIN='1d9875210972a5d1a62b2dc4c48df45ab0af05d3ca1b5e494a014428259df803'
assert ARCHIVE and ARCHIVE.is_file(), 'Pass the official Linux amd64 archive as the only argument.'
assert hashlib.sha256(ARCHIVE.read_bytes()).hexdigest()==PIN, 'Official fixture pin mismatch.'
SECRETS=[]
passed=0
def need(value,message):
    if not value: raise AssertionError(message)
def test(name,fn):
    global passed
    fn(); passed+=1; print('PASS '+name,flush=True)
def clean_output(value):
    for secret in SECRETS: value=value.replace(secret,'[REDACTED]')
    return value[-2500:]
class Fixture:
    def __init__(self):
        self.temp=tempfile.TemporaryDirectory(prefix='swb-relay-test-',dir='/tmp')
        self.root=Path(self.temp.name)
        (self.root/'.swb-relay-test-root').touch()
        self.env=dict(os.environ,SWB_RELAY_TESTING='1',SWB_RELAY_TEST_ROOT=str(self.root),
                      SWB_RELAY_FIXTURE_ARCHIVE=str(ARCHIVE))
        self.config=self.root/'etc/serverworkbench-relay'
        self.install=self.root/'usr/local/lib/serverworkbench-relay'
        self.unit=self.root/'etc/systemd/system/serverworkbench-relay.service'
        self.state=self.root/'var/lib/serverworkbench-relay'
    def run(self,*args,ok=True):
        r=subprocess.run(['bash',str(PROJECT/'relay.sh'),*args],env=self.env,cwd=PROJECT,
                         stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=90)
        if ok and r.returncode: raise AssertionError('Command failed: '+str(args)+'\n'+clean_output(r.stdout))
        if not ok and not r.returncode: raise AssertionError('Command unexpectedly succeeded: '+str(args))
        return r
    def token(self):
        t=(self.config/'frps.env').read_text().strip().split('=',1)[1]
        if t not in SECRETS: SECRETS.append(t)
        return t
    def snapshot(self):
        paths=list(self.config.iterdir())+list(self.install.rglob('*'))+[self.unit,self.root/'usr/local/bin/swb-relay']
        return {str(p.relative_to(self.root)):hashlib.sha256(p.read_bytes()).hexdigest()
                for p in paths if p.is_file()}
    def close(self): self.temp.cleanup()

def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1',0)); return s.getsockname()[1]
def port_open(port):
    try:
        with socket.create_connection(('127.0.0.1',port),timeout=.2): return True
    except OSError: return False
def until(check,seconds=10):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        if check(): return
        time.sleep(.1)
    raise AssertionError('Timed out waiting for isolated test condition.')
class Echo(socketserver.ThreadingTCPServer):
    allow_reuse_address=True
    daemon_threads=True
class EchoHandler(socketserver.BaseRequestHandler):
    def handle(self):
        while True:
            data=self.request.recv(65536)
            if not data: return
            self.request.sendall(data)

def native_tls(f):
    """Use the installed production-generated PKI and real official frps/frpc."""
    work=f.root/'native-tls'; work.mkdir()
    frpc=work/'frpc'
    with tarfile.open(ARCHIVE) as t:
        entry=t.getmember('frp_0.71.1_linux_amd64/frpc')
        need(entry.isfile() and entry.size<64*1024*1024,'Bad frpc fixture member.')
        with t.extractfile(entry) as stream: frpc.write_bytes(stream.read())
    frpc.chmod(0o700)
    control=free_port(); remote=free_port()
    while remote==control: remote=free_port()
    server_text=(f.config/'frps.toml').read_text().replace('"0.0.0.0"','"127.0.0.1"')
    server_text=server_text.replace('bindPort = 7000','bindPort = '+str(control))
    server_text=server_text.replace('single = 7777','single = '+str(remote))
    (work/'frps.toml').write_text(server_text)
    token=f.token()
    env=dict(os.environ,SWB_FRP_TOKEN=token)
    logs=[]; processes=[]
    def launch(binary,config,label,process_env):
        log=work/(label+'.log'); stream=log.open('wb'); logs.append(stream)
        p=subprocess.Popen([str(binary),'-c',str(config)],env=process_env,
                           stdout=stream,stderr=subprocess.STDOUT,start_new_session=True)
        processes.append(p); return p,log
    def stop(p):
        if p.poll() is None:
            p.terminate()
            try: p.wait(timeout=5)
            except subprocess.TimeoutExpired: p.kill(); p.wait(timeout=5)
    with Echo(('127.0.0.1',0),EchoHandler) as echo:
        thread=threading.Thread(target=echo.serve_forever,daemon=True); thread.start()
        def config(name,ca,server_name='kaifu-relay'):
            path=work/(name+'.toml')
            path.write_text('serverAddr = "127.0.0.1"\nserverPort = '+str(control)+'\n'
                'loginFailExit = true\nauth.method = "token"\nauth.token = "{{ .Envs.SWB_FRP_TOKEN }}"\n'
                'auth.additionalScopes = ["HeartBeats", "NewWorkConns"]\n'
                'transport.tls.enable = true\ntransport.tls.disableCustomTLSFirstByte = true\n'
                'transport.tls.trustedCaFile = '+json.dumps(str(ca))+'\n'
                'transport.tls.serverName = '+json.dumps(server_name)+'\n'
                'log.to = "console"\nlog.disablePrintColor = true\n'
                '[[proxies]]\nname = "swb-relay-test"\ntype = "tcp"\nlocalIP = "127.0.0.1"\n'
                'localPort = '+str(echo.server_address[1])+'\nremotePort = '+str(remote)+'\n')
            return path
        try:
            server,_=launch(f.install/'frps',work/'frps.toml','server',env)
            until(lambda: port_open(control))
            client,good_log=launch(frpc,config('good',f.config/'ca.crt'),'good',env)
            until(lambda: 'start proxy success' in good_log.read_text(errors='replace'))
            payload=os.urandom(128*1024)
            with socket.create_connection(('127.0.0.1',remote),timeout=5) as s:
                s.sendall(payload); got=bytearray()
                while len(got)<len(payload):
                    chunk=s.recv(len(payload)-len(got))
                    need(bool(chunk),'Forward closed before payload completion.'); got.extend(chunk)
            need(bytes(got)==payload,'Forwarded binary payload changed.')
            stop(client); until(lambda:not port_open(remote))
            bad_env=dict(env,SWB_FRP_TOKEN='0'*64)
            if bad_env['SWB_FRP_TOKEN']==token: bad_env['SWB_FRP_TOKEN']='1'*64
            bad,log=launch(frpc,config('wrong-token',f.config/'ca.crt'),'wrong-token',bad_env)
            bad.wait(timeout=10)
            need(bad.returncode!=0 and 'start proxy success' not in log.read_text(errors='replace'),
                 'Wrong token was accepted.')
            bad,log=launch(frpc,config('wrong-name',f.config/'ca.crt','wrong-relay'),'wrong-name',env)
            bad.wait(timeout=10)
            need(bad.returncode!=0 and 'start proxy success' not in log.read_text(errors='replace'),
                 'Wrong certificate name was accepted.')
            wrong=f.root/'wrong-pki'
            subprocess.run(['bash','-c','source "$1/relay.sh"; generate_pki "$2" kaifu-relay',
                            'test',str(PROJECT),str(wrong)],check=True,stdout=subprocess.DEVNULL,timeout=30)
            bad,log=launch(frpc,config('wrong-ca',wrong/'ca.crt'),'wrong-ca',env)
            bad.wait(timeout=10)
            need(bad.returncode!=0 and 'start proxy success' not in log.read_text(errors='replace'),
                 'Wrong CA was accepted.')
            need(not port_open(remote),'Rejected clients left the game forwarding endpoint open.')
            for path in work.iterdir():
                if path.suffix in ('.toml','.log'):
                    need(token.encode() not in path.read_bytes(),'Token leaked into native config/log.')
        finally:
            for p in reversed(processes): stop(p)
            for stream in logs: stream.close()
            echo.shutdown()

f=Fixture()
try:
    def first_install():
        r=f.run('install','--server','relay.example.com')
        token=f.token(); need(re.fullmatch('[a-f0-9]{64}',token),'Token format invalid.')
        need(token not in r.stdout,'Default output printed token.')
        need((f.root/'service-enabled').exists() and (f.root/'service-active').exists(),
             'Test service did not activate.')
        need(stat.S_IMODE(f.config.stat().st_mode)==0o750,'Config directory permissions wrong.')
        need(stat.S_IMODE((f.config/'frps.env').stat().st_mode)==0o600,'Token permissions wrong.')
        need(stat.S_IMODE((f.config/'server.key').stat().st_mode)==0o640,'Server-key permissions wrong.')
        need(not list(f.root.rglob('ca.key')),'CA private key retained.')
    test('Fresh isolated install validates official binary and keeps CA private key transient',first_install)
    def idempotent():
        before=f.snapshot(); events=(f.root/'service-events').read_text().count('restart')
        f.run('install','--server','relay.example.com')
        need(before==f.snapshot(),'Repeat installation changed credentials/config/binary.')
        need(events==(f.root/'service-events').read_text().count('restart'),'Repeat restarted active service.')
    test('Repeat install preserves credentials/config and active service',idempotent)
    def display_export():
        token=f.token()
        for cmd in ('status','config'):
            need(token not in f.run(cmd).stdout,'Read-only status leaked token.')
        need(token not in f.run('show-token',ok=False).stdout,'Piped show-token leaked token.')
        out=f.root/'client-export'; f.run('export-client','--output',str(out))
        need({p.name for p in out.iterdir()}=={'ca.crt','client.json'},'Export contains extra material.')
        for path in out.iterdir(): need(token.encode() not in path.read_bytes(),'Export leaked token.')
        need((out/'ca.crt').read_bytes()==(f.config/'ca.crt').read_bytes(),'Export CA changed.')
        f.run('export-client','--output',str(out),ok=False)
    test('Status/export omit Token; piped secret display and export overwrite are rejected',display_export)
    def export_parent_swap():
        outside=f.root/'outside-export-target'; outside.mkdir()
        sentinel=outside/'ca.crt'; sentinel.write_text('must remain unchanged'); sentinel.chmod(0o644)
        before=sentinel.stat()
        hostile=f.root/'untrusted-parent'; hostile.mkdir(); hostile.chmod(0o777)
        preexisting=hostile/'existing-link'; preexisting.symlink_to(outside,target_is_directory=True)
        f.run('export-client','--output',str(preexisting),ok=False)
        hooks=f.root/'python-test-hooks'; hooks.mkdir()
        # Deterministically simulate the attacker replacing the export directory
        # immediately after it is opened. No unrelated filesystem path is used.
        (hooks/'sitecustomize.py').write_text('''import os
_open=os.open
def swapped_open(path,flags,*args,**kwargs):
    fd=_open(path,flags,*args,**kwargs)
    if path=='racy-export' and kwargs.get('dir_fd') is not None and flags&os.O_DIRECTORY:
        parent=kwargs['dir_fd']
        os.rename('racy-export','retained-export',src_dir_fd=parent,dst_dir_fd=parent)
        os.symlink(os.environ['SWB_TEST_OUTSIDE_EXPORT'],'racy-export',dir_fd=parent)
        with open(os.environ['SWB_TEST_EXPORT_RACE_MARKER'],'w') as flag: flag.write('directory replaced')
    return fd
os.open=swapped_open
''')
        marker=f.root/'export-race-triggered'
        old_env=f.env.copy()
        try:
            f.env.update(PYTHONPATH=str(hooks),SWB_TEST_OUTSIDE_EXPORT=str(outside),
                         SWB_TEST_EXPORT_RACE_MARKER=str(marker))
            f.run('export-client','--output',str(hostile/'racy-export'),ok=False)
        finally: f.env=old_env
        need(marker.exists(),'Export race simulation was not reached.')
        need(sentinel.read_text()=='must remain unchanged' and sentinel.stat().st_ino==before.st_ino
             and stat.S_IMODE(sentinel.stat().st_mode)==0o644,'Export followed replacement path or changed its mode.')
        need(set(p.name for p in outside.iterdir())=={'ca.crt'},'Export wrote through an attacker-controlled symlink.')
        retained=hostile/'retained-export'
        need(set(p.name for p in retained.iterdir())=={'ca.crt','client.json'},'Bound directory did not retain safe public export.')
    test('Client export resists symlink destinations and a directory replacement race',export_parent_swap)
    test('Real frps/frpc TLS forwards 128KB and rejects wrong token, CA and hostname',lambda:native_tls(f))
    def upgrade():
        before=f.snapshot(); meta=json.loads((f.config/'node.json').read_text()); f.run('upgrade')
        after=f.snapshot(); new_meta=json.loads((f.config/'node.json').read_text())
        before.pop('etc/serverworkbench-relay/node.json'); after.pop('etc/serverworkbench-relay/node.json')
        meta.pop('updatedUtc'); new_meta.pop('updatedUtc')
        need(before==after and meta==new_meta,'Pinned upgrade changed credentials/config/binary.')
        need(any(f.state.glob('backup-*')),'Upgrade did not preserve backup.')
    test('Pinned upgrade preserves credentials and creates a backup',upgrade)
    def failed_upgrade():
        # Give the installed manager/wrapper/notice distinct prior contents so
        # rollback must restore them rather than leave the newly copied source.
        prior_runtime={p:p.read_bytes() for p in (f.install/'relay.sh',f.install/'lib/common.sh',
                       f.install/'lib/pins.sh',f.install/'LICENSE-frp.txt',f.root/'usr/local/bin/swb-relay')}
        for p,original in prior_runtime.items(): p.write_bytes(original+b'\n# prior installed release marker\n')
        before=f.snapshot(); (f.root/'service-enabled').unlink()
        (f.root/'fail-restart').touch()
        try: f.run('upgrade',ok=False)
        finally: (f.root/'fail-restart').unlink()
        need(before==f.snapshot(),'Failed upgrade did not restore prior data.')
        need(not (f.root/'service-enabled').exists(),'Rollback unexpectedly enabled a previously disabled service.')
        for p,original in prior_runtime.items(): p.write_bytes(original)
        f.run('install','--server','relay.example.com')
    test('Activation failure restores distinct prior runtime/wrapper and previous enabled state',failed_upgrade)
    def first_activation_failure():
        other=Fixture()
        try:
            (other.root/'fail-restart').touch()
            other.run('install','--server','relay.example.com',ok=False)
            need(not (other.root/'service-enabled').exists(),'Failed first install left autostart enabled.')
            need(not (other.root/'service-active').exists(),'Failed first install left active service.')
            need(not other.unit.exists(),'Failed first install left new active unit installed.')
            token=other.token(); ca=(other.config/'ca.crt').read_bytes()
            (other.root/'fail-restart').unlink()
            other.run('uninstall')
            need(not (other.install/'frps').exists(),'Failed activation could not be uninstalled after the unit was removed.')
            need(token==other.token() and ca==(other.config/'ca.crt').read_bytes(),
                 'Uninstall after failed activation changed preserved credentials.')
            other.run('install','--server','relay.example.com')
            need(token==other.token() and ca==(other.config/'ca.crt').read_bytes(),
                 'Retry after failed first activation replaced preserved credentials.')
        finally: other.close()
    test('Failed first activation cannot enable autostart; retry preserves credentials',first_activation_failure)
    def lock_and_dry_run():
        other=Fixture()
        try:
            before={str(p.relative_to(other.root)) for p in other.root.rglob('*')}
            other.run('install','--server','relay.example.com','--dry-run')
            need(before=={str(p.relative_to(other.root)) for p in other.root.rglob('*')},
                 'Dry-run mutated managed files.')
        finally: other.close()
        before=f.snapshot()
        with (f.state/'manager.lock').open('a') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            f.run('upgrade',ok=False)
        need(before==f.snapshot(),'Concurrent operation changed managed files despite lock.')
    test('Dry-run is read-only and concurrent manager operations are locked out',lock_and_dry_run)
    def renew():
        token=f.token(); old_ca=(f.config/'ca.crt').read_bytes(); before=f.snapshot()
        f.run('renew',ok=False); need(before==f.snapshot(),'Unconfirmed CA rotation changed files.')
        f.run('renew','--rotate-ca')
        need(old_ca!=(f.config/'ca.crt').read_bytes(),'Explicit rotation kept old CA.')
        need(token==f.token(),'CA rotation unexpectedly changed token.')
        need(not list(f.root.rglob('ca.key')),'Rotated CA private key retained.')
    test('CA rotation requires explicit flag, changes trust and preserves Token',renew)
    def uninstall_failure():
        before=f.snapshot(); (f.root/'fail-stop').touch()
        try: f.run('uninstall',ok=False)
        finally: (f.root/'fail-stop').unlink()
        need(before==f.snapshot() and (f.root/'service-active').exists(),
             'Stop failure removed files or falsely claimed the live service stopped.')
        (f.root/'fail-disable').touch()
        try: f.run('uninstall',ok=False)
        finally: (f.root/'fail-disable').unlink()
        need(before==f.snapshot() and (f.root/'service-enabled').exists(),
             'Disable failure removed a unit/binary that can still autostart.')
        f.run('install','--server','relay.example.com')
    test('Uninstall refuses to remove files when stop or disable cannot be confirmed',uninstall_failure)
    def uninstall():
        ca=(f.config/'ca.crt').read_bytes(); token=f.token()
        f.run('uninstall')
        need(not f.unit.exists() and not (f.install/'frps').exists(),'Uninstall kept active service/binary.')
        need(not (f.root/'service-enabled').exists() and not (f.root/'service-active').exists(),
             'Uninstall left service active/enabled.')
        need(ca==(f.config/'ca.crt').read_bytes() and token==f.token(),'Uninstall deleted credentials.')
        # A previously removed unit/binary must not mask a still-running cached
        # systemd service or its enabled state on a second uninstall.
        (f.root/'service-active').touch(); (f.root/'service-enabled').touch()
        f.run('uninstall')
        need(not (f.root/'service-active').exists() and not (f.root/'service-enabled').exists(),
             'Repeated uninstall ignored a lingering active/enabled service.')
        f.run('install','--server','relay.example.com','--no-start')
        need(ca==(f.config/'ca.crt').read_bytes() and token==f.token(),'Reinstall rotated credentials.')
        need(not (f.root/'service-active').exists(),'--no-start activated service.')
    test('Uninstall/reinstall preserves credentials and --no-start stays inactive',uninstall)
    def bad_fixture():
        other=Fixture()
        try:
            fake=other.root/'not-official.tar.gz'; fake.write_bytes(b'not an official release')
            other.env['SWB_RELAY_FIXTURE_ARCHIVE']=str(fake)
            other.run('install','--server','relay.example.com',ok=False)
            need(not (other.install/'frps').exists(),'Bad download was installed.')
            need(not (other.root/'service-active').exists(),'Bad download activated service.')
        finally: other.close()
    test('Injected download fixture cannot bypass archive pin',bad_fixture)
    def foreign_directory():
        other=Fixture()
        try:
            other.config.mkdir(parents=True); sentinel=other.config/'user-owned'; sentinel.write_text('preserve')
            other.run('install','--server','relay.example.com',ok=False)
            need(sentinel.read_text()=='preserve','Foreign directory content changed.')
            need(not (other.config/'.managed').exists(),'Foreign directory was adopted.')
        finally: other.close()
    test('Foreign configuration directories are refused without mutation',foreign_directory)
    def symlink_path():
        other=Fixture()
        try:
            outside=other.root/'outside'; outside.mkdir()
            sentinel=outside/'sentinel'; sentinel.write_text('preserve')
            other.config.parent.mkdir(parents=True)
            other.config.symlink_to(outside,target_is_directory=True)
            other.run('install','--server','relay.example.com',ok=False)
            need(sentinel.read_text()=='preserve' and set(p.name for p in outside.iterdir())=={'sentinel'},
                 'Symlink target was modified.')
        finally: other.close()
    test('Symlink-managed paths are refused without traversing targets',symlink_path)
    print('RESULT passed='+str(passed)+' failed=0',flush=True)
finally:
    f.close()
