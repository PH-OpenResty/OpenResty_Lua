from __future__ import annotations

import datetime
import json
import time
import unittest

from support import DiskStore, module, runtime, table
from test_crypto import private_pem, public_pem
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ed25519, rsa
from cryptography.x509.oid import NameOID


def legacy(upstream='origin.example.com:8080', tls=False):
    return dict(name='demo', enabled=True, server_names=['www.example.com'], root='', upstream=upstream,
                cache={'layer': 'off'}, ssl=({'cert': '/certs/site.pem', 'key': '/certs/site.key'} if tls else {'cert': '', 'key': ''}),
                rate_limit={'enabled': False, 'req_per_sec': 0, 'burst': 0, 'conn': 100},
                waf={'enabled': True, 'groups': ['sqli'], 'threshold': 5})


class Sources:
    def __init__(self, lua):
        self.lua = lua
        self.files = {b'/sites': {}, b'/certs': {}}
        self.unavailable = set()
        self.opened, self.closed = 0, 0

    def open(self, root):
        if root in self.unavailable or root not in self.files:
            raise OSError('source directory unavailable')
        self.opened += 1
        def read(_, name, limit):
            value = self.files[root].get(name)
            if value and len(value) > limit:
                raise ValueError('oversized source')
            return value
        def listing(_, path, maximum):
            assert path is None
            if len(self.files[root]) > maximum:
                raise ValueError('directory capacity')
            return self.lua.table_from(sorted(self.files[root]))
        def close(_):
            self.closed += 1
        return self.lua.table_from({b'read': read, b'list': listing, b'close': close})


class DataLuaTests(unittest.TestCase):
    def setUp(self):
        self.lua = runtime()
        self.parser = module(self.lua, 'scdn_sync.data_lua')
        self.codec = module(self.lua, 'scdn_sync.codec')

    def test_literal_comments_keys_and_escapes_are_data(self):
        raw = b'''-- generated file
            --[=[ long comment ]=]
            return { name = 'demo', ["enabled"] = true; empty = {},
                hosts = {"www.example.com",}, string = 'line\\n\\065\\x42',
                long = [=[
value]=], rate = 1e2, escaped = "a\\z  \n b" }; -- end
        '''
        decoded = json.loads(self.codec.encode(self.parser.decode(raw)))
        self.assertEqual(decoded['string'], 'line\nAB')
        self.assertEqual(decoded['long'], 'value')
        self.assertEqual(decoded['escaped'], 'ab')
        self.assertEqual(decoded['hosts'], ['www.example.com'])

    def test_code_bytecode_duplicate_keys_and_complexity_are_rejected(self):
        for raw in (b'return os.execute("anything")', b'return {a=require("io")}',
                    b'while true do end', b'return {a=1,["a"]=2}', b'return {a=1,2}',
                    b'return {a="x" .. "y"}', b'\x1bLJ\x02', b'return {' + b'{' * 30 + b'}' * 31):
            with self.subTest(raw=raw), self.assertRaises(Exception):
                self.parser.decode(raw)


class WatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rsa = rsa.generate_private_key(public_exponent=65537, key_size=3072)
        cls.signing = ed25519.Ed25519PrivateKey.generate()
        cls.materials = []
        now = datetime.datetime.now(datetime.timezone.utc)
        for _ in range(2):
            key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
            name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'www.example.com')])
            cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
                    .serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(hours=1))
                    .not_valid_after(now + datetime.timedelta(days=2))
                    .add_extension(x509.SubjectAlternativeName([x509.DNSName('www.example.com')]), critical=False)
                    .sign(key, hashes.SHA256()))
            cls.materials.append((cert.public_bytes(serialization.Encoding.PEM), private_pem(key)))

    def setUp(self):
        self.lua = runtime()
        self.codec = module(self.lua, 'scdn_sync.codec')
        self.crypto = module(self.lua, 'scdn_sync.crypto')
        self.store = DiskStore(self.lua)
        self.addCleanup(self.store.temp.cleanup)
        self.sources = Sources(self.lua)
        nodes = {name: dict(node_id=name, scope_id='edge', enabled=True, decryption_key_id='decrypt-' + name,
                           encryption_public_key=public_pem(self.rsa).decode(), static_roots=[])
                 for name in ('node-a', 'node-b')}
        self.settings = table(self.lua, dict(signing_key_id='master', signing_private_key=private_pem(self.signing).decode(),
            nodes=nodes, watch=dict(poll_seconds=1, settle_seconds=2, ttl_seconds=60, renew_before_seconds=10,
                scopes=[dict(scope_id='edge', sites_dir='/sites', node_ids=list(nodes), certificate_roots=['/certs'], allow_empty=True)])))
        self.now = int(time.time())
        self.watch = self.new_watch()
        self.put()

    def new_watch(self):
        return module(self.lua, 'scdn_sync.master.watch').new(self.store.table, self.settings, self.sources.open)

    def put(self, value=None, name=b'demo.json'):
        self.sources.files[b'/sites'][name] = json.dumps(value or legacy()).encode()

    def step(self, seconds, watch=None):
        value = (watch or self.watch).step(watch or self.watch, self.now + seconds)
        return json.loads(self.codec.encode(value))

    def desired(self, node='node-a'):
        raw = self.store.read(f'nodes/{node}/desired.json'.encode())
        return json.loads(raw) if raw else None

    def manifest(self, node='node-a'):
        revision = self.desired(node)['revision_id']
        signed = self.store.read(f'nodes/{node}/releases/{revision}/manifest.jws'.encode())
        encrypted = self.crypto.unwrap(signed, self.lua.table_from({b'master': public_pem(self.signing)}))
        return json.loads(self.crypto.decrypt(encrypted, private_pem(self.rsa), ('decrypt-' + node).encode()))

    def initial(self):
        self.assertEqual(self.step(0), [])
        self.assertEqual(len(self.step(2)), 2)

    def test_add_edit_and_delete_publish_latest_complete_snapshot(self):
        self.initial()
        other = legacy('second.example.com:8080')
        other['name'], other['server_names'] = 'other', ['second.example.com']
        self.put(other, b'other.json')
        self.assertEqual(self.step(3), [])
        self.assertEqual(len(self.step(5)), 2)
        self.assertEqual(len(self.manifest()['sites']), 2)
        self.put(legacy('changed.example.com:8080'))
        self.step(6)
        self.step(8)
        self.assertEqual(self.manifest()['sites'][0]['upstream'], 'changed.example.com:8080')
        self.assertEqual(self.manifest()['sites'][0]['resource_version'], 2)
        del self.sources.files[b'/sites'][b'demo.json']
        self.step(9)
        self.step(11)
        self.assertEqual([s['site_id'] for s in self.manifest()['sites']], ['other'])
        self.assertEqual(self.sources.opened, self.sources.closed)

    def test_repeated_edits_settle_before_a_single_publication(self):
        self.initial()
        self.put(legacy('intermediate.example.com:8080'))
        self.step(3)
        self.put(legacy('final.example.com:8080'))
        self.step(4)
        self.assertEqual(self.step(5), [])
        self.assertEqual(self.desired()['desired_seq'], '1')
        self.assertEqual(len(self.step(6)), 2)
        self.assertEqual(self.desired()['desired_seq'], '2')
        self.assertEqual(self.manifest()['sites'][0]['upstream'], 'final.example.com:8080')

    def test_half_written_or_invalid_source_keeps_previous_and_resets_settling(self):
        self.initial()
        previous = self.desired()
        self.put(legacy('new.example.com:8080'))
        self.step(3)
        self.sources.files[b'/sites'][b'demo.json'] = b'{"name":'
        self.assertIn('error_code', self.step(4)[0])
        self.assertEqual(self.desired(), previous)
        self.put(legacy('new.example.com:8080'))
        self.step(5)
        self.assertEqual(self.step(6), [])
        self.assertEqual(len(self.step(7)), 2)

    def test_noop_restart_and_commit_notification_loss_do_not_duplicate_release(self):
        self.initial()
        previous = self.desired()
        self.assertEqual(self.step(3), [])
        restarted = self.new_watch()
        self.step(4, restarted)
        self.assertEqual(self.step(6, restarted), [])
        self.assertEqual(self.desired(), previous)
        self.put(legacy('new.example.com:8080'))
        self.store.fail_after_path = str(self.store.root / 'nodes/node-a/desired.json')
        self.step(7, restarted)
        self.step(9, restarted)
        self.assertEqual(self.desired()['desired_seq'], '2')
        retry = self.step(11, restarted)
        self.assertEqual(len(retry), 1)
        self.assertEqual(retry[0]['node_id'], 'node-a')
        self.assertIn('error_code', retry[0])
        self.store.fail_after_path = None
        self.assertEqual(self.step(12, restarted), [])
        self.assertEqual(self.step(15, restarted), [])
        self.assertEqual(self.desired()['desired_seq'], '2')

    def test_visible_version_ledger_is_reconfirmed_after_fsync_error(self):
        self.store.fail_after_path = str(self.store.root / 'watch/edge/sites/demo.json')
        self.step(0)
        self.assertTrue(self.step(2)[0].get('error_code'))
        self.step(3)
        self.assertTrue(self.step(5)[0].get('error_code'))
        self.assertIsNone(self.desired())
        self.store.fail_after_path = None
        self.step(6)
        self.assertEqual(len(self.step(8)), 2)
        self.assertEqual(self.manifest()['sites'][0]['resource_version'], 1)

    def test_one_node_publish_failure_does_not_block_other_node_and_retries(self):
        self.store.fail_path = str(self.store.root / 'nodes/node-a')
        self.step(0)
        events = self.step(2)
        self.assertIsNone(self.desired('node-a'))
        self.assertEqual(self.desired('node-b')['desired_seq'], '1')
        self.assertTrue(any(e.get('error_code') for e in events))
        self.store.fail_path = None
        self.assertEqual(self.step(3), [])
        self.step(4)
        self.assertEqual(self.desired('node-a')['desired_seq'], '1')
        self.assertEqual(self.desired('node-b')['desired_seq'], '1')

    def test_manifest_renews_before_expiry_even_without_source_changes(self):
        self.initial()
        self.assertEqual(self.step(51), [])
        self.assertEqual(len(self.step(52)), 2)
        self.assertEqual(self.desired()['desired_seq'], '2')
        self.assertEqual(self.manifest()['sites'][0]['resource_version'], 1)

    def test_certificate_replacement_on_same_paths_gets_new_durable_version(self):
        self.put(legacy(tls=True))
        self.sources.files[b'/certs'][b'site.pem'], self.sources.files[b'/certs'][b'site.key'] = self.materials[0]
        self.initial()
        first = self.manifest()['certificates'][0]
        self.sources.files[b'/certs'][b'site.pem'], self.sources.files[b'/certs'][b'site.key'] = self.materials[1]
        self.step(3)
        self.step(5)
        second = self.manifest()['certificates'][0]
        self.assertEqual(first['certificate_id'], second['certificate_id'])
        self.assertEqual((first['version'], second['version']), (1, 2))
        restarted = self.new_watch()
        self.step(6, restarted)
        self.step(8, restarted)
        self.assertEqual(self.desired()['desired_seq'], '2')

    def test_missing_source_empty_guard_and_certificate_path_errors_keep_previous(self):
        self.initial()
        previous = self.desired()
        self.sources.unavailable.add(b'/sites')
        self.assertTrue(self.step(3)[0].get('error_code'))
        self.sources.unavailable.clear()
        self.settings[b'watch'][b'scopes'][1][b'allow_empty'] = False
        self.sources.files[b'/sites'].clear()
        self.assertEqual(self.step(4)[0]['error_code'], 'source_empty')
        value = legacy(tls=True)
        value['ssl']['key'] = '/outside/key'
        self.put(value)
        self.sources.files[b'/certs'][b'site.pem'] = self.materials[0][0]
        self.assertEqual(self.step(5)[0]['error_code'], 'certificate_source_forbidden')
        self.assertEqual(self.desired(), previous)
        self.assertEqual(self.sources.opened, self.sources.closed)

    def test_original_lua_format_and_editor_temporary_files(self):
        self.sources.files[b'/sites'].clear()
        self.sources.files[b'/sites'][b'demo.lua'] = b'''return {
            name="demo", enabled=true, server_names={"WWW.Example.COM"}, root="",
            upstream="origin.example.com:8080", ssl={cert="",key=""},
            rate_limit={enabled=false,req_per_sec=0,burst=0}, waf={enabled=false,groups={},threshold=5}}
        '''
        self.sources.files[b'/sites'][b'.demo.lua'] = b'unfinished editor file'
        self.sources.files[b'/sites'][b'demo.lua.tmp'] = b'unfinished editor file'
        self.initial()
        self.assertEqual(self.manifest()['sites'][0]['server_names'], ['www.example.com'])

    def test_conflicting_hosts_and_unsupported_runtime_code_never_publish(self):
        self.initial()
        previous = self.desired()
        self.put(legacy(), b'other.json')
        self.step(3)
        self.assertEqual(self.step(5)[0]['error_code'], 'host_conflict')
        del self.sources.files[b'/sites'][b'other.json']
        self.sources.files[b'/sites'][b'bad.lua'] = b'return {upstream=os.getenv("SECRET")}'
        self.assertTrue(self.step(6)[0].get('error_code'))
        self.assertEqual(self.desired(), previous)


if __name__ == '__main__':
    unittest.main()
