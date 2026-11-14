# SCDN Lua/OpenResty 独立同步插件

版本：0.2.0。同步方向为 Master → Node，配置采用按节点加密的完整快照。实现保留现有路由、缓存、限速和 WAF 模块，通过可选 `lib.registry`、`lib.sni` 适配层接入。

支持域名、回源、缓存层、WAF、限速参数、站点启停和删除，以及证书链/私钥更新。Master 可自动检测原站点配置文件及引用证书的内容变化，合并后发布，Node 自动拉取并热切换。静态站点内容、stream/RTMP、证书签发、面板和管理 CLI 不在本版范围；同时提供内部 Lua 发布 API。

本目录包含代码、配置模板、systemd 示例和测试；没有安装或接管生产服务。测试方法见 [测试说明](tests/README.md)，协议与原脚本审计见 [设计文档](../doc/SCDN-LUA-SYNC-DESIGN.zh-CN.md)。

## 进程与文件

| 部件 | 入口 | 职责 |
|---|---|---|
| Master 发布进程 | `scdn_sync.master.publish` | 校验完整站点集合和证书，生成每个 Node 的密文；不可变文件全部持久化后原子提交 desired |
| Master 文件监听进程 | `bin/watch.lua` | 独立 resty；有界扫描、变更合并、站点/证书版本登记、逐节点发布与失败重试 |
| Master 分发实例 | `conf/master-distributor.nginx.conf` | 独立 OpenResty；mTLS 节点授权、ETag、密文下载、转交报告 |
| Master 持久化实例 | `conf/master-writer.nginx.conf` | 独立单 Worker；报告验签、重放登记、幂等收据与每节点状态持久化 |
| Node 同步进程 | `bin/node.lua` | 独立 resty 进程；下载、验签解密、journal、应用与回退、持久报告和心跳 |
| Node 业务运行时 | `runtime/engine.lua`、`runtime/registry.lua` | 各 Worker 预载不可变代际，短事务切换 active 指针；业务路径不访问 Master |
| 旧模块适配 | `compat/lib/registry.lua`、`compat/lib/sni.lua` | 保持 `lookup/hosts/set_cert` 接口；旧的直接 reload 被拒绝 |

不能用在业务 OpenResty 内多加一个 `server {}` 代替独立分发/持久化进程。coroutine 和 timer 不隔离同步磁盘 I/O。发布、写入与下载实例仍共享所在主机的 CPU、磁盘和网络，进程隔离不等于整机高可用。

```text
Master 数据目录：
  nodes/<node_id>/desired.json
  nodes/<node_id>/state.json
  nodes/<node_id>/releases/<revision_id>/
    manifest.jws                 # JWS 包装的 JWE；站点配置不在外层
    objects/<sha256>.jwe         # 证书链和私钥的节点独立密文
    metadata.json               # 发布归属、序号、密文摘要；没有站点正文和 PEM
  watch/process.lock            # 独立监听进程锁
  watch/<scope_id>/sites/<site_id>.json
  watch/<scope_id>/certificates/<certificate_id>.json  # 仅内容摘要与单调资源版本

Node 数据目录：
  highest.json                   # 已验证最高序号与封装摘要
  applied.json                   # 通过健康检查且已持久化的版本
  journal.json                   # 未完成事务；恢复完成后删除
  outbound-sequence
  reports/<request_id>.json      # 待 ACK 的有界持久队列
  releases/<revision_id>/
    manifest.jws
    objects/<sha256>.jwe
    runtime.json                 # Node 本机使用的解密后配置和证书
```

Node 必须能在 Master 离线时读取自己的配置和私钥，因此 `runtime.json` 是本机明文。生产文件适配器采用 Linux 64 位 `openat/O_NOFOLLOW`、目录 0700、文件 0600、`fsync + rename + 目录 fsync`；备份须保留同等访问控制并加密。Master 的原始证书输入也必须放在受限位置。

## 运行依赖

