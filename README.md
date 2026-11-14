# OpenResty Lua

基于 OpenResty/LuaJIT 的 HTTP 业务模块与独立站点配置同步插件。仓库只保存可公开的源码、测试和通用配置示例；站点定义、证书、凭据和运行数据由部署环境自行提供。

| 目录 | 内容 |
| --- | --- |
| [`lua_files/`](lua_files/README.md) | 路由、SNI、分层缓存、限速、WAF、指标，以及原有本机 CLI/管理模块 |
| [`scdn-sync/`](scdn-sync/README.zh-CN.md) | Master → Node 配置和证书同步、每节点加密、请求鉴权、文件监听、应用与回退 |
| [`doc/`](doc/SCDN-LUA-SYNC-DESIGN.zh-CN.md) | 同步协议、数据模型、架构与接入边界 |
| [`tools/check-publication.py`](tools/check-publication.py) | 发布文件检查，阻止凭据、私钥和运行站点目录被提交 |

## 使用入口

运行环境为 Linux 64 位、OpenResty/LuaJIT 2.1。同步插件需要 OpenSSL 3、lua-resty-openssl 1.9.0，以及文档列出的 HTTP SSL 辅助模块。完整依赖、初始化和服务示例见 [同步插件说明](scdn-sync/README.zh-CN.md)。

原有业务模块与同步插件分开安装和配置。先阅读 [业务模块说明](lua_files/README.md)，根据自己的目录、账户、源站和 Nginx 配置接入；仓库不附带现成生产站点或完整生产 `nginx.conf`。原有集群 Agent 保留供参考，新同步接入使用 `scdn-sync`。

公开示例使用 `example.com`、loopback 地址和通用系统目录。`lua_files/examples/site.lua` 默认停用；证书与 token 示例仅引用文件路径，实际材料必须在部署环境生成。切勿在源码工作树中保存真实私钥或把生产站点复制回仓库。

## 验证

```sh
python tools/check-publication.py
python -m pip install -r scdn-sync/tests/requirements.txt
export SCDN_TEST_RESTY_OPENSSL=/path/to/openresty/lualib/?.lua
python -m unittest discover -s scdn-sync/tests -p 'test_*.py' -v
```

Lua 语法、第三方摘要和真实 Linux/OpenResty 联调方法见 [测试说明](scdn-sync/tests/README.md)。GitHub Actions 分别执行发布检查和 Linux 集成测试，具体结果以对应提交的 Actions 记录为准。

## 隐私与发布

公开内容的整理规则及提交前检查见 [PUBLISHING.md](PUBLISHING.md)。`.gitignore` 和检查脚本用于降低误提交风险，仍需人工确认新增文件和 Git 差异。测试运行时生成临时密钥，不提交测试产生的证书、状态或日志。

## 许可

项目沿用本仓库的 [Apache License 2.0](LICENSE)。`scdn-sync/vendor/` 中的第三方源码保留其原始许可与署名，详见 [第三方依赖说明](scdn-sync/THIRD_PARTY.md)。
