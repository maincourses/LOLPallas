# 本机原生组件

本目录保留运行/安装流程需要的版本锁定资料：

- `TenPallas.original.dll`：原腾讯 DLL，SHA-256 `97BA57FD47A393A3A4BBFA684D0F03D10CF04344FBD99CB2D2E8626675BE9C94`。
- `TenPallas.twenty.experimental.dll`：与本机已验证二十条版本一致，SHA-256 `3BCEFF093D67F86400DD0F3F1ECE50F812D531926D5FF64CF72C227904DA5D00`。
- `local-response20.json`：默认二十条短测试文案的响应。
- `validation.json`：原候选的离线测试记录，不能视为自动完成的真实游戏发送测试。

DLL 仅保留在本机，不进入 Git。安装工具检查哈希、原版签名、退出状态和备份，拒绝未知版本；不能手工复制到运行中的 WeGame。

可使用 `tools/native/PallasTwenty.py` 从正确原版 **离线副本** 重建候选。原版也有独立恢复备份：`%LOCALAPPDATA%\PallasCustomShout\TwentyMessageExperiment\TenPallas.before-twenty.dll`。示例仅生成新目录，不安装：

```powershell
python .\tools\native\PallasTwenty.py --scheme .\scheme20.example.json --source "$env:LOCALAPPDATA\PallasCustomShout\TwentyMessageExperiment\TenPallas.before-twenty.dll" --out-dir .\build\native-rebuild
```

Python 构建器还会核验已安装的本地文件加载器，输出目录必须不存在。构建后需核对候选固定哈希；不得对其他版本强行应用，也不得绕过正常加载时的签名/完整性拒绝。
