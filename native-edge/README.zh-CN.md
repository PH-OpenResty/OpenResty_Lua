# 原生业务模块

`ngx_http_scdn_edge_module.so` 使用 [native-config](../native-config/README.zh-CN.md) 的不可变站点版本，实现 Host 路由、最长前缀选择、站点启停、动态 SNI 证书、缓存层选择、可选热度策略和 Prometheus 指标。模块不依赖 Lua，不包含 WAF 或限速实现。

反向代理、缓存存储和静态文件由 Nginx 自带模块执行。业务模块提供 `$scdn_edge_site`、`$scdn_edge_upstream`、`$scdn_edge_root`、`$scdn_edge_cache` 与 `$scdn_edge_revision`，保持请求中的版本一致；内部跳转也会保留请求版本。完整接入见 [nginx.conf 示例](examples/nginx.conf)和[站点文件](../native-config/examples/sites.conf)。

## 接入要点

- 先加载配置模块，再加载业务模块。在 `http` 中设置 `scdn_edge_zone counters 2m`，受管理的 server 设置 `scdn_edge on`。
- 默认通过命名 location `@scdn_edge_proxy` 执行代理，也可用 `scdn_edge_proxy_location` 修改。`proxy_pass $scdn_edge_upstream` 保留原 URI，`proxy_cache $scdn_edge_cache` 选择已声明的 l1/l2/off 缓存区。
- 缓存键应包含 `$scdn_edge_revision`，避免切换源站后仍返回旧版本的缓存对象。缓存文件不跨层复制，原缓存内容由 Nginx 自身过期/淘汰。
- 静态根目录使用 `root $scdn_edge_root`，建议启用 `disable_symlinks on`。未知 Host 或停用站点返回 403；Worker 尚未加载当前版本时返回 503。
- TLS server 使用 `scdn_edge_tls on`，并提供 Nginx 启动所需的本机 bootstrap 证书。证书回调只从已准备的内存对象选择，不在握手时读文件。未知 SNI、未启用 TLS 或过期证书拒绝握手。
- 原生 TLS 回调独占所管理的 SSL_CTX 证书选择，不能与 Lua 证书回调或变量证书配置混用。完整会话恢复策略需按场景验证；示例关闭 session cache/tickets，逐请求的 Host 检查仍然执行。

## 指标与热度

`scdn_edge_metrics;` 放在本机只读 location 中，导出每站点请求、字节、状态分类与缓存结果。运行时检查实际 Unix/loopback 连接。统计站点 ID 历史最多 1024 个，计数保留到实例/共享区生命周期结束；超出后业务继续服务，但新 ID 不增加标签。计数采用原子更新，指标抓取不是跨所有计数的事务快照。

热度表固定 4096 项，按站点/Host/URI 隔离，冲突或窗口结束会重置。它是有界的缓存选择提示，不是请求限流，也不保证所有访问历史都保留。不要用它实施安全或计费决策。

## 构建和测试

统一构建脚本现在编译 Sync、Config、Edge 三个动态模块，需目标 Nginx 支持 HTTP SSL 与线程池：

```sh
sh native-sync/tests/build-runtime.sh /tmp/scdn-native nginx
python native-sync/tests/integration.py --prefix /tmp/scdn-native
python native-edge/tests/integration.py --prefix /tmp/scdn-native
```

运行时参数也可为 `openresty`。测试使用临时配置、证书、源站与 loopback 端口，验证不更换 Worker 的路由和证书更新、旧请求/已有 TLS 连接、错误候选保留、空配置保护、Worker 重建、缓存和指标。测试报告必须写在源码工作树之外。

## 原 Lua 配置写入流程已移除

删除了旧 sitectl、panel/admin 管理入口、集群源码写入/编译 Agent、build 字节码脚本和缓存复制/reload 辅助脚本。新的运行路径只读源文件，不生成 `.lua`、`.ljbc` 或 nginx 配置。剩余 `lua_files` 用于旧同步协议测试与历史对照，未参与这两个原生模块的业务请求。

原生 Sync 的加密分发与 Node 拉取仍在迁移，不能把本机文件热更新描述成 Master→Node 远程同步已经完成。
