# 测试流程

两条命令，一次跑完，不重复、不靠人工数结果。

```bash
./script/test.sh                      # 单元测试（秒级）
CPE_PASS='…' ./script/ui_matrix.sh    # 完整 UI 矩阵（单次，约 90 秒）
```

可选环境变量：

| 变量 | 默认 | 用途 |
| --- | --- | --- |
| `CPE_PASS` | 空 | 真机密码。不提供则跳过登录与已连接页检查 |
| `CPE_HOST` | `192.168.8.1` | 设备地址。用于多设备或离线演练 |

## 1. 单元测试

`script/test.sh` 跑 `swift test`，共 **143 项**，覆盖协议解析、菜单栏几何、图标双别名、短信发送合并、密码全角拦截、5 秒同步策略、设置写入、断线清空、会话失效、固定 IP 校验、锁小区/锁频段互斥与回读等纯逻辑。**不碰 UI，不碰设备**，所以永远先跑它。

## 2. UI 矩阵

`script/ui_matrix.sh` 是**一次运行、一次汇总**：脚本自己构建探针、按阶段启动应用、逐场景运行，最后打印总数与失败列表，退出码即结果（旧版即使有 FAIL 也返回 0）。

### 阶段与顺序

| 阶段 | 场景 | 为什么在这个位置 |
| --- | --- | --- |
| 1 · 登录页 | `login-empty`、`login-extra`、`login-fullwidth`、`esc`、`cmdw`、`external-click`、`about` | 不需要会话，必须在登录前跑 |
| 可达性 | `curl http://$CPE_HOST/` | 设备不在本机网段时，登录必然失败；先判定再决定是否跑已连接页 |
| 2 · 登录 | 真实登录一次 | 只登一次，后续全部复用同一会话 |
| 3 · 已连接 | `contextmenu`、`styles`、`keys`、`devices-filter-select`、`a11y`、`controls`、`sms`、`sms-poll`、`relogin` | 需要在线数据 |
| 4 · 退出 | `power`、`cmdq` | 会终止进程，因此各自新开实例，必须最后跑 |

### 覆盖对照

| 规范条目 | 场景 | 断言 |
| --- | --- | --- |
| §2 空密码拦截 | `login-empty` | 按钮存在、提示出现 |
| §2 保存密码 / 导入网关 | `login-extra` | 勾选项存在、清空 IP 后能回填 |
| §2 全角密码拦截 | `login-fullwidth` | 全角逗号提示出现、改为半角后提示消失 |
| §1 菜单栏两种宽度 | `styles` | 勾选后变宽（30.5 → 92.5 pt）、取消后还原 |
| §8.2 右键菜单 | `contextmenu` | 退出项、显示网速项、重新登录；不含打开面板/立即刷新 |
| §8.2 重新登录 | `relogin` | 菜单「重新登录」回到连接页并自动使用已保存凭据 |
| 关于页 | `about` | 登录页与在线状态均可打开，Esc/返回回到来源页 |
| §8.2 点击外部关闭 | `external-click` | 面板消失 |
| §8.2 Esc / ⌘W | `esc`、`cmdw` | 关闭面板、不退出应用；二级页 Esc 返回 |
| §8.2 ⌘1–⌘4 | `keys` | 四个页签分别落到正确页面 |
| §3–§7 页面渲染 | `keys` 的落点断言 | 概览「蜂窝信息」、设备「全部」、控制「上行运行模式」、短信「写短信」 |
| §5 设备筛选 | `devices-filter-select` | 胶囊弹出四个选项，切到 5G 后列表与计数同步 |
| §6 控制页 | `controls` | 模式矩阵、主 SSID、备用通道折叠/展开、重启手风琴 |
| §7 短信 | `sms` | 列表/详情均无流量·积分胶囊、无快捷芯片、内联回复框存在 |
| §7 短信 5 秒同步 | `sms-poll` | 进入短信页后 7 秒内同步时间戳发生更新 |
| §8.4 无障碍 | `a11y` | 六个页面（四页签 + 蜂窝详情 + 会话）内所有按钮/开关/单选必须有名称；滚动条系统控件除外 |
| §8.2 退出 | `power`、`cmdq` | 右键菜单退出、⌘Q 均能结束进程 |

`a11y` 还带两个防假通过条件：应用未运行直接 FAIL；扫到的页面少于 6 个也 FAIL。

