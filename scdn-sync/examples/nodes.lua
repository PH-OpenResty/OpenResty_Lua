local read = require('scdn_sync.config').read
return {
    ['node-a'] = {
        node_id = 'node-a', scope_id = 'edge', enabled = true,
        -- SHA-256 of the client certificate DER, not PEM text or a request-supplied ID.
        tls_certificate_sha256 = 'REPLACE_WITH_64_LOWERCASE_HEX_CHARACTERS',
        decryption_key_id = 'decrypt-a',
        encryption_public_key = read('/etc/scdn-sync/public/node-a-rsa.pem'),
        key_id = 'request-a',
        public_key = read('/etc/scdn-sync/public/node-a-ed25519.pem'),
        static_roots = { '/srv/sites' },
    },
}
