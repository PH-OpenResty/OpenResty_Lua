# OpenResty Lua

Nginx/OpenResty 的原生 C 配置热更新、业务模块和同步组件，并保留旧 Lua 同步实现供协议对照。仓库只保存可公开的源码、测试和通用配置示例；站点定义、证书、凭据和运行数据由部署环境自行提供。

| 目录 | 内容 |
| --- | --- |
| [`native-config/`](native-config/README.zh-CN.md) | 原生配置监听、后台验证、多 Worker 就绪与内存版本切换 |
| [`native-edge/`](native-edge/README.zh-CN.md) | 原生路由、SNI、缓存选择、热度与指标；不包含 WAF/限速 |
| [`lua_files/`](lua_files/README.md) | 旧业务只读参考与协议测试输入；原配置生成/写入/编译流程已移除 |
| [`scdn-sync/`](scdn-sync/README.zh-CN.md) | Master → Node 配置和证书同步、每节点加密、请求鉴权、文件监听、应用与回退 |
| [`native-sync/`](native-sync/README.zh-CN.md) | 原生 C 模块首版：Master/Node 角色、配置校验、本机控制鉴权、mTLS 节点登记与能力接口 |
| [`doc/`](doc/SCDN-LUA-SYNC-DESIGN.zh-CN.md) | 同步协议、数据模型、架构与接入边界 |
| [`tools/check-publication.py`](tools/check-publication.py) | 发布文件检查，阻止凭据、私钥和运行站点目录被提交 |

## 使用入口

原生模块运行于 Linux，已验证 Nginx 1.31.8 和 OpenResty 1.31.8.1，业务请求不依赖 Lua；配置监听需要 HTTP SSL 与 `--with-threads`。旧 Lua 同步参考需要 OpenResty/LuaJIT 2.1、OpenSSL 3、lua-resty-openssl 1.9.0，以及文档列出的 HTTP SSL 辅助模块，见 [旧同步说明](scdn-sync/README.zh-CN.md)。

新的业务接入使用 [原生配置监听](native-config/README.zh-CN.md)与[原生业务模块](native-edge/README.zh-CN.md)。站点文件直接作为数据输入，后台验证后更新内存中的路由、证书和策略；不发送 HUP、不重建 Worker，也不生成 Lua 或 Nginx 配置。启动配置及站点示例均使用通用路径与保留域名。

原生 Sync 正在独立迁移，当前完成角色与身份基础，尚未实现加密分发、Node 拉取和配置应用事务。原生能力接口明确报告这些功能未启用，完整同步仍由 `scdn-sync` 提供。

公开示例使用 `example.com`、loopback 地址和通用系统目录。`lua_files/examples/site.lua` 默认停用；证书与 token 示例仅引用文件路径，实际材料必须在部署环境生成。切勿在源码工作树中保存真实私钥或把生产站点复制回仓库。

## 验证

```sh
python tools/check-publication.py
sh native-sync/tests/build-runtime.sh /tmp/scdn-native nginx
python native-sync/tests/integration.py --prefix /tmp/scdn-native
python native-edge/tests/integration.py --prefix /tmp/scdn-native
```

测试需要 C 构建依赖和 Python `cryptography`，完整步骤见 [原生业务模块](native-edge/README.zh-CN.md)。旧 Lua 语法、密码学互通和真实进程测试见 [旧同步测试说明](scdn-sync/tests/README.md)。GitHub Actions 分别执行发布检查、原生模块和旧同步测试，具体结果以对应提交的 Actions 记录为准。

## 隐私与发布

公开内容的整理规则及提交前检查见 [PUBLISHING.md](PUBLISHING.md)。`.gitignore` 和检查脚本用于降低误提交风险，仍需人工确认新增文件和 Git 差异。测试运行时生成临时密钥，不提交测试产生的证书、状态或日志。

## 许可

项目沿用本仓库的 [Apache License 2.0](LICENSE)。`scdn-sync/vendor/` 中的第三方源码保留其原始许可与署名，详见 [第三方依赖说明](scdn-sync/THIRD_PARTY.md)。
