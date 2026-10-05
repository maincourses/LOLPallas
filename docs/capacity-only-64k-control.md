# 仅扩容 64 KiB 的旧版对照

2026-10-05，用户确认恢复后的 8 KiB 二十条配套可以正常使用。本次以这一配套为基线构建候选；首次交付仅离线构建。随后用户确认退出，已于北京时间 **14:16** 安装容量对照，启动器和全部文案不变，候选的实际游戏加载/发送仍待验证。不是先前游戏内失败的独立组合键版。

## 单变量证明

- 8 KiB 基线 DLL：`BEB422999A6E8E7F87D93937D9010B15DCAAACCE237FD7B11C280D5CF88CCA10`。
- 64 KiB 对照 DLL：`60A14666E80B72A0C87807A89740D51E74E2B68074632E052513A91C7B313A28`。
- 两个文件都是 1687080 字节。只有 3 个字节不同，全部位于 `ReadLocalScheme+0xDB` 的容量检查立即数：文件偏移 1615584、1615585、1615589。
- 编译器把 `2 <= length <= capacity` 编译成无符号范围比较。本次只将其中两个常量由 8192 对应值换成 65536 对应值，下界仍是 2。
- 文件其余字节完全相同：PE 头和节布局、原导入/IAT、初始化代码、原生二十键回调和辅助函数、栈展开表、临时堆分配/释放、路径及一致性校验都不变。没有新增 RW 全局缓存。
- 默认 C 编译仍为 8192，重新构建必须逐字节复现上述已验证基线；对照构建如果出现容量立即数以外的变化，会直接报错，不产出可用证明。

仍要求已经安装的旧版 `pallas.exe`：`803870E3FDA683443471E835699B065293724DC7E0F3289D0093FC84C8E30935`。本次不替换它，不改成原版启动器，也不改变加载器。

## 没有改变的使用方式

仍是旧版 JSON：本地 `library20-v1.json` 的 `0..19`、`title`、`key`；短 `local-response.json` 的 `_lps_local_v1` 仍传入原长度/FNV 标记。原 2046 字节预览传输不扩容。本地库按 token 长度动态分配临时堆缓冲，不是每次传输 64 KiB。

仍是固定二十条、单条及方案名最多 50 个 UTF-16 单位的保护。保留 `~+1..9,0` 和 `~+F1..F10`；原面板仍显示前十条，主键释放触发，行为与成功版一致。没有新增/删除消息，没有独立组合键，没有放大游戏单条长度。

正常二十条短文案的紧凑 JSON 通常不超过 8 KiB。因此本次扩容主要验证**容量变化是否会影响加载/发送**，不是已经获得数百条文案功能。普通文案保持原样测试，才能隔离 DLL 常量变化。

## 已完成的离线验证

完整构建/回归目录：`D:\projects\LOLPallas\build\legacy-capacity64k-control-recheck-20261005`。独立重新构建所得 DLL 与首轮产物逐字节一致。

- 8 项单变量、复现、JSON 和保护限制测试；7 项原库单元回归。
- 64 KiB 候选 77 项本进程桩测试、8 项真实 Win32 文件读取测试。
- 同样的夹具用于 8 KiB 基线：76 项本进程桩测试、8 项真实文件读取测试。
- 16 项旧 JSON/原子保存检查、14 项旧部署/回滚检查。部署测试只用生成的假文件，不安装候选。
- 8 KiB 接受 8192 字节、拒绝 8193；64 KiB 接受 8193、65535、65536，拒绝 65537；长文件、短文件、校验不一致、NUL、堆分配和读取失败仍禁用发送，文件/内存被正确释放。

这些真实文件测试只操作构建目录里的生成夹具；指令测试只链接自己编译的 C 和记录桩，不加载腾讯 DLL、不访问游戏进程、不调用真实游戏发送。

`fixtures/` 的大文件是**同二十条 JSON 加合法空白填充**，每条文字、键位和方案名完全不变。它们只是容量边界测试，不能证明支持更多消息，**不要把这些填充夹具安装到运行目录**。本进程复制成功也不等于腾讯 JSON 解析器/游戏已验证 64 KiB。

`manifest.json` 记录三个差异字节、两种编译命令和固定组件摘要。`validation.capacity-control.json`、`validation.library.json` 记录自动测试。它们均明确标记未安装、未进行该候选的游戏发送验证。

