#!/usr/bin/env python3
"""Isolated real Linux/OpenResty integration. No production paths or services are used."""
from __future__ import annotations

import argparse
import concurrent.futures
import datetime
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import pwd
import secrets
import signal
import socket
import ssl
import subprocess
import tempfile
import threading
import time

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ed25519, rsa
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID

PLUGIN = Path(__file__).resolve().parents[2]
LEGACY = PLUGIN.parent / 'lua_files'
if not (LEGACY / 'lib/route.lua').is_file():
    LEGACY = PLUGIN / 'tests/fixtures/legacy'


def pem(key):
    return key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                             serialization.NoEncryption()).decode()


def public(key):
    return key.public_key().public_bytes(serialization.Encoding.PEM,
                                         serialization.PublicFormat.SubjectPublicKeyInfo).decode()


def lua(value):
    if value is None:
        return 'nil'
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return '{' + ','.join(map(lua, value)) + '}'
    return '{' + ','.join('[' + lua(k) + ']=' + lua(v) for k, v in value.items()) + '}'


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8')
    path.chmod(0o600)


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def certificate(key, name, issuer_key=None, issuer=None, purpose=None, ca=False):
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, name)])
    now = datetime.datetime.now(datetime.timezone.utc)
    builder = (x509.CertificateBuilder().subject_name(subject).issuer_name(issuer or subject)
        .public_key(key.public_key()).serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(hours=1)).not_valid_after(now + datetime.timedelta(days=7))
        .add_extension(x509.BasicConstraints(ca=ca, path_length=0 if ca else None), critical=True))
    if purpose:
        builder = builder.add_extension(x509.ExtendedKeyUsage([purpose]), critical=False)
    if not ca:
        builder = builder.add_extension(x509.SubjectAlternativeName([x509.DNSName(name)]), critical=False)
    signed = builder.sign(issuer_key or key, hashes.SHA256())
    return signed, signed.public_bytes(serialization.Encoding.PEM).decode()


class Process:
    def __init__(self, name, args, root):
        self.name, self.args = name, args
        self.log_path = root / (name + '.log')
        self.process = None
        self.log = None

    def start(self):
        self.log = self.log_path.open('ab')
        self.process = subprocess.Popen(self.args, stdout=self.log, stderr=self.log, start_new_session=True)

    def pause(self):
        os.killpg(self.process.pid, signal.SIGSTOP)

    def resume(self):
        if self.process and self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGCONT)

    def stop(self):
        if self.process and self.process.poll() is None:
            self.resume()
            os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=5)
        if self.log:
            self.log.close()


class Origin(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = self.server.label.encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'public, max-age=60')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class SlowHeaders(Origin):
    def do_GET(self):
        try:
            self.wfile.write(b'HTTP/1.1 200 OK\r\nX-Slow: ')
            self.wfile.flush()
            for _ in range(30):
                time.sleep(0.1)
                self.wfile.write(b'x')
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