- Linux x86_64/ARM64、LuaJIT 2.1、启用 HTTP TLS 的 OpenResty；本地文件适配器拒绝 Windows 和 32 位系统。
- `lua-resty-openssl` 1.9.0，OpenSSL 3；RSA-OAEP/MGF1 均为 SHA-256，AES-256-GCM、Ed25519 必须可用。
- 已随目录固定的 `lua-resty-http` 0.17.2，及 OpenResty 自带的 `cjson.safe`、`resty.lock`、`resty.lrucache`、`ngx.ssl`。
- Node 的 TLS 指纹探测要求编入 `vendor/lua-resty-openssl-aux-module` 的 HTTP 辅助模块 0.3.0。Agent 在启动时检查依赖，缺少时返回 `tls_probe_dependency_unavailable`。不依赖库内按 Nginx 版本猜测结构偏移的开发回退模式。

构建辅助模块时，在匹配的 OpenResty 源码中添加原有构建参数：

```sh
NGX_LUA_LOC=/path/to/openresty/build/ngx_lua-VERSION \
  ./configure --add-module=/opt/scdn-sync/vendor/lua-resty-openssl-aux-module ...
```

`NGX_LUA_LOC` 指向配置过程中生成的 **build 副本**；`bundle` 原始副本没有 `ngx_http_lua_autoconf.h`。现有安装的构建参数、动态模块和服务归属需要保留。测试构建脚本见 `tests/build-openresty.sh`；它只用于独立测试前缀。第三方来源和摘要见 [THIRD_PARTY.md](THIRD_PARTY.md)。

## 初始配置与接入

1. 将插件安装到独立目录，例如 `/opt/scdn-sync`；修改模板中的 OpenResty 安装路径和服务账户。
2. 为 Master 配置一份节点登记表，使用 `examples/nodes.lua`。每个 Node 绑定独立 RSA 解密公钥、Ed25519 请求公钥及 mTLS 叶证书 DER 的 SHA-256。不能把 PEM 文本摘要当作证书指纹。
3. 配置 Master 的发布私钥、受信任 Node CA、服务器证书及独立内部 token。分别使用 `examples/publisher.lua`、`examples/master-writer.lua`、`examples/master-distributor.lua`。
4. 每个 Node 本地产生并保管自己的解密私钥、请求签名私钥、mTLS 身份和独立控制 token；使用 `examples/node.lua`。`master_endpoint`、SNI、authority、端口和 CA 均可配置。
5. 按 `examples/runtime.lua` 配置业务实例。该配置不加载 Node 的长期解密/请求签名私钥，但业务 Worker 必须持有已生效站点的 TLS 私钥。
6. 合并 `conf/node-http.conf` 的 http 级指令。已有 `init_by_lua`、`init_worker_by_lua` 中的原逻辑也须保留。托管范围内的完整站点集合准备好后再启用兼容包路径；未导入的站点会按未知 Host 拒绝。
7. 每个受管理 HTTP/HTTPS server 加入 `conf/node-server-probe.conf`；HTTPS 使用 `ssl_certificate_by_lua_block { require('scdn_sync.runtime.registry').set_cert() }`。启动 Nginx 仍需要本机引导证书配置；未知 SNI 或该站点禁用 HTTPS 时握手失败。
8. 创建受限的运行和数据目录。`deploy/scdn-sync.tmpfiles.conf`、service 文件提供示例；先创建对应账户、目录与所有权。控制目录由 tmpfiles 管理，避免停止 Agent 服务时删掉仍由业务 Nginx 使用的 Socket。
9. 分别检查独立配置，启动 writer、distributor、已接入的业务实例与 Agent。正式接入前备份并验证现有配置、证书、版本和回退路径。

如使用静态目录，`static_roots` 是 Node 本机允许的目录前缀，启用站点的目录必须存在且不含符号链接。业务静态 location 还应设置 `disable_symlinks on;`，阻止应用完成后目录被替换为符号链接所带来的越界访问。这里的检查只验证本机目录，不同步站点文件。

