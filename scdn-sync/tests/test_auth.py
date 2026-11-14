from __future__ import annotations

import base64
import datetime
import hashlib
import time
import unittest
from types import SimpleNamespace

from support import module, runtime, table
from test_crypto import private_pem, public_pem
from cryptography.hazmat.primitives.asymmetric import ed25519
from http_message_signatures import HTTPMessageSigner, HTTPMessageVerifier, HTTPSignatureKeyResolver
from http_message_signatures.algorithms import ED25519


class Resolver(HTTPSignatureKeyResolver):
    def __init__(self, key):
        self.key = key

    def resolve_public_key(self, key_id):
        assert key_id == 'request-a'
        return public_pem(self.key)

    def resolve_private_key(self, key_id):
        assert key_id == 'request-a'
        return private_pem(self.key)


class AuthTests(unittest.TestCase):
    def setUp(self):
        self.lua = runtime()
        self.auth = module(self.lua, 'scdn_sync.auth')
        self.key = ed25519.Ed25519PrivateKey.generate()
        self.now = int(time.time())
        self.identity = table(self.lua, dict(node_id='node-a', key_id='request-a', enabled=True))
        self.identity[b'public_key'] = public_pem(self.key)
        self.signer_identity = self.lua.table_from({b'key_id': b'request-a', b'private_key': private_pem(self.key)})
        self.body = b'{"protocol":"scdn.sync.v1","node_id":"node-a","request_id":"h1","heartbeat_seq":"1"}'
        self.path = b'/_scdn_sync/v1/heartbeat'

    def request(self, at=None):
        return self.lua.table_from({b'node_id': b'node-a', b'method': b'POST', b'authority': b'MASTER.example.com:8443',
            b'path': self.path, b'body': self.body, b'headers': self.auth.sign_request(
                b'MASTER.example.com:8443', self.path, self.body, self.signer_identity, self.now if at is None else at)})

    def test_lua_signature_verified_by_independent_rfc9421_implementation(self):
        headers = {k.decode().title(): v.decode() for k, v in self.request()[b'headers'].items()}
        message = SimpleNamespace(method='POST', url='https://master.example.com:8443' + self.path.decode(), headers=headers)
        verifier = HTTPMessageVerifier(signature_algorithm=ED25519, key_resolver=Resolver(self.key))
        result = verifier.verify(message, max_age=datetime.timedelta(seconds=60))
        self.assertEqual(result[0].label, 'scdn')
        self.assertIn('"content-digest"', result[0].covered_components)

    def test_independent_rfc9421_signature_verified_by_lua(self):
        message = SimpleNamespace(method='POST', url='https://master.example.com:8443' + self.path.decode(), headers={
            'content-type': 'application/json', 'content-digest': 'sha-256=:' + base64.b64encode(hashlib.sha256(self.body).digest()).decode() + ':'})
        signer = HTTPMessageSigner(signature_algorithm=ED25519, key_resolver=Resolver(self.key))
        created = datetime.datetime.fromtimestamp(self.now, datetime.timezone.utc)
        signer.sign(message, key_id='request-a', created=created, expires=created + datetime.timedelta(seconds=60),
            nonce=base64.urlsafe_b64encode(b'0123456789abcdef').decode().rstrip('='), label='scdn',
            covered_component_ids=('@method', '@authority', '@path', 'content-type', 'content-digest'))
        request = self.request()
        request[b'headers'] = self.lua.table_from({k.lower().encode(): v.encode() for k, v in message.headers.items()})
        self.assertEqual(self.auth.verify_request(request, self.identity, self.now)[b'node_id'], b'node-a')

    def test_missing_credentials_wrong_identity_and_revocation_rejected(self):
        for key, value in ((b'node_id', b'node-b'), (b'public_key', public_pem(ed25519.Ed25519PrivateKey.generate())),
                           (b'key_id', b'wrong-key'), (b'enabled', False), (b'revoked', True)):
            original = self.identity[key]
            self.identity[key] = value
            with self.subTest(key=key), self.assertRaises(Exception):
                self.auth.verify_request(self.request(), self.identity, self.now)
            self.identity[key] = original
        for header in (b'signature', b'signature-input', b'content-digest', b'content-type'):
            request = self.request()
            request[b'headers'][header] = None
            with self.subTest(header=header), self.assertRaises(Exception):
                self.auth.verify_request(request, self.identity, self.now)

    def test_method_path_authority_and_body_tampering_rejected(self):
        for key, value in ((b'method', b'GET'), (b'path', b'/_scdn_sync/v1/reports'),
                           (b'authority', b'other.example.com'), (b'body', self.body + b' '), (b'query', b'x=1')):
            request = self.request()
            request[key] = value
            with self.subTest(key=key), self.assertRaises(Exception):
                self.auth.verify_request(request, self.identity, self.now)

    def test_expired_and_future_signatures_rejected(self):
        for signed_at in (self.now - 91, self.now + 31):
            with self.subTest(signed_at=signed_at), self.assertRaises(Exception):
                self.auth.verify_request(self.request(signed_at), self.identity, self.now)

    def test_local_control_requires_independent_strong_token(self):
        token = b'a' * 43
        self.assertTrue(self.auth.local_authorize(token, token))
        for supplied, expected in ((None, token), (b'b' * 43, token), (b'short', b'short')):
            with self.assertRaises(Exception):
                self.auth.local_authorize(supplied, expected)


if __name__ == '__main__':
    unittest.main()
