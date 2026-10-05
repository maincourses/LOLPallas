# LOLPallas · 本地快捷喊话工作台

Windows 单文件 Electron 编辑器。初始 20 条消息，最多 80 条；每 10 条为一组，新增消息会顺序进入下一组，删除时后续消息前移。游戏中沿用已验证的 `~` 面板键：按住 `~`，用 `PageDown` / `PageUp` 切组，再按主键盘 `1～9、0` 发送当前组第 1～10 条。原生面板仍只预览第一组，不显示当前组号。

## 使用分享包

发送 `dist/LOLPallas-Portable-0.1.3.exe` **一个文件**即可；接收者不需要安装 Python、Node.js 或复制本项目代码。编辑界面可直接双击打开；如果目标 WeGame 目录的权限限制写入，关闭程序后右键以管理员身份运行，再点“保存并应用”。若 Windows 提示未知发布者，这是因为此实验版没有代码签名，并非验证通过的发行证书。

不要再使用 `0.1.0`：它把原生 DLL 要求位于 JSON 首字段的本地库标记排在数字消息键之后，导致侧边栏预览正确但游戏内无法发送。`0.1.3` 已修正字段顺序，并移除了打开编辑器时不必要的强制提权；本机原生读取测试通过，实际游戏发送仍需在训练营验证。

1. 打开 EXE，确认 WeGame 安装目录；未自动检测到时点“选择目录”，选择**包含 `apps\Pallas` 的 WeGame 根目录**，不是英雄联盟游戏目录。
2. 编辑文案。新增会追加到末尾；删除任意一条会让后面的消息和键位顺序前移。至少保留 20 条；不能包含换行；整套 UTF-8 JSON 最多 65,536 字节。**没有单条长度保护**，很长的消息可能被游戏拒绝或引发异常。
3. “保存草稿”只保存本机内容，不改游戏。首次“保存并应用”前，请结束对局、关闭 LoL，并从托盘彻底退出 WeGame。工具会检查组件代码布局、备份原件并回读校验；写入或校验失败会自动回滚。代码布局未知时会拒绝安装。
4. 重启 WeGame，在助手里开启“一键喊话”，进入新的一局后测试。编辑器不需要在游戏时一直打开。需要恢复时，退出游戏与 WeGame 后点“还原组件”。

已应用库、草稿和备份放在接收者自己的 `%LOCALAPPDATA%\LPS`。分享 EXE **不含发送者个人文案**；在一台已有旧版文案的电脑上首次启动，会优先只读导入本机旧草稿/文案，不会自动覆盖它们。全新电脑默认 20 条通用示例文案。

兼容范围仍严格受限：只支持已验证的原版组件、此前验证成功的八组十条版，以及**除 PE 证书内容外完全相同**的文件。签名变了但代码没变时可以自动适配；WeGame 真正更新了代码、导入表或 PE 布局时，工具在写入前拒绝，必须取得新版本组件并单独开发、测试补丁。应用时发生写入或回读错误会自动回滚；游戏内不发送无法可靠自动识别，请退出游戏和 WeGame 后手动点“还原组件”。桌面界面、离线原生分组和隔离安装/还原测试已通过；**便携组件尚需在真实游戏里做最终发送验证**，不能把离线测试当成所有电脑、所有版本都已验证。

## 本机既有成功版

`Open-Banks10-Editor.cmd` / `Edit-Pallas-BanksTen.ps1` / `Manage-Pallas-BanksTen.ps1` 仍是此前用户确认可用的、绑定本机路径的历史版本。制作 Electron 包没有修改本机 WeGame 运行文件、当前已应用文案或备份。使用新 EXE 的“保存并应用”才会升级组件；升级前自动备份，失败会尝试回滚。

## 开发与构建

源码核心：`desktop/core.js` 负责数据校验、固定版本补丁、备份、应用和还原；`desktop/main.js` / `preload.js` 为受限 Electron IPC；`web/` 是 HTML/CSS/JS 界面；`tools/native/` 是离线原生候选源码。分享包只打包桌面运行文件和小型二进制**差量补丁**，不打包腾讯原始 EXE/DLL，也不需要在接收者电脑编译 C/Python。

开发者在本项目目录运行：

```powershell
npm ci
npm test
python tools/native/BuildPortableBanksTen.py
python tools/native/TestPortableBanks.py
node desktop/tests/ui-smoke.js
npm run dist
```

`BuildPortableBanksTen.py` 使用本地原版 DLL 夹具和 Clang；这些只在开发/重建补丁时需要。`engine/assets/TenPallas.original.dll` 未纳入 Git，也未分发。`desktop/assets/dll-*.json` 是已验证代码布局的固定差量；仅 PE 证书内容的变化可保留并继续应用，其他变化会拒绝。Electron portable target 的构建说明见 [electron-builder 官方文档](https://www.electron.build/docs/win/)。