模板中的 Master 发布、writer、distributor 使用相同专用 UID 访问数据；这是进程隔离，**不构成同 UID 之间的私钥权限隔离**。需要更严格的 OS 访问边界时，应配套独立 UID、组/ACL 与只读存储权限。数据目录不能对其他租户开放。

Node Agent 和业务实例的主进程需要按配置读取各自必需的本地文件；Agent 必须能遍历控制 Socket 的私有父目录。修改证书、公钥登记或撤销节点后，须同步更新相关 Master 配置并重载独立实例；当前没有自动注册、远程改信任根或自动密钥轮换服务。

## Master 文件变更钩子

监听器运行在独立 resty 进程，默认每 1 秒按内容摘要扫描一次；同一完整文件集合连续稳定至少 2 秒后才构建发布。它不在业务请求中扫描目录，也不等待 Node ACK。Node 复用原有 mTLS 拉取、验签解密、预载/切换/探测事务，更新站点时不重启 Nginx、不替换 Worker。

1. 将 [examples/master-watch.lua](examples/master-watch.lua) 安装为 `/etc/scdn-sync/master-watch.lua`，复用 `publisher.lua` 中的发布密钥与节点表。
2. 为每个托管范围设置 `scope_id`、`sites_dir`、`node_ids` 和 `certificate_roots`。默认示例目录是原 Master 的 `/usr/local/openresty/lua_files/cluster/sites`；如站点定义保存在其他目录，按实际路径修改。
3. 将该范围的完整站点集合放入目录；一个站点一个 `.lua` 或 `.json` 文件。启用 [deploy/scdn-sync-watch.service](deploy/scdn-sync-watch.service)，或在隔离测试环境直接运行：

```sh
/usr/local/openresty/bin/resty -I /opt/scdn-sync/lib \
  /opt/scdn-sync/bin/watch.lua /etc/scdn-sync/master-watch.lua
```

原站点文件结构可以直接使用，例如 `demo.lua`：

```lua
return {
    name = 'demo', enabled = true,
    server_names = { 'www.example.com' },
    root = '', upstream = '127.0.0.1:8080',
    cache = { layer = 'l2' },
    ssl = { cert = '/etc/scdn-sync/certificates/demo.pem',
            key = '/etc/scdn-sync/certificates/demo.key' },
    rate_limit = { enabled = false, req_per_sec = 0, burst = 0 },
    waf = { enabled = true, groups = { 'sqli', 'xss' }, threshold = 5 },
}
```

`.json` 使用相同字段的数据结构。Lua 文件只接受 `return { ... }` 的数据字面量、注释和字符串转义；不执行函数、`require`、表达式或字节码。`site_id` 缺省取文件名，`name` 也可缺省；`resource_version` 自动登记，显式提供时作为版本下限。旧的零请求速率仅在限速关闭时规范为内部合法值；原 `rate_limit.conn` 没有连接限额实现，本适配不会使它生效。`port_forward/live` 等超出 HTTP 同步范围的字段被拒绝。

- **新增/修改**：添加文件或修改原文件即可触发；原子 rename 保存、同名替换、删除后重建目录均由后续扫描重新识别。以内容摘要判断，单纯时间戳变化不会重发。
- **证书更新**：读取 `ssl.cert/key` 白名单路径中的实际 PEM，原路径内容更换也会触发。自动登记新的证书版本并校验证书链、SAN、有效期和私钥配对。禁用站点无需证书文件可用。
- **删除/禁用**：删除文件即从完整快照移除，`enabled=false` 停用站点。默认 `allow_empty=false`，空目录保留上一发布；需要自动删除最后一个站点时，在该范围配置 `allow_empty=true`。
- **异常处理**：文件写到一半、格式错误、路径越界、缺证书、重复域名或源目录不可读时，保留当前 desired 和 Node 已生效版本，修复后自动重新合并发布。单个节点发布失败按退避重试，其他目标仍可推进。
- **重启与续发**：发布提交中包含源摘要；监听器重启或通知前退出不会重复提交相同内容。默认清单有效期 3600 秒，提前 300 秒自动续发，便于离线节点恢复后取得有效清单。