## 后续测试边界

首次构建结束时，实际安装仍是已成功的 8 KiB 配套。随后执行的安装见下节，现有所有文案和历史备份继续保留。构建目录不是安装包，也没有重新打包失败的现代 EXE。

本次开始和结束核对了实际 DLL、启动器、旧库/响应、现代安装记录、编辑草稿、已应用源 JSON 和二进制库这 8 个文件的长度和 SHA-256，全部不变。默认 8 KiB 构建完整回归及公共源码/GUI 自测也已通过。

用户退出游戏及 WeGame 后，已进行有备份和摘要校验的**仅 DLL 切换**。启动器、运行 JSON 和全部文案不变；下一步先测试面板、第 1 条和第 20 条是否如基线工作。不要使用现代独立键位版 EXE 的应用/安装按钮，也不要把示例 JSON 覆盖自己的文案。旧管理器仍锁定 8 KiB；本对照使用独立的状态/恢复脚本，不能假装旧管理器已经识别新版本。

如果对照失败，应先恢复精确的 8 KiB DLL 并回读，保留新局日志，再判断容量变化是否与故障相关；不能仅凭静态差异宣称根因。修改 DLL 的 Authenticode 摘要仍无效；如果正常加载因完整性/安全检查拒绝，停止并恢复，不绕过保护。

## 本机安装记录（14:16）

`Switch-Pallas-CapacityControl.ps1` 的 `Validate` 和 `Install -WhatIf` 完成后实际执行 `Install -AcceptUnsignedExperiment`；每次写入前检查停止进程、相同用户/路径、固定组件摘要和并发变化，使用同一个组件互斥锁及原子回读。

备份目录：`C:\Users\zly\AppData\Local\LOLPallasPortable\backups\legacy-capacity64k-ae9ace0d1d354bdca9ae35c7996d266a`。

安装前后独立核对 11 个已有文件及 11 份备份：只改变 DLL、现代安装记录、旧本地库安装记录；其余 8 个文件（启动器、库/响应、现代库/已应用源、草稿、路径设置及加载器记录）长度和摘要均不变。当前实际库仍为 725 字节，预览为 521 字节，没有安装大尺寸空白夹具。

两个旧安装记录标记 `suspended-for-legacy-capacity64k-control`，历史候选和原版恢复基线保留，额外的 `active_control_dll_sha256`/`active_control_capacity_bytes` 明确当前为此 DLL/65536。新的 `LOLPallasPortable/legacy-capacity-control.json` 记录安装时间、准确备份和待游戏验证状态；原构建报告的 `installed=false` 保留作离线历史，不冒充安装日志。

安装和恢复自动检查共 **181 项**通过，覆盖三处提交点和控制日志的写入前/写入后故障、精确逆序回滚、恢复失败回到原活跃状态、并发变更拒绝、草稿编辑保留和命令参数传递。测试只使用生成的假文件；没有为了验证而切回真实 DLL。公共源码/GUI 回归通过。

安装后只读状态确认 DLL 为 `60A14666...B313A28`、旧启动器匹配。最新可用日志仍是 13:46 的旧 8 KiB 局（RunFlag=3、方案已下发），其 `MatchesCurrentInstall=false`，不能当作新对照成功。没有启动游戏，也没有发送消息。

查看状态：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\projects\LOLPallas\Switch-Pallas-CapacityControl.ps1 -Mode Status
```

如需回到成功的 8 KiB，先彻底退出游戏及 WeGame，然后运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\projects\LOLPallas\Switch-Pallas-CapacityControl.ps1 -Mode Restore
```

恢复只还原精确的 8 KiB DLL 和两个管理记录，不改启动器、不覆盖任何文案/草稿、不删除备份。组件或目标管理记录存在未知并发变化时拒绝覆盖。不要混用早期旧库的 Restore，它回到的是更早的二十条版本，不是本次成功 8 KiB 基线。

## 重新构建

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\projects\LOLPallas\tools\Build-Capacity-Control.ps1
```

使用本机 Python/Clang，默认创建新的 `build/legacy-capacity64k-control-<随机标识>`，不覆盖旧产物，不写入真实安装或运行目录。需要本地保留的原 DLL 和固定哈希的旧 8 KiB 基线；腾讯组件、个人文案和生成数据均不进入 Git。源码工具不是任意电脑即用的分享版本。
