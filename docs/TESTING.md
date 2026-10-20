# 测试流程

```sh
./script/test.sh
FHCPE_KEYCHAIN_SMOKE=1 ./script/test.sh
python3 -m unittest discover -s script -p 'test_*.py'
python3 script/check_privacy.py --history
```

默认测试使用模拟 CPE，不访问真实设备。钥匙串专项使用随机测试服务名与测试密码，完成后删除，不读取用户凭据。

## 界面

`UIRender` 使用合成数据检查页面、号码局部滚动、原生弹窗尺寸、背景扩展及明暗外观。生成图片保留在本地 `render/`。

```sh
swift run UIRender render/light
swift run UIRender render/dark --dark
swift run UIRender --chrome-audit --header-audit --header-scroll-audit
./script/ui_matrix.sh
```

真实鼠标矩阵需要辅助功能授权；未授权返回 `BLOCKED / 2`，不计为通过。默认矩阵不执行真实短信发送和设备写入。

## 设备验证

真机探针通过环境变量 `CPE_HOST`、`CPE_USER`、`CPE_PASS` 接收参数。测试密码不要写入命令历史或文件。只读检查使用 `FiberHomeCPEManagerProbe --network-audit`；风扇、DHCP 等写入专项须明确选用对应探针，结束后恢复状态。

无操作续期使用 `FiberHomeCPEManagerProbe --keepalive-audit 360`：每 3 秒执行生产环境的受保护采样，每 30 秒检查心跳并续期。至少运行 6 分钟，期间不要在其他入口重新登录；只记录耗时与采样次数，不打印设备信息，也不自动重新登录。

## DMG

```sh
./script/build_dmg.sh
```

脚本执行源码和 Git 对象脱敏检查，构建 arm64 Release，验证签名，再挂载 DMG 检查实际包内文件、架构和二进制字符串。可传入仓库外的 `--private-plan` 做精确测试信息检查。
