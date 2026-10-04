# LOLPallas

WeGame 本地快捷喊话及中文编辑器。新版候选支持 **64 KiB 文案库、1～512 条消息、每条独立组合键**。当前交付为不绑定用户名和盘符的 **v3 热键修复测试版**，仍锁定经核验的 WeGame 组件版本；真实游戏效果待复测。

本机正在使用固定二十键回退对照版时，改用 `Open-NativeKeys-Editor.cmd`，不要使用旧 EXE 的应用／还原按钮。此版保留 64 KiB 和文案，恢复 `~＋数字／F1～F10` 原生处理，停用独立改键与增删条目；游戏内效果仍待实测。详见 [固定二十键回退说明](docs/native-keys-control.md)。

## 单文件 EXE

`tools/Build-Standalone.ps1` 生成 `dist/LOLPallas-Fixed-Test-日期.exe`，双击即可打开中文编辑器；路径选择、安装／启用、还原、导入／导出均在一个窗口，不需要自行解压或寻找 CMD。首次仍需退出游戏和 WeGame、选择安装目录并确认实验风险，不能免确认安装或保证任意版本可用。

EXE 内置所有自身运行资源，首次自动校验并释放到当前用户的版本化缓存。个人文案和路径设置单独持久保存在 `%LOCALAPPDATA%\LOLPallasPortable\Editor`；移动／分享 EXE 不会携带私人文案。有旧 `messages.json` 可在界面“导入文案”。旧 v3 用户需点“安装／启用”升级；保留已有文案、键位和最初还原备份，不自动应用草稿。修复导入布局、原生面板状态及修饰键事件跟踪，原有发送函数不变。EXE 未签名，组件签名失效及游戏内未验证的边界不变。详见 [EXE 使用与实现说明](docs/single-exe.md)。

## 分享测试包（v3）

`tools/Build-Portable-Package.ps1` 生成干净 ZIP：自动检测／手动选择 WeGame、同用户管理员安装、本地编辑、应用和备份还原；接收者不需要 Python 或编译器。只带公共默认文案及二进制差异，不带个人 messages.json、备份或完整腾讯组件。

接收者全部解压，退出游戏和 WeGame，运行包内 `Install.cmd`，阅读风险提示并确认，再用 `Open-Editor.cmd`。安装后手动开启 WeGame“一键喊话”，先在训练模式验证。未知组件版本拒绝替换。

**这是尚未完成游戏内复测的实验包，不能保证任意电脑即用。** 旧 v3 已报告游戏内无响应；本修复候选通过离线输入、加载及升级回退检查。构建和测试不自动改变真实安装或私人文案。完整用法见 [分享包说明](portable/README.md)，原理与测试边界见 [v3 设计说明](docs/portable-v3.md)。不要在源码的 `portable/` 子目录直接运行 CMD，那些入口用于打包后根目录。

## 新版：64 KiB／独立快捷键

本机 v2 已安装并通过文件回读校验（2026-10-04）。原二十条已原样迁移，运行库为 2296 字节；真实游戏发送待用户在训练模式确认。

双击 `Open-Editor.cmd`。首次打开会把当前 v1 本地库的二十条文案和原快捷键导入 `messages.json`，不会覆盖已有源文件，也不会自动应用到运行目录。

- 在表格修改“消息内容”和“快捷键”，可以“新增消息”“删除选中”“录制快捷键”。
- 支持如 `Ctrl+Alt+Q`、`Ctrl+Shift+F2`、`~+1`、`~+F1`；Ctrl/Alt/Shift/~ 可以组合，至少一个前缀。不支持裸键、Win、Enter、Tab、Esc；系统关闭等危险组合拒绝保存。
- “保存文案”仅保存源文件，WeGame 可以继续运行；旧源文件自动备份到项目 `backups/`。
- 首次安装先结束游戏并退出客户端、从托盘退出 WeGame，再运行 `Enable-Pallas-Hotkeys.cmd`，确认实验版安装。
- 后续修改用“保存并应用”，同样要求完全退出游戏、客户端及 WeGame，然后手动启动 WeGame。启动后不要在 WeGame 原生助手里编辑文案。
- 按住所设修饰键、按下主键发送一次；只松开主键就能再发。按住主键不会连续刷屏，额外 Ctrl/Alt/Shift/~ 修饰键必须与设置一致。

快捷键仍通过 WeGame 原发送链路，不模拟逐字输入。新版接管原键位处理，原生十条面板不是此版本的编辑／发送入口，不展示自定义键位；使用本地编辑器。游戏本身仍会收到这些按键，不负责屏蔽或消除游戏绑定冲突。

