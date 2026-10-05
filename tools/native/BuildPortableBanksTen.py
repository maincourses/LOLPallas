"""Build a version-pinned, profile-neutral patch bundle (not Tencent binaries).

The generated JSON contains only byte differences from two known installed DLL
states. It does not install anything or include the original executable/DLL.
"""
from __future__ import annotations

import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).parent))
import PallasBanks80 as banks


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def delta(before: bytes, after: bytes) -> dict:
    edits = []
    at = 0
    common = min(len(before), len(after))
    while at < len(after):
        if at < common and before[at] == after[at]:
            at += 1
            continue
        start = at
        while at < len(after):
            at += 1
            if at < common and before[at] == after[at]:
                end = at
                while end < common and before[end] == after[end] and end - at < 16:
                    end += 1
                if end - at >= 16:
                    break
                at = end
        edits.append([start, base64.b64encode(after[start:at]).decode("ascii")])
    return dict(format=1, sourceSha256=digest(before), targetSha256=digest(after),
                sourceSize=len(before), targetSize=len(after), edits=edits)


def main() -> None:
    original = (ROOT / "engine/assets/TenPallas.original.dll").read_bytes()
    legacy = (ROOT / "build/legacy-eight-banks-ten-20261005/TenPallas.banks10.experimental.dll").read_bytes()
    if digest(original) != "97ba57fd47a393a3a4bbfa684d0f03d10cf04344fbd99cb2d2e8626675be9c94":
        raise ValueError("Unknown original DLL")
    if digest(legacy) != "5407dfa6a92640b216f5fba143a5baf63ec68e46a108fc664356df3a037bf3e2":
        raise ValueError("Unknown working DLL")
    clang = Path(r"D:\LLVM\bin\clang.exe")
    if not clang.is_file():
        raise FileNotFoundError("Clang is needed only when BUILDING the distributable, not by its users")
    target = ROOT / "build/portable-banks10"
    target.mkdir(parents=True, exist_ok=True)
    obj = target / "library80-banks.obj"
    command = [str(clang), "--target=x86_64-pc-windows-msvc", "-Os", "-ffreestanding",
               "-fno-builtin", "-fno-stack-protector", "-fno-ident", "-fno-addrsig",
               "-funwind-tables", "-g0", "-Wall", "-Wextra", "-Werror",
               "-DLPS_BANK_SIZE=10", "-DLPS_BANK_SINGLE_LIMIT=0", "-DLPS_PORTABLE_PATH=1",
               "-DLPS_DYNAMIC_BANKS=1", "-c", str(ROOT / "tools/native/library80-banks.c"),
               "-o", str(obj)]
    subprocess.run(command, check=True)
    candidate, _, _ = banks.patch_banks(original, obj.read_bytes())
    for name, source in (("stock", original), ("working", legacy)):
        payload = json.dumps(delta(source, candidate), separators=(",", ":"))
        (ROOT / f"desktop/assets/dll-{name}.json").write_text(payload, encoding="ascii")
    print(json.dumps(dict(candidateSha256=digest(candidate), candidateSize=len(candidate),
                          stockDeltaBytes=(ROOT / "desktop/assets/dll-stock.json").stat().st_size,
                          workingDeltaBytes=(ROOT / "desktop/assets/dll-working.json").stat().st_size)))


if __name__ == "__main__":
    main()
