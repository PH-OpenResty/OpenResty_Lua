# Config / Edge 验证记录

日期：2026-11-14。验证使用独立构建前缀、临时配置、临时证书、loopback 源站和两个真实 Nginx Worker，未修改生产服务。

| 环境与检查 | 本地结果 |
| --- | --- |
| 无 Lua 的 Nginx 1.31.8，严格 C 编译与 UBSan trap 构建 | Config/Edge 47 项、Sync 50 项通过 |
| 完整 OpenResty 1.31.8.1，严格 C 编译 | 本地和 CI 的 Config/Edge 47 项、Sync 50 项通过 |
| 旧 Lua Sync 模块回归 | 54 项通过 |

Config/Edge 检查覆盖启动配置校验与截断输入语料、路由与前缀、URI/查询串、静态文件、SNI、站点新增/删除/停用、回源热更新、在途请求固定旧版本、已有 TLS 连接、证书同路径轮换、空集合与错误候选保留、等待所有 Worker、Worker 重建、缓存选择、指标和源文件只读。

热更新期间核对 Worker PID 未变化；暂停一个 Worker 时，候选版本不提交，恢复后推进。新 TLS 握手使用新证书，已有连接仍可请求。错误配置和不匹配的证书/私钥保留旧版本。

本地 UBSan trap 调试曾定位到上游 Nginx 文件缓存对缺失 ETag 使用 `memcpy(NULL, 0)` 的检查触发点。模块未修改该 Nginx 核心路径；缓存测试源站提供正常 ETag。不能把当前语料通过当作所有 Nginx 缓存路径的 UBSan 证明。

GitHub Actions 对 Nginx 的完整测试启用 ASan/UBSan，并额外构建 OpenResty。远程结果以对应提交的 Actions 记录为准；旧 Lua 的 48 项真实进程联调也应在修改旧目录的 CI 中重新执行。

ASan 只排除 Nginx 为 dlsym 有意导出的三个同名注册表 `ngx_modules`、`ngx_module_names`、`ngx_module_order` 的 ODR 报告，配置见 `native-sync/tests/asan.supp`；其余内存诊断仍生效。UBSan 在发现错误时中止，不把错误配置的异常退出当作测试通过。

当前不证明生产吞吐、容量上限、ARM64、HTTP/2/HTTP/3 完整行为或 TLS 会话恢复策略。动态站点格式与启动配置的边界见 [native-config](../../native-config/README.zh-CN.md)，原生 Master→Node 加密同步仍在迁移。
