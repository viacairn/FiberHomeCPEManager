# FHCPEM

独立 Swift 6 / SwiftUI macOS 菜单栏应用。macOS 14+，当前本机构建为 Apple Silicon。名称 FHCPEM，Bundle ID `local.fhcpem.app`。

**当前是可运行的读取版，尚未完成全量开发计划。** 已实现原生加密协议、登录、内存会话、Keychain 记住连接、概览和在线设备列表、5/15 秒刷新及离线旧数据提示。控制与短信界面明确标注适配中，没有模拟数据冒充真机。无线锁定互斥协调器已有单元测试，尚未接入未验证的写接口。

## 构建与运行

```sh
./script/build_and_run.sh
./script/test.sh
```

生成 `build/FHCPEM.app`，使用本地 ad-hoc 签名，不包含公证。只构建：`./script/build_and_run.sh --build-only`。本机 CLT 6.4 的 Testing 宏搜索路径存在问题，测试脚本显式加载已有插件；构建选择本机可用的 macOS 26.5 SDK。

可选真机只读测试（固定默认地址，无登录、无写操作）：

```sh
FHCPEM_PROBE=1 ./script/test.sh
```

在菜单栏打开连接窗口，输入地址、账号、密码。默认不记住凭据；勾选后只存 Keychain。页面数据、cookies 和短信不写入业务文件；URLSession 使用 ephemeral 配置。系统可能维护自己的诊断和容器元数据。

App Sandbox 仅启用出站网络，无文件访问权限。NSLocalNetworkUsageDescription 说明本地网络用途。为支持可变 HTTP 管理地址，ATS 允许 HTTP；应用内部仅向用户配置的 origin 发送请求并拒绝重定向，HTTPS 仍采用系统证书校验。此设备协议的共享常量不能替代 HTTPS 对不可信网络的防护。

详见 [协议证据](docs/protocol/RP0112.md)、[兼容表](docs/COMPATIBILITY.md)、[设计规格](docs/superpowers/specs/2026-10-17-fhcpem-design.md)。
