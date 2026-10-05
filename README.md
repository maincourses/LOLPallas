# LOLPallas · 当前可用版

这里只保留用户已确认正常使用的 **八组十条版**，共 80 条消息，沿用 WeGame 原生面板键和本地文案加载方式。旧版独立热键 EXE、分享包和实验入口已经移出项目。

## 日常使用

双击 [Open-Banks10-Editor.cmd](Open-Banks10-Editor.cmd) 打开中文编辑器。

- **保存文案**：保存草稿，不改变正在运行的游戏；可以在游戏中编辑并保存。
- **保存并应用**：结束对局、关闭游戏和客户端，并从托盘彻底退出 WeGame 后使用。应用前自动备份，完成后重启 WeGame，进入新的一局。
- **读取已应用文案**：读取当前运行库；未保存修改会先询问。
- 不再通过 WeGame 设置界面编辑文案，也不要运行归档里的旧 EXE 应用。

游戏内开启 WeGame 的“一键喊话”，按住当前面板键 `~`：

- `1～9、0`：发送当前组的第 1～10 条。
- `PageDown` / `PageUp`：下一组 / 上一组，八组首尾循环；翻页本身不发送。
- F1～F10 不触发本工具喊话。面板仍只预览第一组，不显示当前组号。

工具不再设置单条字符数上限、不截断完整文案；整套 UTF-8 JSON 仍限 **65536 字节**。这不代表游戏允许任意长度，长消息可能被拒绝或引发异常。当前分组发送已由用户确认可用，任意长文案的安全性未验证。

## 当前文件

| 文件／目录 | 用途 |
|---|---|
| `Open-Banks10-Editor.cmd`、`Edit-Pallas-BanksTen.ps1` | 编辑器入口和界面 |
| `Manage-Pallas-BanksTen.ps1` | 当前版本的检查、应用和恢复 |
| `Restore-Banks10.cmd` | 恢复到安装本版前的四组二十条版；先归档当前文案，草稿保留 |
| `Switch-Pallas-*.ps1`、`lib/` | 当前管理器仍依赖的校验、备份和兼容辅助代码；不是日常操作入口 |
| `tools/native/` | 当前版本离线构建与只读校验所需源码 |
| `tests/` | 当前版本测试及必要的测试辅助 |
| `build/legacy-eight-banks-ten-20261005/` | 当前候选组件及构建、测试记录 |
| `build/legacy-capacity64k-control-recheck-20261005/` | 当前原生读取测试需要的基准夹具，不是另一套使用入口 |
| `engine/assets/` | 离线重建所需原版 DLL，不用于手工替换运行文件 |
| `experiments/local-library/scheme20.example.json` | 当前读取测试依赖的公共夹具 |
| `backups/current-success-20261005/` | 清理前当前成功组件、最新已应用文案、草稿和状态的精确快照 |
| `docs/banks10.md` | 实现、限制和恢复说明 |
| `.git/` | 完整版本历史 |

实际文案不在工程根目录：

- 已应用库：`C:\Users\zly\AppData\Local\PallasCustomShout\library20-v1.json`
- 编辑草稿：`C:\Users\zly\AppData\Local\LOLPallasPortable\Editor\banks10-messages.json`
- 运行备份：`C:\Users\zly\AppData\Local\LOLPallasPortable\backups`

只读状态检查：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\projects\LOLPallas\Manage-Pallas-BanksTen.ps1 -Mode Status
```

本版绑定本机用户路径和已核验组件，不是可直接分享给其他电脑的 EXE。遇到未知版本或正常完整性检查拒绝时，应停止并恢复，不强行应用。

## 本次清理

2026-10-05：旧入口、过期文档、EXE／分享包、重复构建和旧测试产物移到：

`D:\projects\LOLPallas-archive\cleanup-20261005-d6f3b9840b78\files`

归档保留原相对路径；同目录 `cleanup-manifest.json` 记录移出清单，可恢复。个人文案、Git 历史和 WeGame 实际运行文件均未改动。当前版本的必要辅助依赖保留，没有为清理而改写发送逻辑。
