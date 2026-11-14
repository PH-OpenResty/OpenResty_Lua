from __future__ import annotations

import json
import unittest

from support import module, runtime
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ed25519, rsa
from jwcrypto import jwk, jwe, jws


def private_pem(key):
    return key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                             serialization.NoEncryption())


def public_pem(key):
    return key.public_key().public_bytes(serialization.Encoding.PEM,
                                         serialization.PublicFormat.SubjectPublicKeyInfo)


class CryptoTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = runtime()
        cls.crypto = module(cls.lua, 'scdn_sync.crypto')
        cls.codec = module(cls.lua, 'scdn_sync.codec')
        cls.rsa = rsa.generate_private_key(public_exponent=65537, key_size=3072)
        cls.other = rsa.generate_private_key(public_exponent=65537, key_size=3072)
        cls.ed = ed25519.Ed25519PrivateKey.generate()

    def test_lua_jwe_decrypted_by_jwcrypto(self):
        plaintext = b'{"site":"secret.example.com","private_key":"fixture"}'
        compact = self.crypto.encrypt(plaintext, public_pem(self.rsa), b'node-key')
        self.assertNotIn(b'secret.example.com', compact)
        decoded = jwe.JWE()
        decoded.deserialize(compact.decode(), key=jwk.JWK.from_pem(private_pem(self.rsa)))
        self.assertEqual(decoded.payload, plaintext)

    def test_jwcrypto_jwe_decrypted_by_lua(self):
        wrapped = jwe.JWE(b'confidential', protected=json.dumps({
            'alg': 'RSA-OAEP-256', 'enc': 'A256GCM', 'kid': 'node-key',
            'typ': 'scdn+jwe', 'cty': 'application/json'}))
        wrapped.add_recipient(jwk.JWK.from_pem(public_pem(self.rsa)))
        self.assertEqual(self.crypto.decrypt(wrapped.serialize(compact=True).encode(),
                         private_pem(self.rsa), b'node-key'), b'confidential')

    def test_jws_interoperability(self):
        compact = self.crypto.wrap(b'encrypted.payload', private_pem(self.ed), b'master-key')
        parsed = jws.JWS()
        parsed.deserialize(compact.decode())
        parsed.verify(jwk.JWK.from_pem(public_pem(self.ed)))
        self.assertEqual(parsed.payload, b'encrypted.payload')
        signed = jws.JWS(b'other.payload')
        signed.add_signature(jwk.JWK.from_pem(private_pem(self.ed)), protected=json.dumps({
            'alg': 'EdDSA', 'kid': 'master-key', 'typ': 'scdn+jws', 'cty': 'scdn+jwe'}))
        keys = self.lua.table_from({b'master-key': public_pem(self.ed)})
        self.assertEqual(self.crypto.unwrap(signed.serialize(compact=True).encode(), keys), b'other.payload')

    def test_wrong_node_key_and_tampering_rejected(self):
        compact = self.crypto.encrypt(b'configuration', public_pem(self.rsa), b'node-key')
        with self.assertRaises(Exception):
            self.crypto.decrypt(compact, private_pem(self.other), b'node-key')
        parts = compact.split(b'.')
        tag = self.codec.unb64(parts[4])
        parts[4] = self.codec.b64(bytes([tag[0] ^ 1]) + tag[1:])
        with self.assertRaises(Exception):
            self.crypto.decrypt(b'.'.join(parts), private_pem(self.rsa), b'node-key')
        with self.assertRaises(Exception):
            self.crypto.decrypt(compact, private_pem(self.rsa), b'wrong-key')

    def test_duplicate_json_keys_rejected(self):
        for text in (b'{"a":1,"a":2}', b'{"a":1,"\\u0061":2}', b'{"x":{"a":1,"a":2}}'):
            with self.assertRaises(Exception):
                self.codec.decode(text)


if __name__ == '__main__':
    unittest.main()
