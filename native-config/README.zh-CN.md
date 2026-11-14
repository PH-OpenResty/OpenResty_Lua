# 原生站点配置监听与内存热更新

`ngx_http_scdn_config_module.so` 读取独立的站点数据文件，定期检查配置和引用的证书内容，验证完整候选版本。每个 Worker 在专用线程池中读取、解析和预加载，全部 Worker 准备好相同摘要后切换活动版本。更新不发送 HUP，不重建 Worker，也不生成 Nginx 配置或 Lua 字节码。

文件 I/O 和证书解析运行在后台线程；请求路径只读取已准备的内存版本。默认每 250ms 检查一次、连续稳定 500ms 后才允许提交。检测与应用延迟取决于磁盘、证书数量和最慢 Worker，这不是硬实时保证。实现使用有界内容轮询，可识别 atomic rename、同路径替换及删除后重建，而不依赖单一 inode 的文件通知。

## 接入

Nginx 需要 `--with-threads` 与 HTTP SSL 支持。先加载配置模块，再加载消费配置的业务模块；两者使用匹配的头文件和构建版本。

```nginx
load_module modules/ngx_http_scdn_config_module.so;
thread_pool scdn_config_reader threads=1 max_queue=2;
http {
    scdn_config_zone configurations 128k;
    scdn_config_watch /etc/scdn/sites.conf;
    scdn_config_interval 250ms;
    scdn_config_settle 500ms;
    scdn_config_allow_empty off;
    # Business servers and local observation endpoints follow.
}
```

源文件必须是绝对路径的普通文件，源文件与引用路径中的符号链接均被拒绝。使用受限目录和文件权限；站点数据由受信任管理员或发布者维护，模块不提供文件写入接口。发布时将完整文件写至临时文件，然后原子替换目标路径。可直接修改文件，但完整快照的原子替换能避免观察到编辑过程中的有效中间版本。

启动时校验失败会使 `nginx -t` 或启动失败；运行中的半写文件、语法错误、重复 Host、非法字段、缺失文件、无效证书或空集合都会保留当前版本并输出受控错误码。允许删除最后一个站点时，显式启用 `scdn_config_allow_empty on` 并发布 `sites { }`。

## 站点数据格式

这是独立的受限数据语法，外形类似 Nginx 配置；不执行 Lua、shell、`include`、变量或任意 Nginx 指令。

```nginx
sites {
    site demo {
        host www.example.com;
        host alias.example.com;
        enabled on;
        upstream http://127.0.0.1:8080;
        cache auto;
        tier 3 5000;
        certificate /etc/scdn/certificates/demo.crt;
        certificate_key /etc/scdn/certificates/demo.key;
        prefix /api/ {
            upstream http://127.0.0.1:9000;
            cache off;
        }
    }
    site assets {
        host assets.example.com;
        root /srv/sites/assets;
        cache off;
    }
}
```

`host` 是精确域名，可以重复列出别名；`enabled` 默认为 on，`cache` 默认为 off，可选 l1/l2/off/auto。`tier HITS WINDOW_MS` 定义按站点、Host、URI 隔离的有界固定窗口热度策略；使用 auto 时必须配置 tier。`prefix` 选择最长匹配前缀的回源和缓存策略；静态 root 由 Nginx 原生模块提供内容服务。

回源格式为 `http://host:port`；使用域名需要在 Nginx 中配置 resolver。当前不支持 HTTPS/IPv6 回源或泛域名 Host。配置模型限制会明确拒绝不支持的字段。WAF、限速不属于数据语法或原生模块；用户可以独立配置外部模块或 Nginx 原有功能。

单个快照最多 4MiB、256 个站点，每站点 32 个 Host、32 个前缀；配置及去重前的证书读取总量最多 8MiB，证书链最多 256KiB、私钥最多 64KiB。每实例最多 128 个 Worker。达到边界时拒绝整个候选版本。

启用站点的证书文件按内容纳入摘要；同路径证书/私钥替换会触发更新，配对及 SAN 校验通过后才提交。未变化的证书对象通过安全引用复用，避免每轮重新解析。停用站点不要求旧证书和静态目录继续可用。证书过期检查在预加载和握手时执行。本文不声称这等同于完整公开 CA 信任链或 OCSP 验证。

## 版本与观察

每请求持有自己的版本引用；活动版本切换后，已有请求继续完成旧版本，后续请求采用新版本。旧版本在所有相关请求释放后回收。共享区只放摘要与 Worker 就绪信息，普通 C/OpenSSL 指针留在各自进程。

在本机 Unix Socket 或 loopback listener 中配置 `scdn_config_status;`，可查询版本、代际、站点数量、Worker PID 和最近错误。状态不返回配置正文、证书或私钥。该端点只读，运行时检查真实传输来源；建议使用受限 Unix Socket 并关闭访问日志。

线程阻塞或某 Worker 未准备好时不提交候选版本。Worker 崩溃后会从启动快照和当前磁盘内容重建；重建到活动版本前拒绝业务请求，不使用半成品。当前没有跨主机同步，也没有将新版本另行落盘保存，启动/恢复仍要求发布者保留有效的源文件与证书。

## 可以热更新的范围

Host、别名、启停、回源、URI 前缀、静态 root、缓存选择、热度参数以及站点 TLS 证书可通过该文件更新。`nginx.conf` 的监听端口、协议、模块加载、共享区大小、proxy_cache_path 和其他核心指令仍是启动配置。原生模块不能把任意 Nginx 指令转成无重载动态配置。

本模块和 Master/Node 身份模块可以共存，但身份区分不代表端到端远程同步已经迁移。后续 Sync 应向同一配置应用层提交经过验证的输入，避免两个写入者同时管理同一数据源。
