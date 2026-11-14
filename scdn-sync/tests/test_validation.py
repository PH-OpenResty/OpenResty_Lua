from __future__ import annotations

import datetime
import time
import unittest

from support import module, runtime, table
from test_crypto import private_pem
from test_pipeline import site
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID


class ValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        cls.other_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    def setUp(self):
        self.lua = runtime()
        self.validator = module(self.lua, 'scdn_sync.validate')
        self.checker = module(self.lua, 'scdn_sync.certificates')
        self.codec = module(self.lua, 'scdn_sync.codec')
        self.now = int(time.time())

    def material(self, sans=('www.example.com',), expired=False):
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'test certificate')])
        now = datetime.datetime.fromtimestamp(self.now, datetime.timezone.utc)
        certificate = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(self.key.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(days=2))
            .not_valid_after(now + datetime.timedelta(days=-1 if expired else 2))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName(value) for value in sans]), critical=False)
            .sign(self.key, hashes.SHA256()))
        return table(self.lua, dict(certificate_id='cert-demo', version=1,
            chain_pem=certificate.public_bytes(serialization.Encoding.PEM).decode(), private_key_pem=private_pem(self.key).decode()))

    def test_certificate_key_san_and_expiry_failures_rejected(self):
        good = self.material()
        checked = self.checker.check(good, table(self.lua, ['www.example.com']), self.now)
        self.assertEqual(len(checked[b'fingerprint']), 64)
        wrong_key = self.material()
        wrong_key[b'private_key_pem'] = private_pem(self.other_key)
        for material, hosts in ((wrong_key, ['www.example.com']), (self.material(), ['other.example.com']),
                                (self.material(expired=True), ['www.example.com'])):
            with self.assertRaises(Exception):
                self.checker.check(material, table(self.lua, hosts), self.now)

    def test_certificate_wildcard_covers_exactly_one_dns_label(self):
        material = self.material(sans=('*.example.com',))
        self.checker.check(material, table(self.lua, ['www.example.com']), self.now)
        for name in ('example.com', 'a.b.example.com'):
            with self.assertRaises(Exception):
                self.checker.check(material, table(self.lua, [name]), self.now)

    def test_domain_endpoint_and_static_path_boundaries(self):
        for name in ('', '.example.com', 'example..com', '-a.example', 'a-.example', 'EXAMPLE.COM', 'example.com.'):
            self.assertFalse(self.validator.host(name.encode()))
        self.assertTrue(self.validator.host(b'www.example.com'))
        self.assertFalse(self.validator.endpoint(b'origin.example.com:65536'))
        policy = table(self.lua, dict(static_roots=['/srv/sites']))
        for root in ('/srv/sites/../secrets', '/srv/sites/./demo', '/srv/sites-escape/demo', '/srv/sites\\escape', '/srv/sites//demo'):
            value = site(tls=False)
            value['root'] = root
            with self.subTest(root=root), self.assertRaises(Exception):
                self.validator.site(table(self.lua, value), policy)

    def test_json_number_and_collection_types_are_strict(self):
        for invalid in (b'01', b'-01', b'1.', b'1.e2', b'1e+', b'1+1', b'NaN', b'1e9999', b'{"x":1,}', b'[1,]'):
            with self.subTest(value=invalid), self.assertRaises(Exception):
                self.codec.decode(invalid)
        for valid in (b'0', b'-0', b'1.25', b'1e2', b'-2.1E-2'):
            self.assertIsInstance(self.codec.decode(valid), (int, float))
        self.assertTrue(self.codec.is_array(self.codec.decode(b'[]')))
        self.assertFalse(self.codec.is_array(self.codec.decode(b'{}')))

    def test_decimal_sequence_comparison_preserves_large_integers(self):
        util = module(self.lua, 'scdn_sync.util')
        self.assertEqual(util.increment(b'9007199254740992'), b'9007199254740993')
        self.assertEqual(util.compare(b'9007199254740993', b'9007199254740992'), 1)
        self.assertEqual(util.compare(b'10', b'9'), 1)
        with self.assertRaises(Exception):
            util.increment(b'9' * 32)
        self.assertNotEqual(util.decimal(9007199254740991), util.decimal(9007199254740990))
        self.assertEqual(self.codec.encode(self.codec.decode(b'9007199254740991')), b'9007199254740991')


if __name__ == '__main__':
    unittest.main()
