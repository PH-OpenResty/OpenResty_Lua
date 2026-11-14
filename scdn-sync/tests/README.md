# 测试与复现

测试使用临时密钥、临时目录和 loopback 端口。模块测试与真实 Linux/OpenResty 联调分别执行，结果以当前提交的实际输出和 CI 记录为准。

## 模块测试

```sh
python -m pip install -r scdn-sync/tests/requirements.txt
export SCDN_TEST_RESTY_OPENSSL=/path/to/openresty/lualib/?.lua
python -m unittest discover -s scdn-sync/tests -p 'test_*.py' -v
```

Lupa 的 LuaJIT 2.1 执行真实 Lua 模块；密码学使用 lua-resty-openssl 1.9.0 与 OpenSSL 3，并通过独立 JOSE/HTTP 签名实现验证互通。文件存储、共享内存、锁和 SSL 安装接口在模块测试中使用测试替身。

覆盖加密与签名互通、篡改/过期/重放拒绝、证书及路径校验、完整快照、站点删除与停用、发布幂等、应用事务与回退、故障恢复、文件监听和自动续发。

可配置依赖路径：

- `SCDN_TEST_RESTY_OPENSSL`：lua-resty-openssl 的 `lib/?.lua` 路径；默认 `/usr/local/openresty/lualib/?.lua`。
- `SCDN_TEST_OPENSSL`：Windows 必须显式指定 OpenSSL 3 libcrypto DLL 的绝对路径。
- `SCDN_TEST_DEPS`：可选 Python 测试依赖目录。

## 真实 Linux/OpenResty 联调

需要 Linux 64 位、Python `cryptography`，以及编入 HTTP SSL 辅助模块的 OpenResty。Debian/Ubuntu 构建依赖为 `build-essential perl libpcre2-dev libssl-dev zlib1g-dev curl`。

```sh
sh scdn-sync/tests/build-openresty.sh /tmp/openresty-sync
python scdn-sync/tests/integration/run.py \
  --openresty-prefix /tmp/openresty-sync \
  --report /tmp/scdn-sync-results.json
```

构建脚本校验下载归档的 SHA-256，并拒绝覆盖已有 OpenResty 安装。第三方依赖及固定版本见 [THIRD_PARTY.md](../THIRD_PARTY.md)。联调创建独立 Master writer/distributor、两个 Node 业务实例及 Agent、文件监听进程和两个本地源站。

联调覆盖 mTLS、节点隔离、加密对象、真实多 Worker 切换、SNI 证书轮换、文件变更、新增/删除/停用、重启去重、故障隔离、冷启动恢复、Linux 文件权限与符号链接边界。路由/WAF 从相邻 `lua_files/` 加载；仅独立分发插件时使用有摘要的测试副本。

测试结束停止其创建的进程并清理临时材料。`--report` 只记录检查名称、数量和运行时版本，不记录站点正文或凭据；报告应放在仓库外。

## 语法与依赖完整性

```sh
rg --files lua_files scdn-sync -g '*.lua' -g '*.conf.example' -0 | \
  xargs -0 /path/to/openresty/luajit/bin/luajit scdn-sync/tests/check-syntax.lua
(cd scdn-sync/vendor && sha256sum --check SHA256SUMS)
```

必须使用 LuaJIT 解析依赖中的 `\z` 扩展语法。GitHub Actions 工作流 `.github/workflows/scdn-sync.yml` 自动构建隔离环境并执行这些检查。

## 结果边界

隔离测试不证明生产容量或 SLO。systemd 与非 root 服务账户、ARM64、业务全量迁移、真实跨机分区/磁盘故障、历史目录保留和正式切换仍需目标环境验收。
