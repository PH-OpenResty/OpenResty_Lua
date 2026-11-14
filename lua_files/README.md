# Lua 业务模块

本目录整理了现有 OpenResty 业务 Lua 源码。安装前需要按自己的 Nginx 配置设置包路径、共享字典、缓存区、内部 location、服务账户和目录权限。

| 路径 | 职责 |
| --- | --- |
| `src/config.lua`、`src/tier.lua` | 通用配置示例与热度分层 |
| `src/flush_l1_to_l2.lua`、`pre_action.sh` | 缓存文件迁移与 reload/stop 辅助脚本 |
| `lib/route.lua`、`lib/registry.lua`、`lib/sni.lua` | Host 注册表、HTTP 路由与证书选择 |
| `lib/ratelimit.lua`、`lib/waf.lua`、`lib/waf_rules/` | 请求限速和六组 WAF 规则 |
| `lib/metrics.lua` | 请求与缓存指标 |
| `cli/sitectl.lua`、`lib/admin.lua`、`lib/panel.lua` | 原有本机站点管理入口 |
| `cluster/agent.lua`、`lib/cluster/control.lua` | 原有集群快照接口与 Agent |
| `examples/` | 默认停用的站点示例及 loopback Agent 配置模板 |

## 安装与示例

脚本默认安装位置是 `/usr/local/openresty/lua_files`，LuaJIT 和 Nginx 默认来自 `/usr/local/openresty`。缓存使用 `/var/cache/openresty/L1`、`/var/cache/openresty/L2`，日志使用 `/var/log/openresty`；CLI 生成配置的目录是 `/etc/openresty/generated`，HLS 示例目录是 `/var/cache/openresty/hls`。这些是通用默认值，须与实际 Nginx 配置一致。

部署环境中的 `sites/` 与 `cluster/sites/` 用于存放站点，公开仓库仅保留空目录标记。可把 `examples/site.lua` 复制到部署环境的 `sites/demo.lua`，填写自己的 Host、回源、证书等字段后启用；不要把实际文件提交回来。

如需研究旧 Agent，可把 `examples/agent.conf.example` 复制为部署环境的 `cluster/agent.conf`。`.admin_token` 由部署方生成并限制权限，仓库不提供共享 token。`build.sh` 在安装目录中编译 LuaJIT 字节码，生成的 `.ljbc` 不进入版本控制。

## 接入边界

旧管理接口使用查询串 token，鉴权模块本身不限制监听地址；必须由 Nginx 绑定 loopback 或限制管理网访问，并避免把 token 写入访问日志。原 CLI/面板仅适合受信任的本机管理环境，不应直接作为公网管理服务使用。

旧 Agent 会执行站点 Lua 配置，未提供完整的删除对账、逐 Worker 原子切换或证书轮换事务；`rate_limit.conn` 也没有实际连接限额实现。需要配置和证书同步时，按 [`scdn-sync` 文档](../scdn-sync/README.zh-CN.md)接入独立插件，不要让两个发布来源同时管理同一站点目录。

本目录不是完整 Nginx 部署包。`pre_action.sh` 会操作缓存并触发 Nginx reload/quit，不能在尚未确认路径、权限与回退方案时直接执行。