class Integration:
    def __init__(self, root, prefix):
        self.root, self.prefix = root, prefix
        self.processes, self.results, self.nodes, self.origins = [], [], {}, []
        self.master_port = free_port()
        self.internal_token = secrets.token_urlsafe(32)
        self.library_args = ['-I', str(PLUGIN / 'lib'), '-I', str(PLUGIN / 'vendor/lua-resty-http/lib')]
        self.resty = str(prefix / 'bin/resty')
        self.nginx = str(prefix / 'nginx/sbin/nginx')

    def check(self, name, condition=True):
        if not condition:
            raise AssertionError(name)
        self.results.append(name)
        print('PASS ' + name, flush=True)

    def until(self, predicate, description, seconds=20):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                value = predicate()
                if value:
                    return value
            except (OSError, ssl.SSLError, http.client.HTTPException, ValueError, KeyError):
                pass
            for process in self.processes:
                if process.process and process.process.poll() is not None:
                    raise RuntimeError(process.name + ' exited; ' + process.log_path.read_text()[-3000:])
            time.sleep(0.1)
        raise AssertionError('deadline: ' + description)

    def context(self, node=None):
        context = ssl.create_default_context(cafile=str(self.root / 'etc/ca.crt'))
        if node:
            context.load_cert_chain(str(self.root / f'etc/{node}.crt'), str(self.root / f'etc/{node}.key'))
        return context

    def master(self, node, path='/_scdn_sync/v1/desired', method='GET', headers=None, body=None, timeout=4):
        # Explicit SNI while the transport stays loopback-only.
        connection = http.client.HTTPSConnection('localhost', self.master_port, context=self.context(node), timeout=timeout)
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        result = response.status, dict(response.getheaders()), response.read()
        connection.close()
        return result

    def business(self, node, host='www.example.com', path='/asset', tls=False):
        port = self.nodes[node]['https_port' if tls else 'http_port']
        if tls:
            context = ssl._create_unverified_context()
            raw = socket.create_connection(('127.0.0.1', port), timeout=3)
            transport = context.wrap_socket(raw, server_hostname=host)
            fingerprint = hashlib.sha256(transport.getpeercert(binary_form=True)).hexdigest()
            connection = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
            connection.sock = transport
        else:
            connection, fingerprint = http.client.HTTPConnection('127.0.0.1', port, timeout=3), None
        connection.request('GET', path, headers={'Host': host})
        response = connection.getresponse()
        result = response.status, dict(response.getheaders()), response.read(), fingerprint
        connection.close()
        return result

    def control(self, node, action='status', token=True, method='GET', body=None):
        connection = http.client.HTTPConnection('localhost', timeout=4)
        connection.sock = socket.socket(socket.AF_UNIX)
        connection.sock.settimeout(4)
        connection.sock.connect(self.nodes[node]['control_socket'])
        headers = {'Content-Type': 'application/json'}
        if token:
            headers['X-Scdn-Control'] = self.nodes[node]['token']
        connection.request(method, '/__scdn_sync/v1/' + action, body=body, headers=headers)
        response = connection.getresponse()
        result = response.status, response.read()
        connection.close()
        return result

    def launch(self, name, config):
        prefix = self.root / ('run/' + name)
        prefix.mkdir(parents=True, exist_ok=True)
        process = Process(name, [self.nginx, '-p', str(prefix) + '/', '-e', 'stderr', '-c', str(config), '-g', 'daemon off;'], self.root)
        self.processes.append(process)
        process.start()
        return process

    def driver(self, action, config, value):
        with tempfile.NamedTemporaryFile(mode='w', dir=self.root, suffix='.input', delete=False) as payload:
            json.dump(value, payload)
        try:
            result = subprocess.run([self.resty, *self.library_args, str(PLUGIN / 'tests/integration/driver.lua'),
                action, str(config), payload.name], capture_output=True, text=True, timeout=30)
            if result.returncode:
                raise RuntimeError('test driver failed: ' + result.stderr[-2500:])
            return json.loads(result.stdout)
        finally:
            Path(payload.name).unlink()

    def publish(self, node, origin=0, enabled=True, empty=False, version=1, cert_version=1, host='www.example.com'):
        site = dict(site_id='site-demo', resource_version=version, name='demo', enabled=enabled,
            server_names=[host], root='', upstream=f'127.0.0.1:{self.origins[origin].server_port}',
            cache={'layer': 'off' if origin else 'l2'}, ssl={'enabled': True, 'certificate_id': 'cert-demo', 'certificate_version': cert_version},
            rate_limit={'enabled': False, 'req_per_sec': 50, 'burst': 100},
            waf={'enabled': True, 'groups': ['sqli', 'xss'], 'threshold': 5}, locations=[])
        return self.driver('publish', self.root / 'etc/publisher.lua', dict(node_id=node, scope_id='edge',
            ttl_seconds=300, sites=[] if empty else [site], certificates=([self.materials[cert_version]] if enabled and not empty else []),
            tombstones=['site-demo'] if empty else []))

    def watch_files(self):
        sites, certs = self.root / 'watch/sites', self.root / 'watch/certificates'
        sites.mkdir(parents=True)
        sites.chmod(0o750)
        certs.mkdir()
        write(certs / 'site.pem', self.materials[1]['chain_pem'])
        write(certs / 'site.key', self.materials[1]['private_key_pem'])
        value = dict(name='demo', enabled=True, server_names=['www.example.com'], root='',
            upstream=f'127.0.0.1:{self.origins[0].server_port}', cache={'layer': 'off'},
            ssl={'cert': str(certs / 'site.pem'), 'key': str(certs / 'site.key')},
            rate_limit={'enabled': False, 'req_per_sec': 0, 'burst': 0, 'conn': 100},
            waf={'enabled': True, 'groups': ['sqli', 'xss'], 'threshold': 5})
        path = sites / 'demo.lua'
        def replace(target, content):
            temporary = target.with_suffix(target.suffix + '.tmp')
            write(temporary, content)
            os.replace(temporary, target)
        replace(path, 'return ' + lua(value))
        watch_config = dict(poll_seconds=0.1, settle_seconds=0.4, ttl_seconds=300, renew_before_seconds=60,
            scopes=[dict(scope_id='edge', sites_dir=str(sites), node_ids=list(self.nodes),
                         certificate_roots=[str(certs)], allow_empty=True)])
        config_path = self.root / 'etc/master-watch.lua'
        write(config_path, 'local s=dofile(' + lua(str(self.root / 'etc/publisher.lua')) + '); s.watch='
              + lua(watch_config) + '; return s')
        def desired(node):
            return json.loads((self.root / f'data/master/nodes/{node}/desired.json').read_text())
        def advanced(previous):
            current = {}
            for node in self.nodes:
                self.until(lambda: desired(node)['revision_id'] != previous[node]['revision_id'], 'file watch publish ' + node)
                current[node] = desired(node)
                self.wait_applied(node, current[node]['revision_id'])
            return current
        previous = {node: desired(node) for node in self.nodes}
        watcher = Process('master-watch', [self.resty, *self.library_args, str(PLUGIN / 'bin/watch.lua'), str(config_path)], self.root)
        self.processes.append(watcher)
        watcher.start()
        previous = advanced(previous)
        self.check('Master watcher publishes original Lua site files and both nodes apply automatically',
            all(self.business(node)[2] == b'origin-0' and desired(node).get('source_id') for node in self.nodes))
        worker_pids = {node: [w['pid'] for w in json.loads(self.control(node)[1])['workers']] for node in self.nodes}
        raw = socket.create_connection(('127.0.0.1', self.nodes['node-a']['https_port']), timeout=4)
        transport = ssl._create_unverified_context().wrap_socket(raw, server_hostname='www.example.com')
        persistent = http.client.HTTPConnection('127.0.0.1', self.nodes['node-a']['https_port'], timeout=4)
        persistent.sock = transport
        persistent.request('GET', '/asset', headers={'Host': 'www.example.com'})
        response = persistent.getresponse()
        assert response.status == 200 and response.read() == b'origin-0'
        failures, samples, stopped = [], [], threading.Event()
        def traffic():
            while not stopped.wait(0.02):
                try:
                    status, _, body, _ = self.business('node-a')
                    samples.append(status)
                    if status != 200 or body not in (b'origin-0', b'origin-1'):
                        failures.append((status, body[:32]))
                except Exception as error:
                    failures.append(type(error).__name__)
        thread = threading.Thread(target=traffic, daemon=True)
        thread.start()
        try:
            # A file opened by an editor is not necessarily a complete new configuration.
            write(path, 'return { name = ')
            time.sleep(0.9)
            self.check('half-written watched file preserves previous desired and active routing',
                all(desired(node)['revision_id'] == previous[node]['revision_id'] for node in self.nodes)
                and self.business('node-a')[2] == b'origin-0')
            value['upstream'] = f'127.0.0.1:{self.origins[1].server_port}'
            replace(path, 'return ' + lua(value) + '\n-- first edit\n')
            time.sleep(0.1)
            replace(path, 'return ' + lua(value) + '\n-- final edit\n')
            updated = advanced(previous)
            self.check('atomic replacements and rapid edits produce one automatic publication per node',
                all(int(updated[n]['desired_seq']) == int(previous[n]['desired_seq']) + 1 for n in self.nodes)
                and all(self.business(n)[2] == b'origin-1' for n in self.nodes))
            previous = updated
            extra = dict(value, name='extra', server_names=['added.example.com'], ssl={'cert': '', 'key': ''})
            replace(sites / 'extra.lua', 'return ' + lua(extra))
            previous = advanced(previous)
            self.check('adding a watched site file creates live routing automatically',
                all(self.business(n, host='added.example.com')[2] == b'origin-1' for n in self.nodes))
            (sites / 'extra.lua').unlink()
            previous = advanced(previous)
            self.check('removing a watched site file removes routing automatically',
                all(self.business(n, host='added.example.com')[0] == 403 for n in self.nodes))
            replace(certs / 'site.pem', self.materials[2]['chain_pem'])
            replace(certs / 'site.key', self.materials[2]['private_key_pem'])
            previous = advanced(previous)
            expected = x509.load_pem_x509_certificate(self.materials[2]['chain_pem'].encode()).fingerprint(hashes.SHA256()).hex()
            self.check('replacing certificate files on the same paths rotates new TLS handshakes automatically',
                all(self.business(n, tls=True)[3] == expected for n in self.nodes))
            persistent.request('GET', '/asset', headers={'Host': 'www.example.com'})
            response = persistent.getresponse()
            self.check('automatic reload keeps worker PIDs and an established TLS connection',
                response.status == 200 and response.read() == b'origin-1' and persistent.sock is transport
                and all([w['pid'] for w in json.loads(self.control(n)[1])['workers']] == worker_pids[n] for n in self.nodes))
            watcher.stop()
            watcher.start()
            time.sleep(1.1)
            self.check('restarting the watcher does not duplicate unchanged publications',
                all(desired(n)['revision_id'] == previous[n]['revision_id'] for n in self.nodes))
        finally:
            stopped.set()
            thread.join(timeout=4)
            persistent.close()
        self.check('HTTP sampling stays available throughout watched updates', len(samples) > 10 and not failures)
        value['enabled'] = False
        replace(path, 'return ' + lua(value))
        previous = advanced(previous)
        self.check('watched disable updates every node without certificate objects',
            all(self.business(n)[0] == 403 and not previous[n]['objects'] for n in self.nodes))
        path.unlink()
        previous = advanced(previous)
        self.check('explicit empty-directory policy synchronizes removal of the final site',
            all(self.business(n)[0] == 403 for n in self.nodes))
        watcher.stop()
        self.check('watching existing source directories preserves their permissions', (sites.stat().st_mode & 0o777) == 0o750)

    def wait_applied(self, node, revision):
        def applied():
            path = self.root / f'data/{node}/applied.json'
            return path.exists() and json.loads(path.read_text())['revision_id'] == revision
        self.until(applied, node + ' apply ' + revision)

    def heartbeat_fixture(self, node):
        stored = json.loads((self.root / ('data/master/nodes/' + node + '/state.json')).read_text())
        heartbeat = dict(protocol='scdn.sync.v1', node_id=node,
            request_id=stored['last_heartbeat_receipt']['request_id'], heartbeat_seq=stored['heartbeat_seq'])
        if stored.get('observed_revision'):
            heartbeat['applied_revision'] = stored['observed_revision']
        body = json.dumps(heartbeat, separators=(',', ':'), sort_keys=True)
        assert hashlib.sha256(body.encode()).hexdigest() == stored['last_heartbeat_receipt']['digest']
        headers = self.driver('sign', self.root / ('etc/' + node + '-agent.lua'), dict(path='/_scdn_sync/v1/heartbeat', body=body))
        return headers, body

    def slow_upload(self):
        _, body = self.heartbeat_fixture('node-b')
        declared = body.ljust(4096)
        signed_headers = self.driver('sign', self.root / 'etc/node-b-agent.lua',
            dict(path='/_scdn_sync/v1/heartbeat', body=declared))
        raw = socket.create_connection(('127.0.0.1', self.master_port), timeout=7)
        transport = self.context('node-b').wrap_socket(raw, server_hostname='localhost')
        header_lines = ''.join(key + ': ' + value + '\r\n' for key, value in signed_headers.items())
        transport.sendall((f'POST /_scdn_sync/v1/heartbeat HTTP/1.1\r\nHost: localhost:{self.master_port}\r\n'
            + header_lines + 'Content-Length: 4096\r\nConnection: close\r\n\r\n' + declared[0]).encode())
        stopped = threading.Event()
        def drip():
            while not stopped.wait(0.2):
                try:
                    transport.sendall(b'x')
                except OSError:
                    return
        sender = threading.Thread(target=drip, daemon=True)
        sender.start()
        started = time.monotonic()
        response = http.client.HTTPResponse(transport)
        try:
            try:
                response.begin()
                result = response.status == 408
                response.read()
            except (http.client.RemoteDisconnected, ConnectionResetError, ssl.SSLEOFError):
                # Cancelling a pending downstream cosocket may close the connection
                # before nginx can emit an HTTP error. Both outcomes bound the upload.
                result = True
            elapsed = time.monotonic() - started
            return result and 4 <= elapsed < 7
        finally:
            stopped.set()
            sender.join(timeout=1)
            response.close()
            transport.close()

    def setup(self):
        ca_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        ca, ca_pem = certificate(ca_key, 'SCDN Test CA', ca=True)
        write(self.root / 'etc/ca.crt', ca_pem)
        master_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        _, master_pem = certificate(master_key, 'localhost', ca_key, ca.subject, ExtendedKeyUsageOID.SERVER_AUTH)
        write(self.root / 'etc/master.crt', master_pem)
        write(self.root / 'etc/master.key', pem(master_key))
        signing = ed25519.Ed25519PrivateKey.generate()
        registrations = {}
        self.materials = {}
        for version in (1, 2):
            key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
            cert, chain = certificate(key, 'www.example.com')
            self.materials[version] = dict(certificate_id='cert-demo', version=version, chain_pem=chain, private_key_pem=pem(key))
        for name in ('node-a', 'node-b', 'foreign'):
            tls_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
            cert, tls_pem = certificate(tls_key, name, ca_key, ca.subject, ExtendedKeyUsageOID.CLIENT_AUTH)
            write(self.root / f'etc/{name}.crt', tls_pem)
            write(self.root / f'etc/{name}.key', pem(tls_key))
            if name == 'foreign':
                continue
            rsa_key = rsa.generate_private_key(public_exponent=65537, key_size=3072)
            request_key = ed25519.Ed25519PrivateKey.generate()
            token = secrets.token_urlsafe(32)
            directory = self.root / ('data/' + name)
            registrations[name] = dict(node_id=name, scope_id='edge', enabled=True,
                tls_certificate_sha256=cert.fingerprint(hashes.SHA256()).hex(), decryption_key_id='decrypt-' + name,
                encryption_public_key=public(rsa_key), key_id='request-' + name, public_key=public(request_key), static_roots=[])
            self.nodes[name] = dict(http_port=free_port(), https_port=free_port(), token=token,
                control_socket=str(self.root / ('run/' + name + '-control.sock')))
            runtime = dict(node_id=name, scope_id='edge', data_dir=str(directory), control_token=token, static_roots=[])
            write(self.root / f'etc/{name}-runtime.lua', 'return ' + lua(runtime))
            agent = dict(runtime, decryption_key_id='decrypt-' + name, decryption_private_key=pem(rsa_key),
                signing_public_keys={'master-test': public(signing)},
                request_identity={'key_id': 'request-' + name, 'private_key': pem(request_key)},
                master_endpoint=dict(scheme='https', host='127.0.0.1', server_name='localhost', port=self.master_port,
                    authority=f'localhost:{self.master_port}', client_cert=tls_pem, client_key=pem(tls_key),
                    connect_ms=300, read_ms=600, total_ms=900),
                control_endpoint=dict(unix=self.nodes[name]['control_socket'], authority='localhost', total_ms=2000),
                probe=dict(http_port=self.nodes[name]['http_port'], https_port=self.nodes[name]['https_port']),
                poll_seconds=0.3, heartbeat_seconds=1, prepare_seconds=5, outbox_capacity=32)
            text = ('local s=' + lua(agent) + '; local ssl=require "ngx.ssl"; '
                's.master_endpoint.client_cert=assert(ssl.parse_pem_cert(s.master_endpoint.client_cert)); '
                's.master_endpoint.client_key=assert(ssl.parse_pem_priv_key(s.master_endpoint.client_key)); '
                's.verify_root=require("scdn_sync.fs").verify_directory; return s')
            write(self.root / f'etc/{name}-agent.lua', text)
        write(self.root / 'etc/publisher.lua', 'return ' + lua(dict(data_dir=str(self.root / 'data/master'),
            nodes=registrations, signing_key_id='master-test', signing_private_key=pem(signing))))
        write(self.root / 'etc/master-writer.lua', 'return ' + lua(dict(data_dir=str(self.root / 'data/master'),
            internal_token=self.internal_token, nodes=registrations)))
        write(self.root / 'etc/master-distributor.lua', 'return ' + lua(dict(nodes=registrations,
            internal_token=self.internal_token, writer_endpoint=dict(unix=str(self.root / 'run/scdn-sync-master-writer/writer.sock'),
                authority='localhost', connect_ms=300, read_ms=400, total_ms=600))))
        replacements = {
            '/opt/scdn-sync': str(PLUGIN), '/etc/scdn-sync': str(self.root / 'etc'),
            '/var/lib/scdn-sync-master': str(self.root / 'data/master'),
            '/run/scdn-sync-master-writer': str(self.root / 'run/scdn-sync-master-writer'),
            '/run/scdn-sync-master-distributor': str(self.root / 'run/scdn-sync-master-distributor'),
            '/etc/scdn-sync/pki/master.crt': str(self.root / 'etc/master.crt'),
            '/etc/scdn-sync/pki/master.key': str(self.root / 'etc/master.key'),
            '/etc/scdn-sync/pki/node-ca.crt': str(self.root / 'etc/ca.crt'),
            'listen 8443 ssl;': f'listen 127.0.0.1:{self.master_port} ssl;',
        }
        user = 'user ' + pwd.getpwuid(os.getuid()).pw_name + ';\n' if os.getuid() == 0 else ''
        for role in ('master-writer', 'master-distributor'):
            text = (PLUGIN / ('conf/' + role + '.nginx.conf')).read_text()
            for original in sorted(replacements, key=len, reverse=True):
                text = text.replace(original, replacements[original])
            write(self.root / ('etc/' + role + '.conf'), user + text)
        self.writer = self.launch('scdn-sync-master-writer', self.root / 'etc/master-writer.conf')
        self.distributor = self.launch('scdn-sync-master-distributor', self.root / 'etc/master-distributor.conf')
        for index in range(2):
            server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Origin)
            server.label = 'origin-' + str(index)
            self.origins.append(server)
            threading.Thread(target=server.serve_forever, daemon=True).start()
        for name, node in self.nodes.items():
            fragment = (PLUGIN / 'conf/node-http.conf').read_text().replace('/opt/scdn-sync', str(PLUGIN))
            fragment = fragment.replace('/etc/scdn-sync/runtime.lua', str(self.root / f'etc/{name}-runtime.lua'))
            fragment = fragment.replace('/run/scdn-sync-node/control.sock', node['control_socket'])
            fragment = fragment.replace('/usr/local/openresty/lua_files', str(LEGACY))
            root = self.root / ('run/' + name)
            root.mkdir(parents=True, exist_ok=True)
            content = f'''{user}worker_processes 2;
pid {root}/nginx.pid;
error_log stderr warn;
events {{ worker_connections 512; }}
http {{
    access_log off;
    lua_shared_dict ratelimit_dict 1m;
    proxy_cache_path {root}/cache1 keys_zone=l1:1m;
    proxy_cache_path {root}/cache2 keys_zone=l2:1m;
    {fragment}
    server {{
        listen 127.0.0.1:{node['http_port']};
        listen 127.0.0.1:{node['https_port']} ssl;
        server_name _;
        ssl_certificate {self.root}/etc/master.crt;
        ssl_certificate_key {self.root}/etc/master.key;
        ssl_session_cache off;
        ssl_session_tickets off;
        ssl_certificate_by_lua_block {{ require('scdn_sync.runtime.registry').set_cert() }}
        set $site_root ""; set $site_upstream ""; set $site_mode ""; set $site_name "";
        set $proxy_target_l1 @proxy_l1; set $proxy_target_l2 @proxy_l2; set $proxy_target_nocache @proxy_off;
        include {PLUGIN}/conf/node-server-probe.conf;
        location / {{
            access_by_lua_block {{ require('lib.route').run() }}
            root $site_root;
        }}
        location @proxy_l1 {{ proxy_cache l1; proxy_pass http://$site_upstream; }}
        location @proxy_l2 {{ proxy_cache l2; proxy_pass http://$site_upstream; }}
        location @proxy_off {{ proxy_pass http://$site_upstream; }}
    }}
}}
'''
            path = self.root / ('etc/' + name + '.conf')
            write(path, content)
            node['runtime'] = self.launch(name, path)
        for name in self.nodes:
            self.until(lambda: self.control(name)[0] == 200, name + ' local control')
            agent = Process(name + '-agent', [self.resty, '--http-conf', f'lua_ssl_trusted_certificate {self.root}/etc/ca.crt;',
                *self.library_args, str(PLUGIN / 'bin/node.lua'), str(self.root / f'etc/{name}-agent.lua')], self.root)
            self.processes.append(agent)
            self.nodes[name]['agent'] = agent
            agent.start()

    def run(self):
        self.setup()
        self.check('two real business OpenResty instances started with two workers each')
        self.until(lambda: self.master('node-a')[0] == 503, 'mTLS distributor readiness')
        self.check('registered node without publication is rejected with 503')
        try:
            rejected = self.master(None)[0] >= 400
        except (OSError, ssl.SSLError, http.client.HTTPException):
            rejected = True
        self.check('client certificate is required', rejected)
        self.check('unregistered client certificate is forbidden', self.master('foreign')[0] == 403)
        for action in ('stage', 'commit', 'rollback', 'finalize'):
            self.check('local ' + action + ' requires token', self.control('node-a', action, False, 'POST', '{}')[0] == 401)
        self.check('remote POST requires message signature', self.master('node-a', '/_scdn_sync/v1/heartbeat', 'POST', body='{}')[0] == 401)
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            releases = list(executor.map(self.publish, ('node-a', 'node-b')))
        for node, release in zip(self.nodes, releases):
            self.wait_applied(node, release['revision_id'])
            self.check(node + ' full publish/decrypt/stage/two-worker-commit/probe/applied', self.business(node)[2] == b'origin-0')
            self.check(node + ' real TLS SNI certificate installed', self.business(node, tls=True)[3] ==
                x509.load_pem_x509_certificate(self.materials[1]['chain_pem'].encode()).fingerprint(hashes.SHA256()).hex())
        bodies = [self.master(node)[2] for node in self.nodes]
        self.check('per-node ciphertext differs and contains no plaintext site or PEM', bodies[0] != bodies[1]
            and all(b'www.example.com' not in body and b'PRIVATE KEY' not in body for body in bodies))
        self.check('cross-node encrypted object access is forbidden', self.master('node-a',
            '/_scdn_sync/v1/objects/' + releases[1]['objects'][0])[0] == 403)
        self.check('internal file URL is inaccessible directly', self.master('node-a',
            '/_scdn_sync_files/node-a/releases/' + releases[0]['revision_id'] + '/manifest.jws')[0] == 404)
        self.check('unchanged version uses ciphertext ETag', self.master('node-a', headers={
            'If-None-Match': '"' + releases[0]['sha256'] + '"'})[0] == 304)
        for node in self.nodes:
            state = self.root / ('data/master/nodes/' + node + '/state.json')
            self.until(lambda: state.exists() and json.loads(state.read_text()).get('applied_revision') == releases[list(self.nodes).index(node)]['revision_id'],
                node + ' durable ACK')
        self.check('both agents authenticate reports and receive durable ACKs')
        headers, body = self.heartbeat_fixture('node-a')
        self.check('real signed POST is accepted', self.master('node-a', '/_scdn_sync/v1/heartbeat', 'POST', headers, body)[0] == 200)
        self.writer.stop()
        self.writer.start()
        self.until(lambda: Path(self.root / 'run/scdn-sync-master-writer/writer.sock').exists(), 'writer restart')
        self.check('same nonce is rejected after real writer restart', self.master('node-a', '/_scdn_sync/v1/heartbeat', 'POST', headers, body)[0] == 409)
        writer_headers, writer_body = self.heartbeat_fixture('node-b')
        self.writer.pause()
        self.check('writer hang preserves already indexed encrypted downloads', self.master('node-b')[0] == 200)
        self.check('writer hang does not stop node business', self.business('node-b')[2] == b'origin-0')
        self.check('writer hang never returns successful report ACK', self.master('node-b',
            '/_scdn_sync/v1/heartbeat', 'POST', writer_headers, writer_body)[0] == 503)
        self.writer.resume()
        self.nodes['node-a']['agent'].pause()
        advanced = self.publish('node-b', origin=1, version=2)
        self.wait_applied('node-b', advanced['revision_id'])
        self.check('paused node does not prevent other node progress', self.business('node-b')[2] == b'origin-1'
            and self.business('node-a')[2] == b'origin-0')
        self.nodes['node-a']['agent'].resume()
        rotated = self.publish('node-b', origin=1, version=3, cert_version=2)
        self.wait_applied('node-b', rotated['revision_id'])
        self.check('certificate rotation changes new TLS handshake fingerprint', self.business('node-b', tls=True)[3] ==
            x509.load_pem_x509_certificate(self.materials[2]['chain_pem'].encode()).fingerprint(hashes.SHA256()).hex())
        self.check('existing Lua WAF consumes synchronized site settings', self.business('node-b', path='/asset?x=1%20UNION%20SELECT%201')[0] == 403)
        status = json.loads(self.control('node-b')[1])
        replaced = status['workers'][0]
        os.kill(replaced['pid'], signal.SIGKILL)
        def worker_recovered():
            current = json.loads(self.control('node-b')[1])['workers'][0]
            return current.get('pid') != replaced['pid'] and current.get('boot') != replaced['boot'] \
                and current.get('active_revision') == rotated['revision_id']
        self.until(worker_recovered, 'worker respawn and immutable snapshot preparation')
        self.check('respawned real worker prepares the current generation', self.business('node-b')[2] == b'origin-1')
        self.check('slow signed upload is bounded by absolute body deadline', self.slow_upload())
        slow = http.server.ThreadingHTTPServer(('127.0.0.1', 0), SlowHeaders)
        self.origins.append(slow)
        threading.Thread(target=slow.serve_forever, daemon=True).start()
        deadline_result = subprocess.run([self.resty, *self.library_args, str(PLUGIN / 'tests/integration/deadline.lua'),
            str(slow.server_port)], capture_output=True, text=True, timeout=5)
        self.check('slow response headers are cancelled by total network deadline', deadline_result.returncode == 0)
        self.distributor.pause()
        time.sleep(1.2)
        self.check('hung master distributor leaves HTTP and TLS business available', self.business('node-b')[2] == b'origin-1'
            and self.business('node-b', tls=True)[2] == b'origin-1')
        self.nodes['node-b']['agent'].pause()
        self.nodes['node-b']['runtime'].stop()
        self.nodes['node-b']['runtime'].start()
        self.until(lambda: self.business('node-b')[2] == b'origin-1', 'cold bootstrap without master')
        self.check('cold business restart restores durable applied snapshot without master')
        self.distributor.resume()
        self.nodes['node-b']['agent'].resume()
        disabled = self.publish('node-b', enabled=False, version=4, cert_version=2)
        self.wait_applied('node-b', disabled['revision_id'])
        self.check('disable removes live HTTP routing without certificate distribution', self.business('node-b')[0] == 403 and not disabled['objects'])
        deleted = self.publish('node-b', empty=True, version=5)
        self.wait_applied('node-b', deleted['revision_id'])
        self.check('full-snapshot deletion removes previous site on every worker', self.business('node-b')[0] == 403)
        self.watch_files()
        fs_root = self.root / 'fs-test'
        fs_root.mkdir()
        outside = self.root / 'outside'
        outside.mkdir()
        write(outside / 'secret', 'test-only')
        (fs_root / 'escape').symlink_to(outside, target_is_directory=True)
        result = subprocess.run([self.resty, *self.library_args, str(PLUGIN / 'tests/integration/filesystem.lua'), str(fs_root)],
            capture_output=True, text=True, timeout=20)
        self.check('real Linux openat/fsync/flock/list/path and symlink confinement', result.returncode == 0)
        self.check('read of missing path creates no directories',
            not (fs_root / 'missing').exists() and not (fs_root / 'no-source').exists())
        self.check('private data directories and atomic files use 0700/0600',
            (fs_root.stat().st_mode & 0o777) == 0o700 and ((self.root / 'data/node-b/applied.json').stat().st_mode & 0o777) == 0o600)

    def close(self):
        for process in reversed(self.processes):
            process.stop()
        for server in self.origins:
            server.shutdown()
            server.server_close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--openresty-prefix', type=Path, default=Path(os.environ.get('OPENRESTY_PREFIX', '/opt/openresty')))
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    if os.name != 'posix' or not (args.openresty_prefix / 'bin/resty').exists():
        parser.error('real Linux OpenResty with lua-resty-openssl and Python cryptography is required')
    with tempfile.TemporaryDirectory(prefix='scdn-sync-integration-') as directory:
        integration = Integration(Path(directory), args.openresty_prefix)
        try:
            integration.run()
            result = dict(passed=len(integration.results), checks=integration.results,
                completed_at_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'),
                openresty=subprocess.run([integration.nginx, '-V'], capture_output=True, text=True).stderr.splitlines()[:3])
            if args.report:
                args.report.parent.mkdir(parents=True, exist_ok=True)
                args.report.write_text(json.dumps(result, indent=2) + '\n')
            print(f'{len(integration.results)} real integration checks passed', flush=True)
        except Exception:
            for process in integration.processes:
                print(process.name + ': ' + process.log_path.read_text(errors='replace')[-2500:])
            raise
        finally:
            integration.close()


if __name__ == '__main__':
    main()
