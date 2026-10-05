# 原版离线重建基准

`TenPallas.original.dll` 是当前八组十条版离线重建与测试所需的固定原版基准，不是安装入口，不要手工复制到运行中的 WeGame。

原版 SHA-256：

`97BA57FD47A393A3A4BBFA684D0F03D10CF04344FBD99CB2D2E8626675BE9C94`

当前构建器为 `tools/native/PallasBanksTen.py`，当前只读校验器为 `tools/native/ValidateBanksTenInstall.py`。它们通过保留的公共辅助模块复现当前候选，未知基准不得强行使用。

组件不进入 Git，旧二十条候选和对应记录已移到工程外归档。实际运行文件及原始恢复备份未改动。组件变更会使原签名摘要失效；正常加载或安全检查拒绝时应停止、恢复，不绕过检查。
