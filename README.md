# FiberHomeCPEManager

FiberHome LG6851F 5G CPE 的原生 macOS 菜单栏控制台与桌面磁贴。Swift 6 / SwiftUI，macOS 14+，显示名 / 产品名 / `.app` 均已更名；Bundle ID 保留 `local.fhcpem.app` 以沿用本地网络授权、钥匙串与磁贴数据。

全页面统一 350×590，数据多时向下滚动；菜单栏宽度恒定不随速率变化。

| 概览（浅色） | 概览（深色） |
| --- | --- |
| ![概览浅色](render/live/v2-overview.png) | ![概览深色](render/dark/01-overview-light.png) |

| 在线设备 | 设备控制 | 首次连接 |
| --- | --- | --- |
| ![设备](render/live/v2-devices.png) | ![控制](render/live/v2-controls.png) | ![连接](render/live/v2-connect.png) |

| 蜂窝详情 | 基站与小区 |
| --- | --- |
| ![蜂窝](render/live/v2-cellular.png) | ![小区](render/smoke/11-cellular-cells.png) |

## 构建与运行

```sh
./script/build_and_run.sh            # 构建、打包、ad-hoc 签名并启动
./script/build_and_run.sh --build-only
./script/test.sh                     # 单元 / 端到端测试
./script/ui_matrix.sh                # 43 项 UI 交互检查（可带 CPE_PASS 验证登录后页面）
```

产物为 `build/FiberHomeCPEManager.app`，内含 `Contents/PlugIns/FiberHomeCPEManagerWidget.appex`（桌面磁贴）。使用本地 ad-hoc 签名，不含公证。

首次启动访问 `192.168.8.1` 时 macOS 会询问「本地网络」权限，请选择允许；若误点拒绝，登录会显示 `The Internet connection appears to be offline`，需到 系统设置 → 隐私与安全性 → 本地网络 重新打开。

依赖说明：本机 Swift 6.4 与 `MacOSX26.5.sdk` 匹配，构建脚本会固定该 SDK 并把 SwiftPM 缓存放在 `.build/`（用户级缓存目录在当前开发沙箱内不可写）。

## 功能

| 页面 | 内容 |
| --- | --- |
| 概览 | 大号中国联通、以太网/蜂窝 IP、右上角 `5G`/`SA`/`N78`、右下角已注册/以太网已连接状态、实时速率与流量、九项蜂窝摘要 |
| 设备 | 单个不分组列表、四个常驻筛选、真实在线数；右键设置图标或固定 IP（DHCP 保留），写后读回 |
| 控制 | Wi-Fi 广播开关/改名、定时重启、机身指示灯、风扇模式均写入后重读；上行切换需二次确认并自动重连 |
| 短信 | 会话列表 / 正文 / 内联回复 / 撰写；不显示流量/积分胶囊；停留短信页时每 5 秒调用 `get_sms_data`，不落盘 |
| 蜂窝详情 | 350 pt 页面内两分段滚动：技术指标、邻区与候选小区；锁小区/锁频段互斥，支持空 PCI |
| 连接 | FiberHome CPE Manager；设备 IP（只填 IP）、账号、密码与「保存密码」同一行；全角密码/首尾空格在发送前拦截 |

菜单栏有两种模式：**仅信号强度**（四根柱）与 **信号强度 + 网速**（柱 + `128 Kbps` / `12.8 Mbps` / `1.28 Gbps`，最多三位有效数字）。

**交互**

| 操作 | 行为 |
| --- | --- |
| 左键单击图标 | 打开 / 关闭面板 |
| 右键（或 Control+左键） | 状态摘要、重新登录、显示网速、清除已保存的密码、关于、退出应用 |
| 点击面板外 | 关闭面板（应用失活即关闭） |
| `Esc` / `⌘W` | 关闭面板（不退出应用） |
| `⌘Q` / 右键菜单退出 | 退出应用 |

菜单栏图标两档宽度实测 **30.5 / 92.5 pt**（仅信号 / 含网速），与读数无关；圆角与几何规范见 [docs/design/macos27-DESIGN-SPEC.md](docs/design/macos27-DESIGN-SPEC.md)。

面板内容四边统一 **16 pt**：顶部、左右、画布与底栏间距、底栏距面板底都是 16 pt；底部导航高 52 pt，完全胶囊圆角；面板与底栏均使用与原生右键菜单一致的 `.menu` 材质。

