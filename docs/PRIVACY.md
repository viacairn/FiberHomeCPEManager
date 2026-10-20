# 隐私与脱敏

- 账号密码仅由用户输入；选择保存时进入系统钥匙串。Cookie、会话令牌和短信只在内存中。
- 测试夹具使用合成数据，设备图标不按开发者的实际网络预设。
- 开发阶段取得的真实测试地址、别名、SSID、短信、原始参考图和旧 WIP 补丁不进入项目；发布前删除原始记录与旧备份，并清理本地 Git 历史。
- `.gitignore` 仅在本地保留；本地排除规则写入 `.git/info/exclude`。

```sh
python3 script/check_privacy.py --history
python3 script/check_privacy.py --history --private-plan /仓库外/清单.json
git ls-files .gitignore
git fsck --full --no-reflogs --unreachable
```

后两条应无输出。扫描器检查当前文件、全部 Git 对象、非构建类忽略文件、二进制字符串，以及 PNG/ICNS 的压缩文本元数据。精确清单只在清理期间临时使用，位于仓库外，核查后删除；扫描输出仅显示位置和类别。

DMG 从隔离目录构建 arm64 Release，映射编译路径并剥离调试信息，签名后挂载检查包内实际文件。不复制用户目录、钥匙串、Cookie、短信、测试记录、原始截图或开发探针。

`Sources/FHCPECore/Resources/firmware-protocol.der` 是现有客户端协议所需的固件通用材料，不是用户登录密码或会话密钥。打包时只允许与源码中既有资源完全一致的内容。
