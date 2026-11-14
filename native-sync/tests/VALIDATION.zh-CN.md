# 原生 Sync 0.1.0 验证记录

本地验证日期：2026-11-13。环境：隔离 WSL2/Alpine x86_64、GCC 14.2.0、OpenSSL 3.5.9、来自固定 OpenResty 1.31.8.1 归档的源码。两种运行时分别使用独立测试前缀，未覆盖现有安装。

| 项目 | 结果 |
| --- | --- |
| 纯 C 边界检查，`-Wall -Wextra -Werror -pedantic` | 通过 |
| 纯 C 检查，UBSan trap 模式 | 通过 |
| 独立 nginx 1.31.8 + 动态模块 | 编译、加载与 50 项角色/身份/接口检查通过 |
| 完整 OpenResty 1.31.8.1 + 动态模块 | 编译、加载与 50 项角色/身份/接口检查通过 |

真实进程检查使用独立 Master 与 Node，各两个 Worker；证书和 token 在临时目录生成，结束时停止进程并清理。检查覆盖默认关闭、错误角色、重复身份、scope 边界、token 文件权限/符号链接、content handler 冲突、只读控制接口、mTLS 登记与冒用拒绝、路径/方法/body 限制，以及能力未实现时不返回假成功。

本地 Alpine 工具链未提供 ASan 运行库，因此本地未宣称 ASan 通过。GitHub Actions 在 Ubuntu 上配置 AddressSanitizer 与 UndefinedBehaviorSanitizer 的核心检查，以及 nginx/OpenResty 两种构建；远程结果以对应提交的 Actions 记录为准。

本记录不证明加密分发、Node 拉取、应用事务或业务健康检查已经迁移，也不证明生产容量、ARM64、HTTP/3 或所有目标 OpenResty 构建的 ABI 兼容。部署产物需按目标构建重新生成。
