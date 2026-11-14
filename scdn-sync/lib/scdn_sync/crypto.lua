-- Fixed JOSE profile. Cryptographic primitives are supplied by lua-resty-openssl.
local pkey = require 'resty.openssl.pkey'
local cipher = require 'resty.openssl.cipher'
local digest = require 'resty.openssl.digest'
local rand = require 'resty.openssl.rand'
local u = require 'scdn_sync.util'
local json = require 'scdn_sync.codec'
local M = {}
local oaep = { oaep_md = 'sha256', mgf1_md = 'sha256' }

function M.random(size) return u.check(rand.bytes(size), 'random_failed', 500) end
function M.sha256(value, raw)
    local d = u.check(digest.new('sha256'), 'crypto_unavailable', 500)
    local bytes = u.check(d:final(value), 'crypto_failed', 500)
    if raw then return bytes end
    return (bytes:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end
function M.key(pem, kind, private)
    local key = type(pem) == 'string' and pkey.new(pem)
    u.check(key, 'invalid_key')
    local nid = key:get_key_type(true)
    u.check((kind == 'rsa' and nid == 6) or (kind == 'ed25519' and nid == 1087), 'key_algorithm')
    if private then u.check(key:is_private(), 'private_key_required') end
    if kind == 'rsa' then
        local params = u.check(key:get_parameters(), 'invalid_key')
        local n = u.check(params.n:to_binary(), 'invalid_key')
        local bits, first = (#n - 1) * 8, n:byte(1)
        while first and first > 0 do bits = bits + 1; first = math.floor(first / 2) end
        u.check(bits >= 3072 and bits <= 8192, 'rsa_key_size')
    end
    return key
end
function M.sign(value, pem)
    return u.check(M.key(pem, 'ed25519', true):sign(value), 'sign_failed', 500)
end
function M.verify(value, signature, pem)
    u.check(type(signature) == 'string' and #signature == 64, 'invalid_signature', 401)
    u.check(M.key(pem, 'ed25519'):verify(signature, value), 'invalid_signature', 401)
    return true
end

local function split(compact, count)
    u.check(type(compact) == 'string' and #compact <= u.MAX_BYTES * 2, 'envelope_size', 413)
    local parts = {}
    for part in (compact .. '.'):gmatch('(.-)%.') do parts[#parts + 1] = part end
    u.check(#parts == count, 'invalid_envelope')
    return parts
end
function M.encrypt(plaintext, public_pem, kid, content_type)
    u.check(u.id(kid) and type(plaintext) == 'string' and #plaintext <= u.MAX_BYTES, 'encryption_input')
    local header = json.b64(json.encode({ alg = 'RSA-OAEP-256', enc = 'A256GCM', kid = kid,
        typ = 'scdn+jwe', cty = content_type or 'application/json' }))
    local cek, iv = M.random(32), M.random(12)
    local encrypted_key = u.check(M.key(public_pem, 'rsa'):encrypt(cek, pkey.PADDINGS.RSA_PKCS1_OAEP_PADDING, oaep), 'encryption_failed', 500)
    local aes = u.check(cipher.new('aes-256-gcm'), 'crypto_unavailable', 500)
    local ciphertext = u.check(aes:encrypt(cek, iv, plaintext, true, header), 'encryption_failed', 500)
    local tag = u.check(aes:get_aead_tag(16), 'encryption_failed', 500)
    return table.concat({ header, json.b64(encrypted_key), json.b64(iv), json.b64(ciphertext), json.b64(tag) }, '.')
end
function M.decrypt(compact, private_pem, expected_kid)
    local parts = split(compact, 5)
    local header = json.decode(json.unb64(parts[1], 1024), 1024)
    u.keys(header, u.fields('alg enc kid typ cty'))
    u.check(header.alg == 'RSA-OAEP-256' and header.enc == 'A256GCM' and header.typ == 'scdn+jwe'
        and header.cty == 'application/json' and header.kid == expected_kid, 'untrusted_encryption_header')
    local key = M.key(private_pem, 'rsa', true)
    local encrypted_key, iv, ciphertext, tag = json.unb64(parts[2], 1024), json.unb64(parts[3], 12),
        json.unb64(parts[4]), json.unb64(parts[5], 16)
    u.check(#encrypted_key == key:get_size() and #iv == 12 and #tag == 16, 'invalid_encryption_parameters')
    local cek = key:decrypt(encrypted_key, pkey.PADDINGS.RSA_PKCS1_OAEP_PADDING, oaep)
    u.check(cek and #cek == 32, 'decryption_failed')
    local aes = u.check(cipher.new('aes-256-gcm'), 'crypto_unavailable', 500)
    local plaintext = aes:decrypt(cek, iv, ciphertext, true, parts[1], tag)
    return u.check(plaintext, 'decryption_failed')
end
function M.wrap(jwe, private_pem, kid)
    u.check(u.id(kid), 'invalid_key_id')
    local header = json.b64(json.encode({ alg = 'EdDSA', kid = kid, typ = 'scdn+jws', cty = 'scdn+jwe' }))
    local signing_input = header .. '.' .. json.b64(jwe)
    return signing_input .. '.' .. json.b64(M.sign(signing_input, private_pem))
end
function M.unwrap(jws, public_keys)
    local parts = split(jws, 3)
    local header = json.decode(json.unb64(parts[1], 1024), 1024)
    u.keys(header, u.fields('alg kid typ cty'))
    u.check(header.alg == 'EdDSA' and header.typ == 'scdn+jws' and header.cty == 'scdn+jwe'
        and u.id(header.kid) and public_keys[header.kid], 'untrusted_signing_header', 401)
    M.verify(parts[1] .. '.' .. parts[2], json.unb64(parts[3], 64), public_keys[header.kid])
    return json.unb64(parts[2], u.MAX_BYTES * 2)
end
return M
