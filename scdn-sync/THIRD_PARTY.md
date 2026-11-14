# Dependency provenance

Runtime dependencies are fixed for this implementation. The plugin does not fetch code at startup.

| Component | Version/source | Included material |
|---|---|---|
| lua-resty-http | [v0.17.2](https://github.com/ledgetech/lua-resty-http/tree/v0.17.2) | Original `http.lua`, `http_headers.lua`, `http_connect.lua` and BSD license under `vendor/lua-resty-http/` |
| lua-resty-openssl-aux-module | [0.3.0, commit 9d39a905c30e9b8626b5e787accd99d4333edfba](https://github.com/fffonion/lua-resty-openssl-aux-module/tree/9d39a905c30e9b8626b5e787accd99d4333edfba) | Original HTTP C source/header, nginx `config`, README and BSD license under `vendor/lua-resty-openssl-aux-module/`; unused stream module is omitted |
| lua-resty-openssl | [1.9.0](https://github.com/fffonion/lua-resty-openssl/tree/1.9.0) | Supplied by the tested OpenResty bundle, not copied into this plugin |
| OpenResty test bundle | [1.31.8.1](https://openresty.org/download/openresty-1.31.8.1.tar.gz) | Test-only external build; archive SHA-256 `b569c63b420f80a4ac8466f2deffe73ed93ab760026532e039c3658409a997f4` |
| LuaJIT, cjson.safe, resty.lock, resty.lrucache, ngx.ssl | Tested OpenResty bundle | Supplied by the runtime; no additional copies |

All included third-party files are unmodified. Exact file digests are recorded in `vendor/SHA256SUMS`. Check from that directory with `sha256sum --check SHA256SUMS`. The plugin's `.gitattributes` preserves LF endings so checkout does not alter these digests.

TLS fingerprint probes require the compiled auxiliary module. Its public functions obtain the SSL pointer from the nginx structures compiled for the actual build. Startup explicitly checks the C-backed helper; the plugin does not extend the library's version-specific development fallback.

Cryptographic operations are delegated to lua-resty-openssl/OpenSSL. First-party JOSE and HTTP Message Signature code implements a deliberately fixed protocol profile. Independent `jwcrypto` and `http-message-signatures` implementations validate interoperability in the test suite.

Python `lupa`, `jwcrypto`, `http-message-signatures` and `cryptography` in `tests/requirements.txt` are test-only dependencies. Test fixtures under `tests/fixtures/legacy/` preserve the workspace's existing routing/WAF/limit modules for a checkout without the sibling `lua_files/` directory; fixture provenance is recorded separately there.
