# LOLPallas · 本地快捷喊话工作台

Windows 单文件 Electron 编辑器。初始 20 条消息，最多 80 条；每 10 条为一组，新增消息会顺序进入下一组，删除时后续消息前移。游戏中沿用已验证的 `~` 面板键：按住 `~`，用 `PageDown` / `PageUp` 切组，再按主键盘 `1～9、0` 发送当前组第 1～10 条。原生面板仍只预览第一组，不显示当前组号。

## 使用分享包

给朋友发送 `dist/LOLPallas-Portable-0.1.0.exe` **一个文件**即可；接收者不需要安装 Python、Node.js 或复制本项目代码。双击时 Windows 会请求管理员权限，因为首次应用需要备份并替换 WeGame 安装目录中的两个组件。若 Windows 提示未知发布者，这是因为此实验版没有代码签名，并非验证通过的发行证书。

1. 打开 EXE，确认 WeGame 安装目录；未自动检测到时点“选择目录”，选择**包含 `apps\Pallas` 的 WeGame 根目录**，不是英雄联盟游戏目录。
2. 编辑文案。新增会追加到末尾；删除任意一条会让后面的消息和键位顺序前移。至少保留 20 条；不能包含换行；整套 UTF-8 JSON 最多 65,536 字节。**没有单条长度保护**，很长的消息可能被游戏拒绝或引发异常。
3. “保存草稿”只保存本机内容，不改游戏。首次“保存并应用”前，请结束对局、关闭 LoL，并从托盘彻底退出 WeGame。工具会核对组件哈希、备份原件并回读校验；未知版本会拒绝安装。
4. 重启 WeGame，在助手里开启“一键喊话”，进入新的一局后测试。编辑器不需要在游戏时一直打开。需要恢复时，退出游戏与 WeGame 后点“还原组件”。

已应用库、草稿和备份放在接收者自己的 `%LOCALAPPDATA%\LPS`。分享 EXE **不含发送者个人文案**；在一台已有旧版文案的电脑上首次启动，会优先只读导入本机旧草稿/文案，不会自动覆盖它们。全新电脑默认 20 条通用示例文案。

当前分享包只支持源码中固定哈希的 **一版** Pallas/`TenPallas.dll`，以及本项目此前验证成功的八组十条版。WeGame 自动更新导致哈希变化时，工具会停止；若 WeGame 拒绝修改后的组件，应使用“还原组件”，不要继续强行兼容。桌面界面、离线原生分组和隔离安装/还原测试已通过；**便携组件尚需在真实游戏里做最终发送验证**，不能把离线测试当成所有电脑、所有版本都已验证。

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

`BuildPortableBanksTen.py` 使用本地原版 DLL 夹具和 Clang；这些只在开发/重建补丁时需要。`engine/assets/TenPallas.original.dll` 未纳入 Git，也未分发。`desktop/assets/dll-*.json` 是固定版本差量，收到其他版本会拒绝应用。Electron portable target 的构建说明见 [electron-builder 官方文档](https://www.electron.build/docs/win/)。