目录和 PEM 只读打开，不创建源目录、不改变其权限，并拒绝路径中的符号链接。ACME 等工具需将最终证书/私钥交付为白名单目录内的普通文件。建议写入临时文件后原子替换；稳定窗口不能代替跨文件事务，若一次修改多个站点/证书，应在同一维护写入流程中完成后再让其稳定。持续编辑期间会继续使用当前版本。

默认发现和应用延迟由扫描间隔、2 秒稳定窗口、分发索引刷新、Node 约 5 秒轮询及健康检查组成；这不是立即推送或固定时延保证。`watch` 配置、节点登记、公钥与信任根仍需重启/重载对应独立服务。每个 Node/scope 由一个配置来源管理，避免与手工发布器、旧 Agent 或第二个监听器同时争用；跨节点分批灰度仍由后续管理层负责。

单范围最多 1000 个站点，单源文件最多 256 KiB，一次读取的站点与去重 PEM 总量最多 4 MiB；全目录枚举最多 4096 个条目，监听范围最多 16 个。输入和输出均校验边界，超限不会发布部分站点。版本登记与发布历史同样需要受控磁盘保留策略。

## 发布 API

发布者由本机受信任流程调用 Lua 模块。没有公开 publish HTTP 接口，也没有复用 Node 身份授予管理权限。

```lua
local config = require 'scdn_sync.config'
local json = require 'scdn_sync.codec'
local settings = config.load('/etc/scdn-sync/publisher.lua')
local store = require('scdn_sync.fs').open(settings.data_dir)
local publisher = require('scdn_sync.master.publish').new(store, settings)
local input = json.decode(config.read('/restricted/release-input.json', 4 * 1024 * 1024))
local published = publisher:publish(input, ngx.time())
-- 记录 published 的 release_id / revision_id / desired_seq，不能记录原始私钥。
```

`input` 的字段为 `node_id, scope_id, release_id?, ttl_seconds?, sites[], certificates[], tombstones[]?`。单个站点的完整结构见设计文档第 3.2 节。证书材料为 `{certificate_id, version, chain_pem, private_key_pem}`；只传入启用站点实际引用的证书。使用本机 Lua 表调用时，空数组等集合须通过 `scdn_sync.codec.array` 显式标记；从 JSON 解析的数组自动保留类型。

每次提交是该 Node/scope 的完整配置，缺失站点即删除；`tombstones` 用于删除记录，并非增量执行入口。证书更新需要新证书版本与新的完整节点发布。恢复历史内容也会产生新的单调发布序号；不能直接把 desired 指向旧序号。

`resource_version` 在协议中保留为资源元数据；草稿存储、编辑冲突检查及跨节点发布调度属于后续管理层。当前调用者负责准备完整一致的输入，每节点进程锁负责提交串行化。

## 接口与保护

| 接口 | 必需身份 | 行为 |
|---|---|---|
| `GET /_scdn_sync/v1/desired` | 已登记且未禁用/撤销的 mTLS Node | 只返回本节点签名密文，支持密文 ETag/304 |
| `GET /_scdn_sync/v1/objects/{sha256}` | 同上，并在本节点当前/保留发布的授权集合内 | 返回证书密文；摘要不授予访问权 |
| `POST /_scdn_sync/v1/reports` | mTLS + 固定 RFC 9421/9530 Ed25519 签名 | 校验目标、正文摘要、时效、nonce、业务幂等和发布归属；持久化后 ACK |
| `POST /_scdn_sync/v1/heartbeat` | 同上 | 单调心跳，重复业务重试不延长在线时间 |
| `GET /__scdn_sync/v1/status` | 私有 Unix Socket + 独立 token | 当前事务和各 Worker 状态 |
| `POST /__scdn_sync/v1/stage` | 同上 | 验证范围和预期旧版本，登记预载事务 |
| `POST /__scdn_sync/v1/commit` | 同上 | 确认全部 Worker 准备后切换指针 |
| `POST /__scdn_sync/v1/rollback` | 同上 | 仅回退当前事务到其上一版本 |
| `POST /__scdn_sync/v1/finalize` | 同上 | 结束已提交/已回退事务，释放非活动内存代际 |
| `/internal/index`、`/internal/accept` | Master 本机私有 Socket + 独立内部 token | 仅用于分发实例与 writer 之间通信 |