**宽度恒定**：整段绘制为固定尺寸 template 图像，实测在任何读数下都保持 92.5 pt（含网速档），不会推动相邻菜单栏项目。

## 凭据保存策略

设备认证方式：明文 HTTP 局域网控制台 + `DO_WEB_LOGIN` 换取会话令牌，没有可持久化的长期 API Key。

结论：**只把账号密码存入系统登录钥匙串，默认不保存**。

- `kSecClassGenericPassword`，服务名 `local.fhcpem.app.credentials`，`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`，不随 iCloud 同步。
- 不使用 Data Protection Keychain（`kSecUseDataProtectionKeychain`）：它需要 `keychain-access-groups` 权限，而本项目 ad-hoc 签名无法获得该权限（实测返回 `-34018`）；登录钥匙串实测可读写。
- 密码不写入任何文件、UserDefaults 或日志；会话 Cookie 与令牌只在内存 URLSession 中。
- 连接页对 HTTP 地址显示明文传输提示：设备端的共享常量加密不能替代 TLS。

## 桌面磁贴

小 / 中 / 大三种尺寸，读取 App Group `group.local.fhcpem.app` 中的 `widget-snapshot.json`：

- 仅含网络制式、信号档、上下行速率、流量、在线设备数与时间戳。
- **不含账号、会话、短信、设备名或 IP**；扩展进程不登录设备、不读钥匙串。
- 数据过期后显示「数据可能已过期」，不伪装成实时值。

## 协议与证据

- [真机只读验证记录](docs/protocol/LIVE-VERIFIED-2026-10-17.md)：字段语义、70+ 条实测结论与反例（如 `SIMStatus=0` 但网络可用）。
- [兼容表](docs/COMPATIBILITY.md)：逐字段验证状态，明确标注「观测惯例」与「未解决」。
- [实现状态](docs/IMPLEMENTATION-STATUS.md)：已实现范围与明确未启用项。
- [会话互斥实测](docs/protocol/SESSION-CONTENTION.md)：WebUI 与客户端互相挤占、错误分层与显式重新登录。
- [协议基线](docs/protocol/RP0112.md)：FHAPIS 传输、加密协商与测试向量。
- [高级控制契约](docs/protocol/ADVANCED-CONTROLS-2026-10-18.md)：风扇、移动网络、DDNS、端口映射的节点与真机回环。

真机关键反例（这些直接改变了实现）：

- `WorkMode=SA` 是组网模式，不是制式；制式由 `NR_Band` 是否存在判定。
- `SIMStatus` / `RegisterStatus` 为 `0` 时网络仍正常，上行可用性改用 `WANIPConnection.1.ConnectionStatus`。
- `EARFCN_NBR` 等多值字段返回 `634464,634464,...`，需取首值。
- 温度是千分之一度（`31708` → `31.7 ℃`）。
- LTE 未接入时 `BAND` 为空，残留的 LTE PCI/RSRP 必须忽略。
- 短信 `From` / `ReceivedTime` 在真机为空；实际用 `get_sms_data` 的 `session_phone` / `time` / `msg_content`，发送走 `send_msg`。

## 设计说明

- [v7 说明](docs/design/ui-v7-NOTES.md)：尺寸策略、设计令牌、为何不用第三方 UI 框架。
- [v6 设计稿](docs/design/ui-v6/README.md)：视觉基准。

## 开发辅助

- `Sources/UIRender`：离屏渲染各页面为 PNG（含深色），用于无录屏权限时的布局校验，不进入 App 包。
- `script/cdp.py`：DevTools Protocol 客户端，用于在用户手动登录的专用 Chrome 实例中做只读字段核对；不接触登录表单与密码。

```sh
swift run UIRender ./render/smoke
swift run UIRender ./render/dark --dark
python3 script/cdp.py eval "<read-only expression>"
```

## 已知限制

- 接入类型按真机观测的 `WLANConfiguration` 索引惯例映射（5→5G，1→2.4G）；`OperatingFrequencyBand` 在真机返回空，未知索引显示「未知接入」。
- 短信正文读取与发送、风扇模式已适配；锁定与固定 IP 的原厂写通道已同值写入并读回确认。锁定启停/互斥、候选增删与 DHCP 冲突另有本地契约测试；主动扫描、立即重启未开放。
- 磁贴在 ad-hoc 签名下能否出现在系统图库取决于 PlugInKit；未宣称已验证，必要时需 Developer ID 签名。
- 仅适配 LG6851F / RP0112；RP0106–RP0111 与其他型号未验证。
