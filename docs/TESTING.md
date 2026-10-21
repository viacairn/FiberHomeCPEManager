# 测试

## 本地回归

```sh
./script/test.sh
FHCPE_KEYCHAIN_SMOKE=1 ./script/test.sh
python3 -m unittest discover -s script -p 'test_*.py'
```

默认测试使用合成数据和本地模拟 CPE，不连接真实设备。钥匙串专项使用随机测试服务名，完成后删除，不读取用户保存的连接。

覆盖范围包括协议编解码、认证与续期、断线清理、设置写后读回、锁定互斥、DHCP 校验、设备图标身份、短信合并与已读状态、密码输入、提醒及发布排除规则。

## 界面与性能

```sh
swift run UIRender render/light
swift run UIRender render/dark --dark
swift run UIRender --chrome-audit
swift run UIRender --controls-performance-audit
```

渲染器使用真实视图和模拟数据，检查边界、布局和截图。性能审计区分首次控制页布局与重复切换，截图绘制时间单独记录，不能把截图开销当作交互延迟。

`script/ui_matrix.sh` 是可选的真实鼠标验证，需要运行器的 macOS 辅助功能权限。授权不足会返回退出码 2，不能计作通过。只在明确选用连接参数时才进入真机路径。

文档图片从模拟渲染结果中选取，只提交 PNG；不要提交 `layout.json`、调试日志或真实桌面截图。

## 真机验证

探针通过 `CPE_HOST`、`CPE_USER`、`CPE_PASS` 环境变量获取临时连接参数，不能将真实密码写进源码或命令历史。`--keepalive-audit 360` 至少持续 6 分钟，只输出耗时与采样次数，不自动重新登录。

写入类专项必须明确选择，并在结束后读回或恢复。普通单元测试和截图生成不执行设备写入。

## 发布检查

```sh
python3 script/check_privacy.py --history
./script/build_dmg.sh
```

打包流程检查公开文件与 Git 历史、构建 arm64 Release、校验签名与架构，最后挂载 DMG 检查实际内容与 Applications 链接，并生成 SHA256SUMS。