远程 POST 固定 HTTP/1.1、`Content-Type: application/json`、明确的 Content-Length，不接受 chunked 传输或查询参数。签名覆盖方法、规范化 authority、路径、Content-Type、Content-Digest 和签名参数。有效期最多 60 秒，时钟偏差最多 30 秒；128 位随机 nonce 持久化到保护窗口结束。每次网络重试重签并使用新 nonce，保留业务 request ID。

请求体使用独立总截止时间；超时后取消读取。取消正在读取的下游 cosocket 时，OpenResty 可能直接关闭连接，调用者不能依赖一定收到 HTTP 408；未完成的请求不会进入写入或 ACK 路径。

文件采用 `JWE(RSA-OAEP-256/A256GCM)`；清单外层为固定 Ed25519 的 JWS。Node 先验签再解密。证书对象摘要、受众、版本、SAN、有效期和私钥配对均检查。所有下载设 `Cache-Control: no-store`，请求凭据、完整密文体及私钥不写访问日志或错误响应。

## 故障与并发

- Master 发布未完整提交时 desired 不变；不同 Node 不共用发布锁。分发请求不执行逐次扫描、加密或等待其他 Node。
- writer 使用单独进程，磁盘慢时报告 ACK 会延迟；分发端可继续使用已缓存的发布索引。索引未成功加载时返回 503。
- Node 默认一次轮询、一个对象下载、一个应用事务；报告与心跳使用独立协程。所有网络使用 cosocket，连接/读写超时外还有总截止时间；对象下载和健康探测也有总预算。
- 初始默认值：5 秒轮询、10 秒心跳，随机抖动 20%，指数退避最多 60 秒；报告队列 256，满时停止新应用。分发模板设置每节点/全局连接数、请求速率和下载带宽上限。
- 所有 Worker 先预载并确认准备，短锁推进 active 指针；请求在 `lookup` 时固定代际。新生 Worker 在准备完成前返回 503，不使用半成品。
- 路由检查及新的 TLS 握手验证版本/证书后，才持久写 applied 和报告。失败按 journal 回退；回退失败保留 journal 并停止推进。
- Master 不可达时，Node 使用本机已生效版本；Master ACK 不参与业务激活。清单过期限制首次应用，不清空已有配置；已生效证书仍受实际有效期约束。
- 新配置会改变缓存选择和回源设置，已有缓存对象按原有缓存策略过期；本版不执行缓存全量清理。站点内容缓存键、已有连接的排空与 TLS 会话恢复仍由业务配置管理。

默认上限为 4 MiB JSON/运行时快照、1000 站点/证书，shared dict 示例为 16 MiB 数据和 2 MiB 状态。最终可用容量同时受证书体积、Worker 数、索引大小、探测预算和系统内存限制；达到任一边界时整批拒绝。单个大 JSON 解码或证书解析仍是同步 CPU 操作，应以实际业务规模验收。

## 当前边界

- 本版保留磁盘历史供恢复，尚未自动回收发布目录。长期运行需独立文件系统/磁盘配额、容量监控和受控保留策略；清理不能删除 applied、journal、在途下载或未确认报告需要的元数据。内存代际、报告队列、重放收据及授权索引历史有界。
- 单 Master 没有跨机复制、发布仲裁或自动故障转移。节点数上限和吞吐能力须压测后确定，不能由少量联调结果推导。
- 模块测试中的 Worker/共享内存适配器与真实 OpenResty 联调分别记录。systemd 加固配置、非 root 服务账户、ARM64、真实网络分区和生产切换仍需目标环境验收。

原始 `lua_files/`、现有面板、CLI、Go/Rust 服务都没有被本目录自动修改。正式部署前，应先在独立端口和目录验证完整站点集合与回退，再执行受控接入。
