# 本地文案库 v1（前一阶段的 8 KiB 版本）

2026-10-04 已安装，用户随后报告游戏中工作正常。下面保留这一阶段的构建与恢复说明；最新 64 KiB／独立组合键／增删消息版请看项目根目录 README。不要在 v2 安装状态下混用本目录旧管理器。

目标是绕开 **整套方案 2046 UTF-8 字节**的传输容量，不是突破游戏单条聊天消息上限。保留二十条、原快捷键、单条 50 UTF-16 单位的保护限制；本地紧凑 JSON 先限 8192 字节。

现有传输包不扩容。短 JSON 的首字段 `_lps_local_v1` 包含完整文件的字节长度与 FNV-1a32 校验值，前十条保留真实面板预览。实验 DLL 在原接收位置识别标记，再读取唯一固定文件 `C:\Users\zly\AppData\Local\PallasCustomShout\library20-v1.json`，将完整 JSON 交给原解析和二十条处理逻辑。

FNV 用于发现文件不一致，不是密码学认证。源文件仍严格校验结构、重复键、Unicode、控制字符和单条长度。读取只用同步只读句柄；不创建游戏进程、不注入、不联网、不发送测试消息。文件缺失、大小不符、校验失败、内存或读取失败时替换为空方案，新增发送守卫拒绝空字符串。

## 当前进度与风险

- 完整测试库 **2294 字节**，短传输 JSON **1280 字节**，20 条均为 43 UTF-16 单位，尾标为 `LIB-END-01` 至 `LIB-END-20`。
- 离线重建、PE 布局、ASLR 相对引用、原有非代码段、Win64 展开表、隔离指令及保存/恢复用例有自动测试。另在独立进程用真实 Windows 文件读取 API 回读生成的测试文件；不访问 AppData 运行库。隔离测试不加载真正的腾讯 DLL，不证明 WeGame 实际加载或最终游戏发送。
- DLL 的 Authenticode 摘要失效（`HashMismatch`），可能被拒绝或更新覆盖。不得绕过完整性、签名或反作弊检查；异常时停止并恢复。
- 仍仅适配现有 zly 账户和固定 WeGame 版本，不能直接当作通用分发版。
- 本阶段独立管理器仅支持 v1 的二十条库；原二十条 GUI 仍为 2046 字节模式。根目录 `Open-Editor.cmd` 现在进入新 v2 编辑器，支持从 v1 导入，但不自动修改运行文件。

## 离线构建

在项目根目录运行 `powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-Library-Experiment.ps1`，生成到 `build/local-library-v1/`，不安装。输出目录存在时拒绝覆盖，可显式指定一个新的 `-ArtifactDirectory`。开发依赖本机 Python 与 LLVM；游戏使用时不运行它们。

## 安装验证（需要先同意新实验并完全退出游戏/WeGame）

只有 `build/local-library-v1/` 已生成并通过验证后，才运行本目录 `Enable-Pallas-Library.cmd`。安装会备份**当前可用的二十条 DLL 和当前运行文案**，然后写入独立文案库、实验 DLL、短本地响应，逐项回读。安装器不会终止进程或自动启动、发送消息。

先在训练/私人测试环境手动验证第 1 条和第 20 条，确认收到 `LIB-END-01`、`LIB-END-20`，并确认原生面板仍可使用。只有在游戏端验证后才能称为突破成功。被拒绝加载、闪退或异常时停止使用，运行 `Restore-Pallas-Library.cmd`，不尝试绕过保护。

`Check-Pallas-Library.cmd` 只读检查。`Restore-Pallas-Library.cmd` 返回安装前的**二十条版本与文案**，不是顶层恢复脚本的十条版；备份在 `%LOCALAPPDATA%\PallasCustomShout\LocalLibraryExperiment`。文案库和备份保留，不删除，恢复后该库不再使用。

## 编辑与应用（仅在实验安装成功后）

此阶段不使用旧 GUI 来应用扩容库。复制本目录的示例为你自己的 JSON 文件，保持 `title`、`key`、`0` 至 `19`。用 `Manage-Pallas-Library.ps1 -Mode Validate -SchemePath "你的文件绝对路径"` 离线校验；完全退出游戏/WeGame 后用 `-Mode Apply -SchemePath "你的文件绝对路径"` 应用。每次应用备份旧文案库与短响应，失败时尝试回滚，未知 DLL 或并发改动会拒绝覆盖。

不得只修改 AppData 中的库文件；长度/校验值必须同步生成，否则该方案停止发送。不要在 WeGame 云端设置中保存这些本地文案。

## 新代码

- `tools/native/library20.c`：只读本地库及空消息守卫。
- `tools/native/PallasLibrary.py`：离线编译、校验导入槽、追加原生段和展开元数据；不安装。
- `lib/LibraryTools.ps1`：扩容文案校验、短响应、带版本和并发保护的文件写入。
- 本目录管理脚本：独立备份、实验安装、应用和恢复。
- `tests/Test-Library*.ps1`、`tests/Test-Library-Native.py`：离线和隔离测试。

同步文件读取和 EOF 处理遵循 [Microsoft ReadFile 文档](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-readfile)，只读打开方式参考 [CreateFileW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew)。
