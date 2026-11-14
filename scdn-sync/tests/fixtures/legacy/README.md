# Legacy business test fixtures

Unmodified snapshots of the workspace Lua routing, rate-limit and WAF modules, captured on 2026-11-06. These are test-only fallback inputs when the sibling `lua_files/` directory is absent. Runtime adapters remain in `compat/`; these fixtures are never installed as plugin business code.

| Source under `lua_files/lib/` | SHA-256 |
|---|---|
| `route.lua` | `9759017492cac27c7f269b4e418cb3f22d2c9a30f921077472f4aa0b175ffd2e` |
| `ratelimit.lua` | `2339ae8aca530952806eed1276f38d5daa4e15a8612edf010b03b293d48c3188` |
| `waf.lua` | `eea893ec2615e328586adf3060ff49f7cc8d8e49e53681afddedd6014b25aa36` |
| `waf_rules/sqli.lua` | `147701e9cbbdde2712831156b7089d8327f9813ad88095be13ca1efacf9d401b` |
| `waf_rules/xss.lua` | `fa124a3edf4f9d87de20a28b7cf2d77bce4e572b0184ce1ff8ec1cc4759878d2` |
| `waf_rules/lfi.lua` | `eb8036bcc6059081d6cd828b716c857a118347f40a5672aa3642459ea78174c0` |
| `waf_rules/rce.lua` | `8567ffdc36e3d9f1e6feb57120ee731f6890cbb301d8b23228bd9b2c7d57417d` |
| `waf_rules/scanner.lua` | `d1322cc5e4617b086d9256214987d6b938d3608cdaacb05b91fa616dfe65d95b` |
| `waf_rules/protocol.lua` | `93ef8fc401ef99cd2492ddade8e88f0f9ff8c1b8d712ac140b522659794075d7` |
