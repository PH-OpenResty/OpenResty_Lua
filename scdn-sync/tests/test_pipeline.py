from __future__ import annotations

import datetime
import json
import time
import unittest

from support import DiskStore, module, runtime, runtime_doubles, table
from test_crypto import private_pem, public_pem
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ed25519, rsa
from cryptography.x509.oid import NameOID


def site(enabled=True, tls=True):
    return dict(site_id='site-demo', resource_version=1, name='demo', enabled=enabled,
                server_names=['www.example.com'], root='', upstream='origin.example.com:8080',
                cache={'layer': 'l2'}, ssl=({'enabled': True, 'certificate_id': 'cert-demo',
                'certificate_version': 1} if tls else {'enabled': False}),
                rate_limit={'enabled': True, 'req_per_sec': 50, 'burst': 100},
                waf={'enabled': True, 'groups': ['sqli', 'xss'], 'threshold': 5}, locations=[])


class PipelineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rsa = rsa.generate_private_key(public_exponent=65537, key_size=3072)
        cls.master = ed25519.Ed25519PrivateKey.generate()
        cls.request_key = ed25519.Ed25519PrivateKey.generate()
        cls.tls = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'www.example.com')])
        now = datetime.datetime.now(datetime.timezone.utc)
        cls.cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
            .public_key(cls.tls.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - datetime.timedelta(hours=1)).not_valid_after(now + datetime.timedelta(days=7))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName('www.example.com')]), critical=False)
            .sign(cls.tls, hashes.SHA256()))

    def setUp(self):
        self.lua = runtime()
        runtime_doubles(self.lua)
        self.codec = module(self.lua, 'scdn_sync.codec')
        self.now = int(time.time())
        self.settings = table(self.lua, dict(node_id='node-a', scope_id='edge', decryption_key_id='decrypt-a',
            static_roots=[], worker_count=2, prepare_seconds=1))
        self.settings[b'decryption_private_key'] = private_pem(self.rsa)
        self.settings[b'signing_public_keys'] = self.lua.table_from({b'master-key': public_pem(self.master)})
        node = table(self.lua, dict(node_id='node-a', scope_id='edge', decryption_key_id='decrypt-a',
                    key_id='request-a', enabled=True, static_roots=[]))
        node[b'encryption_public_key'] = public_pem(self.rsa)
        node[b'public_key'] = public_pem(self.request_key)
        self.nodes = self.lua.table_from({b'node-a': node})
        self.master_store, self.node_store = DiskStore(self.lua), DiskStore(self.lua)
        self.addCleanup(self.master_store.temp.cleanup)
        self.addCleanup(self.node_store.temp.cleanup)
        self.publisher = module(self.lua, 'scdn_sync.master.publish').new(self.master_store.table,
            self.lua.table_from({b'nodes': self.nodes, b'signing_key_id': b'master-key',
                                 b'signing_private_key': private_pem(self.master)}))
        self.ingest = module(self.lua, 'scdn_sync.master.ingest').new(self.master_store.table,
            self.lua.table_from({b'nodes': self.nodes}))
        self.outbox = module(self.lua, 'scdn_sync.node.outbox').new(self.node_store.table, b'node-a', 16)
        self.clock = float(self.now)
        self.data, self.state = self.lua.globals().test_dict(), self.lua.globals().test_dict()
        engine = module(self.lua, 'scdn_sync.runtime.engine')
        self.engines = [engine.new(self.data, self.state, b'locks', self.settings, self.lua.globals().test_ssl,
                       self.lua.globals().test_worker(i, 2), lambda: self.clock) for i in range(2)]
        self.ticking = True
        self.ticks()
        self.probe_fail = False
        self.applier = module(self.lua, 'scdn_sync.node.apply').new(self.node_store.table, self.settings,
            self.control, self.outbox, lambda: self.clock, self.sleep, self.probe)

    def ticks(self):
        for engine in self.engines:
            engine.tick(engine)

    def sleep(self, duration):
        self.clock += duration
        if self.ticking:
            self.ticks()

    def control(self, action, input=None):
        self.ticks() if self.ticking else None
        engine = self.engines[0]
        try:
            value = engine[action](engine, input) if input is not None else engine[action](engine)
            return self.lua.table_from({b'status': 200, b'body': self.codec.encode(value)})
        except Exception:
            return self.lua.table_from({b'status': 409, b'body': b'{"error":"rejected"}'})

    def probe(self, snapshot):
        if self.probe_fail:
            raise ValueError('injected probe failure')
        self.assertEqual(self.state.get(self.state, b'active'), snapshot[b'revision_id'])

    def publish(self, sites=None, tls=True):
        material = dict(certificate_id='cert-demo', version=1,
                        chain_pem=self.cert.public_bytes(serialization.Encoding.PEM).decode(),
                        private_key_pem=private_pem(self.tls).decode())
        metadata = self.publisher.publish(self.publisher, table(self.lua, dict(node_id='node-a', scope_id='edge',
            sites=sites if sites is not None else [site(tls=tls)], certificates=[material] if tls else [])), self.now)
        revision = metadata[b'revision_id'].decode()
        root = f'nodes/node-a/releases/{revision}/'
        signed = self.master_store.read((root + 'manifest.jws').encode())
        def fetch(sha):
            return self.master_store.read((root + 'objects/' + sha.decode() + '.jwe').encode())
        return metadata, signed, fetch

    def test_publish_decrypt_apply_and_delete_two_workers(self):
        metadata, signed, fetch = self.publish()
        applied = self.applier.apply(self.applier, signed, fetch)
        self.assertEqual(applied[b'revision_id'], metadata[b'revision_id'])
        self.assertNotIn(b'www.example.com', signed)
        for engine in self.engines:
            self.assertIsNotNone(engine.lookup(engine, b'www.example.com'))
        _, deleted, fetch_deleted = self.publish(sites=[], tls=False)
        self.applier.apply(self.applier, deleted, fetch_deleted)
        for engine in self.engines:
            self.assertIsNone(engine.lookup(engine, b'www.example.com'))
        self.assertEqual(len(self.outbox.entries(self.outbox)), 2)

    def test_failed_health_restores_previous_and_keeps_applied(self):
        first, signed, fetch = self.publish(tls=False)
        self.applier.apply(self.applier, signed, fetch)
        self.probe_fail = True
        _, second, fetch_second = self.publish(sites=[], tls=False)
        with self.assertRaises(Exception):
            self.applier.apply(self.applier, second, fetch_second)
        self.assertEqual(self.state.get(self.state, b'active'), first[b'revision_id'])
        self.assertEqual(self.applier.read(self.applier, b'applied.json')[b'revision_id'], first[b'revision_id'])

    def test_shared_memory_failure_preserves_previous(self):
        first, signed, fetch = self.publish(tls=False)
        self.applier.apply(self.applier, signed, fetch)
        second, signed_second, fetch_second = self.publish(sites=[], tls=False)
        self.data[b'fail_key'] = b'snapshot:' + second[b'revision_id']
        with self.assertRaises(Exception):
            self.applier.apply(self.applier, signed_second, fetch_second)
        self.assertEqual(self.state.get(self.state, b'active'), first[b'revision_id'])

    def test_object_tampering_does_not_activate(self):
        _, signed, fetch = self.publish()
        with self.assertRaises(Exception):
            self.applier.apply(self.applier, signed, lambda sha: fetch(sha) + b'x')
        self.assertIsNone(self.state.get(self.state, b'active'))
        self.assertIsNone(self.node_store.read(b'applied.json'))

    def test_older_manifest_rejected_after_newer_release(self):
        _, first, fetch_first = self.publish(tls=False)
        _, second, fetch_second = self.publish(sites=[], tls=False)
        self.applier.apply(self.applier, second, fetch_second)
        with self.assertRaises(Exception):
            self.applier.apply(self.applier, first, fetch_first)

    def test_request_auth_and_durable_replay(self):
        auth = module(self.lua, 'scdn_sync.auth')
        identity = self.lua.table_from({b'key_id': b'request-a', b'private_key': private_pem(self.request_key)})
        body = self.codec.encode(table(self.lua, dict(protocol='scdn.sync.v1', node_id='node-a',
            request_id='heartbeat-1', heartbeat_seq='1')))
        headers = auth.sign_request(b'master.example.com', b'/_scdn_sync/v1/heartbeat', body, identity, self.now)
        request = self.lua.table_from({b'node_id': b'node-a', b'method': b'POST', b'authority': b'master.example.com',
            b'path': b'/_scdn_sync/v1/heartbeat', b'headers': headers, b'body': body})
        self.assertTrue(self.ingest.accept(self.ingest, request, self.now)[b'accepted'])
        restarted = module(self.lua, 'scdn_sync.master.ingest').new(self.master_store.table,
            self.lua.table_from({b'nodes': self.nodes}))
        with self.assertRaises(Exception):
            restarted.accept(restarted, request, self.now)
        request[b'headers'] = auth.sign_request(b'master.example.com', b'/_scdn_sync/v1/heartbeat', body, identity, self.now)
        self.assertTrue(restarted.accept(restarted, request, self.now)[b'accepted'])
        request[b'body'] = body + b' '
        with self.assertRaises(Exception):
            restarted.accept(restarted, request, self.now)

    def test_writer_disk_failure_never_acknowledges(self):
        auth = module(self.lua, 'scdn_sync.auth')
        identity = self.lua.table_from({b'key_id': b'request-a', b'private_key': private_pem(self.request_key)})
        body = self.codec.encode(table(self.lua, dict(protocol='scdn.sync.v1', node_id='node-a',
            request_id='heartbeat-1', heartbeat_seq='1')))
        request = self.lua.table_from({b'node_id': b'node-a', b'method': b'POST', b'authority': b'master.example.com',
            b'path': b'/_scdn_sync/v1/heartbeat', b'body': body,
            b'headers': auth.sign_request(b'master.example.com', b'/_scdn_sync/v1/heartbeat', body, identity, self.now)})
        self.master_store.fail_path = 'state.json'
        with self.assertRaises(Exception):
            self.ingest.accept(self.ingest, request, self.now)
        self.master_store.fail_path = None
        self.assertTrue(self.ingest.accept(self.ingest, request, self.now)[b'accepted'])

    def test_same_manifest_is_idempotent_without_second_report_or_switch(self):
        metadata, signed, fetch = self.publish()
        first = self.applier.apply(self.applier, signed, fetch)
        second = self.applier.apply(self.applier, signed, fetch)
        self.assertEqual(first[b'digest'], second[b'digest'])
        self.assertEqual(self.state.get(self.state, b'active'), metadata[b'revision_id'])
        self.assertEqual(len(self.outbox.entries(self.outbox)), 1)

    def test_disable_site_removes_http_and_tls_without_certificate_object(self):
        _, signed, fetch = self.publish()
        self.applier.apply(self.applier, signed, fetch)
        disabled, signed_disabled, fetch_disabled = self.publish(sites=[site(enabled=False)], tls=False)
        self.applier.apply(self.applier, signed_disabled, fetch_disabled)
        self.assertEqual(len(disabled[b'objects']), 0)
        for engine in self.engines:
            self.assertIsNone(engine.lookup(engine, b'www.example.com'))
            with self.assertRaises(Exception):
                engine.set_certificate(engine, b'www.example.com')

    def test_publish_failure_never_advances_desired(self):
        first, _, _ = self.publish(tls=False)
        for failed_path in ('manifest.jws', 'metadata.json', 'desired.json'):
            self.master_store.fail_path = failed_path
            with self.subTest(path=failed_path), self.assertRaises(Exception):
                self.publish(sites=[], tls=False)
            desired = self.codec.decode(self.master_store.read(b'nodes/node-a/desired.json'))
            self.assertEqual(desired[b'revision_id'], first[b'revision_id'])
        self.master_store.fail_path = None

    def test_staging_transaction_capacity_failure_cleans_uncommitted_snapshot(self):
        metadata, signed, fetch = self.publish(tls=False)
        self.state[b'fail_key'] = b'transaction'
        with self.assertRaises(Exception):
            self.applier.apply(self.applier, signed, fetch)
        self.assertIsNone(self.data.get(self.data, b'snapshot:' + metadata[b'revision_id']))
        self.assertIsNone(self.state.get(self.state, b'active'))

    def test_commit_pointer_failure_rolls_back_and_exact_candidate_can_retry(self):
        first, signed, fetch = self.publish(tls=False)
        self.applier.apply(self.applier, signed, fetch)
        second, signed_second, fetch_second = self.publish(sites=[], tls=False)
        self.state[b'fail_key'] = b'active'
        with self.assertRaises(Exception):
            self.applier.apply(self.applier, signed_second, fetch_second)
        self.assertEqual(self.state.get(self.state, b'active'), first[b'revision_id'])
        self.assertIsNotNone(self.node_store.read(b'journal.json'))
        self.state[b'fail_key'] = None
        self.applier.recover(self.applier)
        self.applier.apply(self.applier, signed_second, fetch_second)
        self.assertEqual(self.state.get(self.state, b'active'), second[b'revision_id'])

    def test_missing_worker_does_not_commit(self):
        _, signed, fetch = self.publish(tls=False)
        self.engines.pop()
        self.state.delete(self.state, b'worker:1')
        with self.assertRaises(Exception):
            self.applier.apply(self.applier, signed, fetch)
        self.assertIsNone(self.state.get(self.state, b'active'))
        self.assertIsNone(self.node_store.read(b'applied.json'))

    def test_applied_disk_failure_restores_previous(self):
        first, signed, fetch = self.publish(tls=False)
        self.applier.apply(self.applier, signed, fetch)
        _, second, fetch_second = self.publish(sites=[], tls=False)
        self.node_store.fail_path = 'applied.json'
        with self.assertRaises(Exception):
            self.applier.apply(self.applier, second, fetch_second)
        self.assertEqual(self.state.get(self.state, b'active'), first[b'revision_id'])
        self.assertEqual(self.applier.read(self.applier, b'applied.json')[b'revision_id'], first[b'revision_id'])

    def test_interrupted_finalize_recovers_durable_applied_report(self):
        metadata, signed, fetch = self.publish(tls=False)
        normal_control = self.applier[b'control']
        def lost_finalize(action, value=None):
            if action == b'finalize':
                return self.lua.table_from({b'status': 503, b'body': b'{}'})
            return self.control(action, value)
        self.applier[b'control'] = lost_finalize
        with self.assertRaises(Exception):
            self.applier.apply(self.applier, signed, fetch)
        self.assertEqual(self.applier.read(self.applier, b'applied.json')[b'revision_id'], metadata[b'revision_id'])
        self.assertIsNotNone(self.node_store.read(b'journal.json'))
        self.applier[b'control'] = normal_control
        self.applier.recover(self.applier)
        self.assertIsNone(self.node_store.read(b'journal.json'))
        self.assertEqual(len(self.outbox.entries(self.outbox)), 1)

    def test_outbox_capacity_reserves_apply_slot_and_ack_loss_retries(self):
        outbox = module(self.lua, 'scdn_sync.node.outbox').new(self.node_store.table, b'node-a', 2)
        report = outbox.reserve(outbox, b'/_scdn_sync/v1/reports')
        beat = outbox.reserve(outbox, b'/_scdn_sync/v1/heartbeat')
        outbox.enqueue(outbox, beat, table(self.lua, {}))
        self.assertFalse(outbox.available(outbox))
        with self.assertRaises(Exception):
            outbox.reserve(outbox, b'/_scdn_sync/v1/heartbeat')
        outbox.enqueue(outbox, report, table(self.lua, dict(phase='failed')))
        def missing_ack(path, body):
            return self.lua.table_from({b'status': 503, b'body': b'{}'})
        with self.assertRaises(Exception):
            outbox.flush(outbox, missing_ack, 8)
        self.assertEqual(len(outbox.entries(outbox)), 2)
        def ack(path, body):
            value = self.codec.decode(body)
            return self.lua.table_from({b'status': 200, b'body': self.codec.encode(
                self.lua.table_from({b'accepted': True, b'request_id': value[b'request_id']}))})
        self.assertEqual(outbox.flush(outbox, ack, 8), 2)
        self.assertEqual(len(outbox.entries(outbox)), 0)

    def test_journal_write_failure_does_not_leak_outbox_reservation(self):
        _, signed, fetch = self.publish(tls=False)
        self.node_store.fail_path = 'journal.json'
        with self.assertRaises(Exception):
            self.applier.apply(self.applier, signed, fetch)
        self.assertEqual(len(list(self.outbox[b'reserved'].keys())), 0)
        self.assertIsNone(self.state.get(self.state, b'active'))

    def report_request(self, body, now=None):
        auth = module(self.lua, 'scdn_sync.auth')
        identity = self.lua.table_from({b'key_id': b'request-a', b'private_key': private_pem(self.request_key)})
        return self.lua.table_from({b'node_id': b'node-a', b'method': b'POST', b'authority': b'master.example.com',
            b'path': b'/_scdn_sync/v1/reports', b'body': body, b'headers': auth.sign_request(b'master.example.com',
                b'/_scdn_sync/v1/reports', body, identity, now or self.now)})

    def test_last_report_retry_survives_bounded_receipt_pruning(self):
        _, signed, fetch = self.publish(tls=False)
        self.applier.apply(self.applier, signed, fetch)
        body = self.outbox.entries(self.outbox)[1][b'value'][b'body']
        self.assertTrue(self.ingest.accept(self.ingest, self.report_request(body), self.now)[b'accepted'])
        state = self.codec.decode(self.master_store.read(b'nodes/node-a/state.json'))
        state[b'receipts'] = table(self.lua, {})
        self.master_store.write(b'nodes/node-a/state.json', self.codec.encode(state))
        self.assertTrue(self.ingest.accept(self.ingest, self.report_request(body, self.now + 100), self.now + 100)[b'accepted'])

    def test_late_old_report_cannot_replace_new_desired_result(self):
        first, signed, fetch = self.publish(tls=False)
        self.applier.apply(self.applier, signed, fetch)
        body = self.outbox.entries(self.outbox)[1][b'value'][b'body']
        second, _, _ = self.publish(sites=[], tls=False)
        self.assertTrue(self.ingest.accept(self.ingest, self.report_request(body), self.now)[b'accepted'])
        state = self.codec.decode(self.master_store.read(b'nodes/node-a/state.json'))
        self.assertIsNone(state[b'latest_report'])
        self.assertNotEqual(first[b'desired_seq'], second[b'desired_seq'])

    def test_applied_report_cannot_be_downgraded_to_failed(self):
        _, signed, fetch = self.publish(tls=False)
        self.applier.apply(self.applier, signed, fetch)
        body = self.outbox.entries(self.outbox)[1][b'value'][b'body']
        self.ingest.accept(self.ingest, self.report_request(body), self.now)
        changed = self.codec.decode(body)
        changed[b'report_seq'], changed[b'request_id'], changed[b'phase'] = b'2', b'wrong-transition', b'failed'
        changed[b'error_code'] = b'fake-error'
        with self.assertRaises(Exception):
            self.ingest.accept(self.ingest, self.report_request(self.codec.encode(changed)), self.now)

    def test_visible_applied_marker_after_fsync_error_is_not_acknowledged(self):
        metadata, signed, fetch = self.publish(tls=False)
        self.node_store.fail_after_path = 'applied.json'
        with self.assertRaises(Exception):
            self.applier.apply(self.applier, signed, fetch)
        self.assertEqual(self.state.get(self.state, b'active'), metadata[b'revision_id'])
        self.assertIsNotNone(self.node_store.read(b'journal.json'))
        self.assertEqual(len(self.outbox.entries(self.outbox)), 0)
        self.node_store.fail_after_path = None
        self.applier.recover(self.applier)
        self.assertIsNone(self.node_store.read(b'journal.json'))
        self.assertEqual(len(self.outbox.entries(self.outbox)), 1)

    def test_visible_report_file_after_fsync_error_is_not_sent(self):
        reservation = self.outbox.reserve(self.outbox, b'/_scdn_sync/v1/heartbeat')
        self.node_store.fail_after_path = 'reports'
        with self.assertRaises(Exception):
            self.outbox.enqueue(self.outbox, reservation, table(self.lua, {}))
        calls = []
        with self.assertRaises(Exception):
            self.outbox.flush(self.outbox, lambda *args: calls.append(args), 8)
        self.assertEqual(calls, [])

    def test_certificate_version_cannot_change_material(self):
        self.publish()
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'www.example.com')])
        now = datetime.datetime.now(datetime.timezone.utc)
        changed = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
            .public_key(self.tls.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - datetime.timedelta(hours=1)).not_valid_after(now + datetime.timedelta(days=7))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName('www.example.com')]), critical=False)
            .sign(self.tls, hashes.SHA256()))
        material = dict(certificate_id='cert-demo', version=1, private_key_pem=private_pem(self.tls).decode(),
            chain_pem=changed.public_bytes(serialization.Encoding.PEM).decode())
        with self.assertRaises(Exception):
            self.publisher.publish(self.publisher, table(self.lua, dict(node_id='node-a', scope_id='edge',
                sites=[site()], certificates=[material])), self.now)

    def test_maximum_safe_certificate_version_roundtrips_without_tostring_collision(self):
        value = site()
        value['ssl']['certificate_version'] = 9007199254740991
        material = dict(certificate_id='cert-demo', version=9007199254740991,
            chain_pem=self.cert.public_bytes(serialization.Encoding.PEM).decode(), private_key_pem=private_pem(self.tls).decode())
        metadata = self.publisher.publish(self.publisher, table(self.lua, dict(node_id='node-a', scope_id='edge',
            sites=[value], certificates=[material])), self.now)
        root = b'nodes/node-a/releases/' + metadata[b'revision_id'] + b'/'
        self.applier.apply(self.applier, self.master_store.read(root + b'manifest.jws'),
            lambda digest: self.master_store.read(root + b'objects/' + digest + b'.jwe'))
        for engine in self.engines:
            self.assertEqual(engine.lookup(engine, b'www.example.com')[b'ssl'][b'certificate_version'], 9007199254740991)

    def test_domain_origin_cache_and_waf_update_replaces_whole_site(self):
        _, signed, fetch = self.publish(tls=False)
        self.applier.apply(self.applier, signed, fetch)
        changed = site(tls=False)
        changed.update(server_names=['new.example.com', 'alias.example.com'], upstream='new-origin.example.com:9000', resource_version=2)
        changed['cache']['layer'], changed['waf']['enabled'] = 'off', False
        _, updated, objects = self.publish(sites=[changed], tls=False)
        self.applier.apply(self.applier, updated, objects)
        for engine in self.engines:
            self.assertIsNone(engine.lookup(engine, b'www.example.com'))
            for host in (b'new.example.com', b'alias.example.com'):
                value = engine.lookup(engine, host)
                self.assertEqual(value[b'upstream'], b'new-origin.example.com:9000')
                self.assertEqual(value[b'cache'][b'layer'], b'off')
                self.assertFalse(value[b'waf'][b'enabled'])


if __name__ == '__main__':
    unittest.main()
