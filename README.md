# LOLPallas

WeGame 本地二十条快捷喊话及中文文案编辑器。当前是 **zly 这台电脑的实验版**，不是通用安装器。

## 使用

双击 `Open-Editor.cmd`。两个标签页分别编辑前十条、后十条，界面显示快捷键、长度和整包容量。

- **保存到本地**：写入 `scheme20.json`；WeGame 可以保持运行。不同文案保存前在 `backups/` 备份旧 JSON。
- **保存并应用**：先保存，再应用。必须先关闭游戏及客户端，并从系统托盘退出 WeGame；未退出时仅保存、拒绝应用。
- **读取已应用文案**：将当前运行文案读入编辑区，不自动保存或覆盖。
- **重读本地文件 / 检查环境**：重新加载文件 / 只读检查安装环境。

Git 检出不包含个人文案。首次正常打开编辑器时，会从 `scheme20.example.json` 创建本地 `scheme20.json`；已有文案不会被覆盖。离线自测不创建个人文件。

也可以运行 `Validate-Messages.cmd`、`Enable-Pallas-Twenty.cmd`、`Check-Pallas-Twenty.cmd`。成功应用后手动启动 WeGame，开启“一键喊话”，面板键与文案配置保持一致。

按住 `~`，松开 `1～9、0` 分别发送第 1～10 条；松开 `F1～F10` 分别发送第 11～20 条。不必每次松开 `~`。面板键可在编辑器改为 Ctrl。原生面板仍只显示前十条，F 键可能与游戏绑定冲突。

## 原理和边界

`scheme20.json` 是可编辑源文件。应用工具校验并转换为本地响应，Pallas 从 AppData 读取方案；二十条组件沿用原喊话发送链路。不是模拟逐字输入，也不是脱离 WeGame 的发送服务。

单条及方案名称暂保留 **50 个 UTF-16 单位的保护限制**，超出拒绝、不截断；这不是测得的游戏上限。整套紧凑 JSON 最多 **2046 个 UTF-8 字节**。不支持单条 500 字、颜色修改、自动连发或分条发送。

发送功能仍要求：

- `D:\Program Files (x86)\WeGame` 中已有经核验的本地文件版 `pallas.exe`。
- 加载器读取 `C:\Users\zly\AppData\Local\PallasCustomShout\local-response.json`。
- DLL / EXE 与管理脚本中的固定 SHA-256 匹配；未知版本拒绝覆盖。

因此不能保证发给别人即用。项目迁移只改变源码位置，没有改变安装路径或运行文案。

实验 DLL 的腾讯 Authenticode 摘要失效，可能被拒绝加载、更新覆盖或出现异常。异常时停止使用并恢复，不绕过签名、完整性或反作弊检查。不上传文案、不读取账号票据，也不自动发送游戏消息；WeGame 登录和其他功能仍可能联网。

## 恢复

`Restore-Pallas-Twenty.cmd` 恢复安装前的 **十条 DLL 和十条运行响应**，不是仅撤销一次编辑；不恢复 `pallas.exe`。恢复前也要完全退出游戏及 WeGame，后来编辑过的响应会另存备份。

运行备份及安装记录仍在 `%LOCALAPPDATA%\PallasCustomShout\TwentyMessageExperiment`，迁移未移动或删除它们。应用文案的响应备份在其中的 `TextBackups/`；编辑器源文件备份在项目 `backups/`。恢复后已有安装记录不会被直接覆盖，重装需要单独复核。

## 目录

```text
LOLPallas/
  Open-Editor.cmd             日常编辑入口
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
  tests/                     校验、控件和隔离文件测试
  build/、dist/、backups/     生成数据，Git 忽略
```

DLL 保留在本机 `engine/assets/`，不进入 Git；Git 克隆不会自带腾讯组件。离线构建源码保留，详见 `engine/assets/README.md`。

## 开发和打包（源码仓库）

在项目目录运行：

```powershell
powershell -NoProfile -Sta -ExecutionPolicy Bypass -File .\tools\Test.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-Package.ps1
```

GUI 日常使用无需 Python。测试使用 Windows PowerShell 5.1 和系统 WinForms，测试文件只写入 `build/test-work/`，不改运行响应、不发送消息。DLL 开发工具需要 Python 3，但不在应用启动时运行。

打包包含应用和原生构建源码，默认使用模板文案，不包含你的个人文案、备份、开发测试、旧实验或 Git 历史；输出到 `dist/`，逐项回读 SHA-256。生成包仍是本机版本，不会因为重新打包而变成通用版。

CMD 使用 ASCII / CRLF；PowerShell 源码保持 ASCII，中文界面文本放在 UTF-8 JSON 中，避免 Windows PowerShell 5.1 编码问题。

## 迁移与历史

旧项目完整归档在 `D:\projects\LOLPallas-archive-20261004\legacy-project.zip`，`snapshot.json` 记录 84 个原文件的 SHA-256。归档已逐项校验。

旧十条云端编辑工具、颜色测试、重复的无界面/界面分发副本、旧压缩包及缓存不再保留在工作目录；需要时可从归档恢复。Codex 工作区中的历史研究资料未纳入当前项目，也没有删除。旧目录留下迁移说明。