`tabs` 场景已删除：它的四个页面落点断言与 `keys` 完全重复，只是多花 5 秒。

### 断线与会话失效

不需要设备，单元测试即可覆盖主要契约：

| 测试套件 | 覆盖 |
| --- | --- |
| `PageDataTests` | 断线后 `snapshot` / `devices` 不透过 `isLive` 暴露；晚到数据不能回填 |
| `ShellSessionTests` | 认证失效 → 清空会话、回到登录页、保留可重登状态 |
| `EndToEndTests` | 被挤占后受保护读返回 `CPEError.authentication` |
| `RadioLockTests` / `DHCPReservationTests` | 写入前校验、互斥、失败不重试、回读不一致判 `uncertain` |
| `SafetyTests` | 登录页 HTML/418 识别；短信正文含 `<html>` 不被误判 |

离屏渲染 `UIRender` 的 `16-offline-devices`、`17-offline-sms`、`18-offline-cellular` 用 fixture 固定断线态，不依赖真机。

### 设备不可达时

```
device
  unreachable  http://192.168.8.1/  (不在本机网段，跳过已连接检查)
login
  SKIP  设备不可达，跳过登录与已连接页检查
summary
  15 passed, 0 failed, 1 skipped  (40s)
```

这是**跳过**而不是失败：应用本身没有问题，只是这台 Mac 不在设备网段。演练可用 `CPE_HOST=192.0.2.1`（TEST-NET-1）。

### 真机专项探针

这些场景需要 `CPE_PASS`，但不放进默认矩阵（有的会写设备或发短信）：

```bash
.build/ui_probe devices-filter-select   # 胶囊筛选 5G → 3/8 台 → 还原
.build/ui_probe controls-stable         # 四个开关采样 3 秒，值/可用性不变
.build/ui_probe controls-toggle         # 关/开指示灯，验证写入与还原
.build/ui_probe sms-send                # 给 10010 发「流量查询」，验证状态与已发送气泡
.build/ui_probe sms-poll                # 停留短信页 7 秒，确认同步时间戳更新
.build/debug/FiberHomeCPEManagerProbe --session-audit   # 两个原生入口：验证客户端会话可并存（会挤掉浏览器会话）
```

2026-10-18 实测：`controls-stable` 4 个开关 3 秒无变化；`controls-toggle` 写入 1→0→1；`sms-send` 状态「已回复 10010」，会话出现「已发送，流量查询」，设备 `get_sms_data` 回读 29 条；`sms-poll` 的「同步 HH:mm:ss」在 7 秒内更新。

## 3. 设计约束

* **等待用轮询，不用固定 sleep**。`waitFor(条件, 超时)` 每 40 ms 检查一次，条件满足立即继续；界面快时省时间，慢时也不误判。
* **登录用全新实例**。场景会反复开关面板，AppKit 的 key window 状态会被打乱，键入可能落到别处；登录前重开一次最稳。
* **密码用粘贴，不逐字键入**。应用主菜单补了「编辑」菜单后，登录探针把密码写入剪贴板并按 ⌘V；逐字合成 Unicode 时，一个残留的 Command 状态会把密码首字母 Q 变成 ⌘Q（退出）。
* **启动失败要重试**。应用是沙盒应用，在沙盒 shell 里 `open` 偶尔会在 `libsecinit` 阶段 SIGTRAP（业务代码还没执行）；`relaunch` 最多重试 5 次。
* **每场景打印耗时**，便于发现回归（例如某次 `styles` 从 2 秒变成 6 秒）。
* **密码只键入应用自己的密码框**，不落盘、不打印。

## 4. 常见失败怎么读

| 输出 | 含义 |
| --- | --- |
| `设备不可达` + 大量 SKIP | 网络问题，先确认 Mac 在 CPE 网段 |
| `The Internet connection appears to be offline` | macOS 本地网络权限被拒；在系统设置 → 隐私与安全性 → 本地网络允许 FiberHomeCPEManager |
| `FAIL UI 登录` 且 `page texts` 含 `用户名或密码错误` | 固件拒绝了凭据；连续错误会触发 1 分钟锁定 |
| `FAIL …tab…` 成片出现 | 通常是应用没登录（看 `UI 登录` 一行） |
| 单个场景偶发失败 | 重跑该场景：`.build/ui_probe <scenario>` |
