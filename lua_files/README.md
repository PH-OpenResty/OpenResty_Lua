# 旧 Lua 业务参考

当前业务运行路径已迁移到 [native-config](../native-config/README.zh-CN.md) 与 [native-edge](../native-edge/README.zh-CN.md)，支持监听独立站点文件并在不重建 Worker 的情况下更新路由、证书与缓存策略。原生模块不包含 WAF 和限速。

本目录保留旧路由、注册表、SNI、指标、热度、WAF 和请求限速脚本，作为已有 Lua Sync 联调与行为对照输入；它们不属于新原生模块的运行依赖。

已删除的旧运行入口包括：

- `cli/sitectl.lua` 和 `lib/panel.lua`：生成站点定义、stream/RTMP 配置并落盘。
- `lib/admin.lua`、`lib/cluster/control.lua` 和 `cluster/agent.lua`：旧注册表 reload、远程源码写入、字节码编译和站点文件更新。
- `build.sh`：站点与业务 Lua 字节码生成。
- `pre_action.sh` 与 `src/flush_l1_to_l2.lua`：直接复制缓存并触发 Nginx reload/quit。

`sites/` 和 `cluster/sites/` 仅保留空目录标记。历史 Lua 站点示例仍供旧测试理解字段，新配置格式见 [sites.conf](../native-config/examples/sites.conf)。

旧 `scdn-sync` 的 journal、密文、应用记录等持久化是其协议恢复机制，不是被删除的站点配置生成入口；原生端到端同步仍需后续迁移，不能将本机热更新当作远程分发完成。