**容量不是单条长度**：64 KiB 即 65536 字节，包含二进制头、键位记录和 UTF-8 文案。每条记录额外 9 字节，整库额外 16 字节；消息数量也有 512 条保护上限，不能同时保证 512 条都写满。中文通常每字 3 字节。单条仍限制 50 个 UTF-16 单位，超出拒绝保存、不截断；这不是测得的游戏上限，也没有扩大游戏服务器的单条限制。

`messages.json` 是可编辑源文件；应用生成 `%LOCALAPPDATA%\PallasCustomShout\hotkeys-v2.bin` 及短响应 `local-response.json`。固定 2046 字节传输链路未扩大，只传递本地文件的长度／一致性校验标记。原生代码只加载经过完整长度、版本、校验、UTF-8、单条保护、条数及键位去重检查的库；异常时禁用发送。

`Check-Pallas-Hotkeys.cmd` 只读检查；`Restore-Pallas-Hotkeys.cmd` 恢复安装前已由用户确认可用的 **8 KiB v1 二十条 DLL／库／响应**，保留所有 v2 文案和备份。运行备份在 `%LOCALAPPDATA%\PallasCustomShout\HotkeysV2Experiment`，原 v1 备份不动。不要混用旧二十条安装／恢复工具。

离线测试已覆盖 64 KiB 边界、512 条映射、独立组合、按键去重、坏文件禁用、跨语言字节一致性、保存／应用／安装／回退及旧版回归。v1 已由用户报告真实游戏发送正常；新版的真实加载和发送仍需安装后在训练模式人工验证，不能仅凭离线测试宣布游戏兼容。

此候选加入两个标准 USER32 API 来读取键盘状态和前台窗口，并将可执行代码与可写缓存分开，不创建 RWX 节。修改组件的 Authenticode 摘要仍失效。如果更新、签名、完整性或反作弊检查拒绝加载，应停止并恢复，不能绕过检查。没有自动发送游戏消息，也没有对游戏进程进行运行时注入或读取。

新增主要文件：`Edit-Hotkeys-GUI.ps1`（界面）、`lib/HotkeyTools.ps1`（校验和保存）、`Manage-Pallas-Hotkeys.ps1`（安装应用回退）、`messages.example.json`（模板）、`tools/native/hotkeys2.c`（本地库与键位处理）、`tools/native/PallasHotkeys.py`（离线构建）。`messages.json` 和生成组件不进入 Git。旧版代码保留用于回退和对照。

完整说明与验证边界见 [v2 设计说明](docs/hotkeys-v2.md)。这仍不是可直接发送给任意其他电脑的通用安装包。

## 旧版二十条（2046 字节）使用

旧版编辑器入口是 `Open-Twenty-Editor.cmd`，原 `Open-Editor.cmd` 现在进入 v2。下面说明仅适用于旧版二十条／2046 字节版本，不适用于 v1 文案库或 v2 独立键位版。

- **保存到本地**：写入 `scheme20.json`；WeGame 可以保持运行。不同文案保存前在 `backups/` 备份旧 JSON。
- **保存并应用**：先保存，再应用。必须先关闭游戏及客户端，并从系统托盘退出 WeGame；未退出时仅保存、拒绝应用。
- **读取已应用文案**：将当前运行文案读入编辑区，不自动保存或覆盖。
- **重读本地文件 / 检查环境**：重新加载文件 / 只读检查安装环境。

Git 检出不包含个人文案。首次正常打开编辑器时，会从 `scheme20.example.json` 创建本地 `scheme20.json`；已有文案不会被覆盖。离线自测不创建个人文件。

也可以运行 `Validate-Messages.cmd`、`Enable-Pallas-Twenty.cmd`、`Check-Pallas-Twenty.cmd`。成功应用后手动启动 WeGame，开启“一键喊话”，面板键与文案配置保持一致。

按住 `~`，按下 `1～9、0` 分别发送第 1～10 条；按下 `F1～F10` 分别发送第 11～20 条。松开主键后可以再次发送，不必每次松开 `~`。面板键可在编辑器改为 Ctrl。原生面板仍只显示前十条，F 键可能与游戏绑定冲突。

## 原理和边界

`scheme20.json` 是可编辑源文件。应用工具校验并转换为本地响应，Pallas 从 AppData 读取方案；二十条组件沿用原喊话发送链路。不是模拟逐字输入，也不是脱离 WeGame 的发送服务。

单条及方案名称暂保留 **50 个 UTF-16 单位的保护限制**，超出拒绝、不截断；这不是测得的游戏上限。整套紧凑 JSON 最多 **2046 个 UTF-8 字节**。不支持单条 500 字、颜色修改、自动连发或分条发送。

发送功能仍要求：

- `D:\Program Files (x86)\WeGame` 中已有经核验的本地文件版 `pallas.exe`。
- 加载器读取 `C:\Users\zly\AppData\Local\PallasCustomShout\local-response.json`。
- DLL / EXE 与管理脚本中的固定 SHA-256 匹配；未知版本拒绝覆盖。

