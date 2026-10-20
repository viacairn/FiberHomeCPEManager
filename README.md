# FiberHome CPE Manager

烽火 CPE 的原生 macOS 菜单栏管理工具，支持 Apple Silicon，macOS 14+。Swift / SwiftUI；当前版本 1.0-Beta。

## 功能

- 概览：动态信号、运营商、蜂窝参数、实时网速和流量；断线清空 API 数据。
- 设备：搜索、接入类型筛选、通用设备图标与手动选择、静态 IP 绑定。
- 控制：移动网络、上网模式、DDNS、端口映射、Wi-Fi、定时重启、风扇、指示灯、外置天线、小区与频段互斥锁定。
- 短信：会话、发送、自动刷新与当前会话已读；内容仅在内存中。
- 菜单栏：信号强度、网速、重新登录、关于与退出应用；包含桌面磁贴。
- 连接：每 3 秒刷新数据、每 30 秒续期当前登录；关闭弹窗后继续执行。

## 构建

需要匹配的 Swift 6 工具链和 macOS SDK。当前开发环境使用 Swift 6.4 / MacOSX26.5.sdk，脚本在该 SDK 存在时优先使用。

```sh
python3 script/package_release.py --configure-only
./script/build_and_run.sh
./script/build_and_run.sh --build-only
```

应用位于 `build/FiberHomeCPEManager.app`。首次使用时输入设备管理地址、账号和密码；默认网关为 `192.168.8.1`。保存密码为可选功能，使用系统钥匙串。

## DMG

```sh
./script/build_dmg.sh
```

生成 Apple Silicon Release 安装包 `build/release/FiberHomeCPEManager-1.0-Beta.dmg`，附 `SHA256SUMS`。打开 DMG 后将应用拖入 Applications。

打包前检查源码和 Git 历史；应用从隔离目录构建，剥离调试符号，校验主程序与磁贴，并挂载检查 DMG 内容。可使用 `--private-plan /仓库外/清单.json` 增加本地精确脱敏检查。

## 开发与协议

- [测试流程](docs/TESTING.md)
- [隐私说明](docs/PRIVACY.md)
- [UI 规格](docs/UI-SPEC.md)
- [兼容性](docs/COMPATIBILITY.md)
- [Web API](docs/protocol/WEB-API.md)
- [会话互斥](docs/protocol/SESSIONS.md)
- [高级控制](docs/protocol/ADVANCED-CONTROLS.md)

`.gitignore` 不进入提交；本地排除规则保存在 `.git/info/exclude`，构建和打包产物不进入源码仓库。设备数据、截图与凭据不随项目分发。

## 许可证

[Apache License 2.0](LICENSE)，版权信息见 [NOTICE](NOTICE)。应用资源中同时包含许可证和 NOTICE。
