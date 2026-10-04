# 可分发 v3 实验包

目标是让接收者无需开发环境即可安装同一版已核验组件，不是把任意版本的 WeGame 变成通用接口。本机已安装的 v2 不由构建或测试流程替换。

## 与 v2 的变化

- 使用组件已有的 Shell32 `SHGetFolderPathW(CSIDL_LOCAL_APPDATA)` 导入读取当前进程用户的本地目录，不再编译 `C:\Users\zly`；追加 `LOLPallasPortable\hotkeys.bin`。遵守返回码和 MAX_PATH 边界。API 行为依据 [Microsoft 文档](https://learn.microsoft.com/en-us/windows/win32/api/shlobj_core/nf-shlobj_core-shgetfolderpathw)。
- 源 JSON 仍是 version 2，二进制库改为 `LPSKEY3\0`、长度、条数、FNV-1a(records)、记录，头为 20 字节。此校验用于损坏检测，不是密码学认证。
- 方案接收回调不从云端文字取本地记录；若接收回调尚未运行，首个真实键盘回调尝试加载一次。不创建全局钩子、定时器、输入模拟或自动发送。
- 安装只修改 `TenPallas.dll`，不修改 `pallas.exe`，也不写旧版 `PallasCustomShout` 目录。原版启动器产生原回调的路径尚待游戏验证；离线桩无法验证整个 WeGame 初始化链。
- 新的安装器按注册表、常见目录和用户选择解析路径，不遍历全盘。版本绑定仍通过固定 DLL／启动器 SHA256，原组件要求签名 Valid；同一用户内部一致的 v2 安装允许升级，保存其现有 DLL 和启动器。
- 应用时把可恢复的 `applied-messages.json` 和运行二进制写入 AppData。搬移／重新解压后可以在首次打开编辑器时恢复已应用文案；已有项目 `messages.json` 永不自动覆盖。
- 正常同用户 UAC 提权，SID 变化即拒绝；事务互斥、文件校验、重解析路径拒绝、原组件备份、替换前比较、回读与异常回退。还原保留文案，成功还原后重装沿用已有库。
- ZIP 白名单仅含自有脚本、公共模板、说明和重建差异；不含完整腾讯 DLL／EXE、个人 messages.json、源备份、账号数据、编译器或 Python。

v2 默认编译和库格式保持原样：加入条件编译后的 v2 构建仍逐字节复现 `4AE8AB...D3EE143`。可分发 v3 候选为 `6B8CCD...92F5AE3`；其 Authenticode 摘要失效，安装前明确接受实验风险，拒绝绕过完整性或反作弊限制。

## 构建和验证

```powershell
D:\anaconda\python.exe tools/native/PallasPortable.py --out-dir build/NEW-portable
D:\anaconda\python.exe tests/Test-Hotkeys-Native.py --build build/NEW-portable --portable
powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-Portable.ps1 -BuildDirectory build/NEW-portable
powershell -NoProfile -STA -ExecutionPolicy Bypass -File Edit-Hotkeys-GUI.ps1 -Portable -SelfTest
powershell -NoProfile -ExecutionPolicy Bypass -File tools/Build-Portable-Package.ps1 -BuildDirectory build/NEW-portable
```

构建只能使用新的 build 子目录，拒绝覆盖已有候选。开发构建依赖本机核验的原 DLL 和 v2 候选，均不进入 Git；普通使用不依赖这些文件。可分发包中的差异由安装器校验固定差异摘要、源摘要、编辑边界及重建目标摘要。

已执行隔离原生指令测试、生成文件读取、跨语言序列化、中文路径／自定义安装位置、检测歧义、签名不符、运行进程保护、安装／应用／还原／重装、损坏差异、并发修改和失败回退测试，以及既有 v2／旧版回归。测试不加载腾讯 DLL，不操作游戏进程，也不发真实游戏消息。

**2026-10-04 用户确认 64 KiB v2 尚未进行游戏内测试。v3 更未实机安装／发送。** 交付必须标为测试包，不能把离线检查或文件回读当成兼容实证。新电脑先训练模式小范围验证；若安全／完整性拒绝、闪退或异常，停止并还原，不强行绕过。