因此不能保证发给别人即用。项目迁移只改变源码位置，没有改变安装路径或运行文案。

实验 DLL 的腾讯 Authenticode 摘要失效，可能被拒绝加载、更新覆盖或出现异常。异常时停止使用并恢复，不绕过签名、完整性或反作弊检查。不上传文案、不读取账号票据，也不自动发送游戏消息；WeGame 登录和其他功能仍可能联网。

前一阶段 [v1 本地文案库实验](experiments/local-library/README.md) 已安装，并由用户报告发送正常：8 KiB、二十条。新版 v2 在此基础上加入独立键位和增删消息。

## 恢复

`Restore-Pallas-Twenty.cmd` 恢复安装前的 **十条 DLL 和十条运行响应**，不是仅撤销一次编辑；不恢复 `pallas.exe`。恢复前也要完全退出游戏及 WeGame，后来编辑过的响应会另存备份。

运行备份及安装记录仍在 `%LOCALAPPDATA%\PallasCustomShout\TwentyMessageExperiment`，迁移未移动或删除它们。应用文案的响应备份在其中的 `TextBackups/`；编辑器源文件备份在项目 `backups/`。恢复后已有安装记录不会被直接覆盖，重装需要单独复核。

## 目录

```text
LOLPallas/
  Open-Editor.cmd             新版动态消息及独立键位编辑入口
  *-Pallas-Hotkeys.cmd         新版安装、检查、恢复
  Edit-Hotkeys-GUI.ps1        新版编辑器
  Manage-Pallas-Hotkeys.ps1   新版安装及文案管理
  messages.json              新版个人文案和键位，Git 忽略
  messages.example.json      新版模板
  Open-Twenty-Editor.cmd     旧版二十条编辑入口
  *-Pallas-Twenty.cmd          启用、检查和恢复入口
  Validate-Messages.cmd       离线校验入口
  Edit-Twenty-GUI.ps1         编辑器主程序
  Manage-Twenty-Release.ps1   应用及环境管理
  scheme20.example.json      Git 管理的默认模板
  scheme20.json              个人文案，Git 忽略
  lib/                       界面、校验和安全保存
  engine/                    版本锁定安装/恢复工具
    assets/                  必要原 DLL、候选及校验资料
  tools/native/              离线 DLL 构建源码和汇编
  tools/Test.ps1             测试入口
  tools/Build-Package.ps1    生成干净分发包
  tools/Build-Portable-Package.ps1  生成 v3 分享测试包
  tools/Test-Portable.ps1    v3 离线验证入口
  tools/Build-Standalone.ps1 单文件 EXE 构建与验证
  tools/desktop/            x64 .NET 宿主及启动清单
  Manage-Pallas-Portable.ps1 新版可移植安装／应用／还原
  portable/                 分享包入口模板、公共文案和说明
  tests/                     校验、控件和隔离文件测试
  build/、dist/、backups/     生成数据，Git 忽略
```

DLL 保留在本机 `engine/assets/`，不进入 Git；Git 克隆不会自带腾讯组件。离线构建源码保留，详见 `engine/assets/README.md`。

## 开发和打包（源码仓库）

在项目目录运行：

```powershell
powershell -NoProfile -Sta -ExecutionPolicy Bypass -File .\tools\Test.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-Hotkeys-Experiment.ps1
```

GUI 日常使用无需 Python。源文件、界面及事务测试使用 Windows PowerShell 5.1 和 WinForms，生成文件只写入 `build/` 或具名临时目录，不改运行响应、不发送消息。原生构建及隔离指令测试使用本机 Python 和 Clang；不会加载腾讯 DLL，启动应用时也不运行 Python。

`tools/Build-Package.ps1` 仍只打包旧二十条版本，**不是新版分发包**。新版分享请用 `tools/Build-Portable-Package.ps1`，得到名称带 `Portable-Test` 的 v3 ZIP。v2 本机安装路径不随 v3 的构建／打包改变；不能把旧包当成 64 KiB 自定义键位版。

CMD 使用 ASCII / CRLF；PowerShell 源码保持 ASCII，中文界面文本放在 UTF-8 JSON 中，避免 Windows PowerShell 5.1 编码问题。

## 迁移与历史

旧项目完整归档在 `D:\projects\LOLPallas-archive-20261004\legacy-project.zip`，`snapshot.json` 记录 84 个原文件的 SHA-256。归档已逐项校验。

旧十条云端编辑工具、颜色测试、重复的无界面/界面分发副本、旧压缩包及缓存不再保留在工作目录；需要时可从归档恢复。Codex 工作区中的历史研究资料未纳入当前项目，也没有删除。旧目录留下迁移说明。
