# 可分发 v3 实验包

目标是让接收者无需开发环境即可安装同一版已核验组件，不是把任意版本的 WeGame 变成通用接口。构建或离线测试不替换真实安装。

## 与 v2 的变化

- 使用组件已有的 Shell32 `SHGetFolderPathW(CSIDL_LOCAL_APPDATA)` 导入读取当前进程用户的本地目录，不再编译 `C:\Users\zly`；追加 `LOLPallasPortable\hotkeys.bin`。遵守返回码和 MAX_PATH 边界。API 行为依据 [Microsoft 文档](https://learn.microsoft.com/en-us/windows/win32/api/shlobj_core/nf-shlobj_core-shgetfolderpathw)。
- 源 JSON 仍是 version 2，二进制库改为 `LPSKEY3\0`、长度、条数、FNV-1a(records)、记录，头为 20 字节。此校验用于损坏检测，不是密码学认证。
- 方案接收回调不从云端文字取本地记录；若接收回调尚未运行，新按下的真实键盘事件允许加载本地库。连续失败最多三次，成功后重置预算；显式方案接收可再次加载。不创建全局钩子、定时器、输入模拟或自动发送。
- 安装只修改 `TenPallas.dll`，不修改 `pallas.exe`，也不写旧版 `PallasCustomShout` 目录。原版启动器产生原回调的路径尚待游戏验证；离线桩无法验证整个 WeGame 初始化链。
- 新的安装器按注册表、常见目录和用户选择解析路径，不遍历全盘。版本绑定仍通过固定 DLL／启动器 SHA256，原组件要求签名 Valid；同一用户内部一致的 v2 安装允许升级，保存其现有 DLL 和启动器。
- 应用时把可恢复的 `applied-messages.json` 和运行二进制写入 AppData。搬移／重新解压后可以在首次打开编辑器时恢复已应用文案；已有项目 `messages.json` 永不自动覆盖。
- 正常同用户 UAC 提权，SID 变化即拒绝；事务互斥、文件校验、重解析路径拒绝、原组件备份、替换前比较、回读与异常回退。还原保留文案，成功还原后重装沿用已有库。
- ZIP 白名单仅含自有脚本、公共模板、说明和重建差异；不含完整腾讯 DLL／EXE、个人 messages.json、源备份、账号数据、编译器或 Python。

v2 默认编译和库格式保持原样：加入条件编译后的 v2 构建仍逐字节复现 `4AE8AB...D3EE143`。旧 v3 `6B8CCD...92F5AE3` 已停止交付；修复候选为 `52776E...0CC0AD`。组件 Authenticode 摘要失效，安装前明确接受实验风险，拒绝绕过完整性或反作弊限制。

## 输入与加载修复

- 保留原 IAT 导入地址表目录，追加槽位位于单独可写区；不扩大 IAT 覆盖范围到代码，不把整段代码设为可写。
- Ctrl／Alt／Shift／~ 使用真实键盘 down／up 事件跟踪，支持左右修饰键和系统按键事件。异步键状态仅用于额外禁止 Win 组合，不再决定上述修饰键是否匹配。
- 更新原控制器的面板保持标记，按已有设置使用 ~ 或 Ctrl 面板键。原生十槽预览按本地库的 ~+数字绑定填入，不代表所有独立键位或条目顺序；完整文案仍在本地编辑器管理。
- 焦点切换后禁止重复事件重放，主键松开才可再次发送；本地重载不清除已按住的状态。
- 旧 v3 升级仅替换已核验组件和安装记录，保留运行库、已应用源文案、键位及最初还原基线；升级额外备份旧 v3 和状态，失败按已知摘要回退。

## 构建和验证

2026-10-05 新增 `stock-reinstall-r1`：同用户、路径、签名、哈希和备份都核验成功的 `original-components-restored` 记录，可从原版重新安装。历史候选二十键哈希仅在这个恢复状态下接纳，活跃的未知组件或部分恢复不接纳。新备份目录保存原版 DLL、旧安装记录及当前运行文案；还原基线切为原版，旧基线和全部备份仍保留。安装不写 `pallas.exe` 或编辑草稿，运行文案沿用原已应用库，草稿另行应用。额外隔离测试见 `tests/Test-Stock-Reinstall.ps1`。此修复未改变候选 DLL 的字节，不验证游戏发送。

```powershell
D:\anaconda\python.exe tools/native/PallasPortable.py --out-dir build/NEW-portable
D:\anaconda\python.exe tests/Test-Hotkeys-Native.py --build build/NEW-portable --portable
D:\anaconda\python.exe tests/Test-Import-Loader.py --build build/NEW-portable
powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-Portable.ps1 -BuildDirectory build/NEW-portable
powershell -NoProfile -STA -ExecutionPolicy Bypass -File Edit-Hotkeys-GUI.ps1 -Portable -SelfTest
powershell -NoProfile -ExecutionPolicy Bypass -File tools/Build-Portable-Package.ps1 -BuildDirectory build/NEW-portable
```

构建只能使用新的 build 子目录，拒绝覆盖已有候选。开发构建依赖本机核验的原 DLL、v2 候选和旧 v3 候选，均不进入 Git；普通使用不依赖这些文件。可分发包中的差异由安装器校验固定差异摘要、源摘要、编辑边界及重建目标摘要。

已执行隔离原生指令测试、生成文件读取、跨语言序列化、中文路径／自定义安装位置、检测歧义、签名不符、运行进程保护、安装／应用／还原／重装、损坏差异、并发修改和失败回退测试，以及既有 v2／旧版回归。测试不加载腾讯 DLL，不操作游戏进程，也不发真实游戏消息。

正常 Windows 加载回归仅加载自编最小 DLL，验证原 R 区 IAT 与追加 RW 区槽位分离的布局：原布局正常、旧 v3 类布局失败、修复布局正常。此证据与 159 项隔离输入逻辑、17 项文件读取及 62 项事务检查一起作为打包门槛，不代表已加载腾讯组件。

**2026-10-04 用户报告旧 v3 在训练模式中面板及全部快捷键均无响应。本修复版尚待游戏内复测。** 交付必须标为测试包，不能把离线检查或文件回读当成兼容实证。新电脑先训练模式小范围验证；若安全／完整性拒绝、闪退或异常，停止并还原，不强行绕过。
