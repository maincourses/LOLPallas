# LOLPallas · 旧版二十条包

这是原二十条／2046 字节版本，不包含 64 KiB 独立快捷键版。

双击 `Open-Editor.cmd` 编辑，使用 `scheme20.json`。保存不应用；应用前必须退出游戏、客户端和 WeGame。

默认按住 `~`，按 `1～9、0` 发前十条，按 `F1～F10` 发后十条。只需松开主键即可再次发送。单条保护为 50 个 UTF-16 单位，整套紧凑 JSON 最多 2046 个 UTF-8 字节。

安装、检查、恢复入口分别为 `Enable-Pallas-Twenty.cmd`、`Check-Pallas-Twenty.cmd`、`Restore-Pallas-Twenty.cmd`；恢复回到安装前十条组件及响应。

仍要求 zly 用户目录中既有的本地读取版 Pallas 及固定 WeGame 版本，不是通用安装器。修改 DLL 的签名摘要失效；遇到完整性检查拒绝加载时应恢复，不绕过检查。不要将此旧安装器用于正在使用 v1 文案库或 v2 独立快捷键的安装。
