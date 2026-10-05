"""Own offline build: eight ten-key banks, no individual character-count cap.

Preserve the current eighty texts and existing local loader/protocol/64 KiB
reader. Never install, launch games, load a Tencent module or send messages.
"""
from __future__ import annotations
import argparse
import base64
import json
from pathlib import Path
import subprocess

import PallasBanks80 as old

library = old.library
EXPERIMENT = "legacy-eight-ten-key-banks-no-character-cap-v1"


def preview_text(text):
    out, units = [], 0
    for char in text:
        extra = 2 if ord(char) > 0xFFFF else 1
        if units + extra > 32:
            return "".join(out) + "…"
        out.append(char)
        units += extra
    return text


def artifacts(scheme):
    if (not isinstance(scheme, dict) or set(scheme) != {"title", "key", *(str(i) for i in range(80))}
            or type(scheme["key"]) is not int or scheme["key"] not in (1, 2)):
        raise ValueError("Requires exactly eighty messages and unchanged panel-key metadata.")
    for name in ("title", *(str(i) for i in range(80))):
        value = scheme[name]
        if not isinstance(value, str) or not value.strip() or any(ord(c) < 32 or ord(c) == 127 for c in value):
            raise ValueError(f"{name}: nonempty valid UTF-8 text without control characters required.")
        value.encode("utf-8", "strict")
    ordered = {str(i): scheme[str(i)] for i in range(80)}
    ordered.update(title=scheme["title"], key=scheme["key"])
    raw = library.twenty.compact(ordered)
    if len(raw) > 65536:
        raise ValueError("Whole UTF-8 JSON library exceeds 65536 bytes; no text is truncated.")
    preview = {"_lps_local_v1": f"{len(raw):08X}:{library.fnv1a(raw):08X}"}
    preview.update({str(i): preview_text(scheme[str(i)]) if i < 10 else "" for i in range(20)})
    preview.update(title=preview_text(scheme["title"]), key=scheme["key"])
    short = library.twenty.compact(preview)
    if len(short) > 2046:
        # Escaped/unusual preview characters must never impose an indirect
        # per-message limit on the FULL local data. Drop display-only previews.
        preview.update({str(i): "" for i in range(10)})
        short = library.twenty.compact(preview)
    if len(short) > 2046:
        raise ValueError("Native preview transport overflow.")
    response = library.twenty.compact({"result": {"error_code": 0},
                                      "shout_message": base64.b64encode(short).decode("ascii")})
    metrics = dict(message_count=80, bank_count=8, bank_size=10, allocated_string_count=81,
                   library_capacity_bytes=65536, library_json_utf8_bytes=len(raw),
                   bootstrap_json_utf8_bytes=len(short), single_message_utf16_limit=None,
                   function_keys_send=False, full_message_text_truncated=False)
    return raw, response, metrics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed-library", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--clang", default=r"D:\LLVM\bin\clang.exe")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    out = args.out_dir.resolve()
    if root / "build" not in out.parents or out.exists():
        raise ValueError("Use a NEW project build directory, never live/prior paths.")
    seed_bytes = args.seed_library.read_bytes()
    seed = json.loads(seed_bytes.decode("utf-8-sig"), object_pairs_hook=library.twenty.unique_object)
    raw, response, metrics = artifacts(seed)
    original = (root / "engine/assets/TenPallas.original.dll").read_bytes()
    if library.twenty.sha256(original) != library.twenty.DLL_SHA256:
        raise ValueError("Unknown original component version.")
    out.mkdir(parents=True, exist_ok=False)
    c_path = Path(__file__).with_name("library80-banks.c")
    obj = out / "library80-banks.obj"
    command = [args.clang, "--target=x86_64-pc-windows-msvc", "-Os", "-ffreestanding", "-fno-builtin",
               "-fno-stack-protector", "-fno-ident", "-fno-addrsig", "-funwind-tables", "-g0",
               "-Wall", "-Wextra", "-Werror", "-DLPS_BANK_SIZE=10", "-DLPS_BANK_SINGLE_LIMIT=0",
               "-c", str(c_path), "-o", str(obj)]
    subprocess.run(command, check=True, capture_output=True, text=True)
    candidate, native, changes = old.patch_banks(original, obj.read_bytes())
    library.twenty.write_new(out / "library80.json", raw)
    library.twenty.write_new(out / "local-response80.json", response)
    library.twenty.write_new(out / "scheme80.json", json.dumps(seed, ensure_ascii=False, indent=2).encode("utf-8"))
    library.twenty.write_new(out / "TenPallas.banks10.experimental.dll", candidate)
    report = dict(experiment=EXPERIMENT, metrics=metrics, native=native, changes=changes,
                  seed_library_sha256=library.twenty.sha256(seed_bytes),
                  candidate_dll_sha256=library.twenty.sha256(candidate),
                  object_sha256=library.twenty.sha256(obj.read_bytes()),
                  c_source_sha256=library.twenty.sha256(c_path.read_bytes()), compile_command=command,
                  library_sha256=library.twenty.sha256(raw), response_sha256=library.twenty.sha256(response),
                  required_legacy_pallas_sha256=library.twenty.PALLAS_LOCAL_SHA256,
                  installed=False, game_send_verified=False, invalid_authenticode_digest=True,
                  no_integrity_or_loader_bypass=True, new_imports=False,
                  limitations=["Native panel preview remains the FIRST bank only; no group indicator.",
                               "Only preview text is shortened; full local messages remain unchanged.",
                               "No character cap is NOT a bypass of server limits or a game-safety guarantee.",
                               "Own-process tests never execute Tencent's controller/parser/sender.",
                               "Profile-pinned local experiment, not a portable/shareable release."])
    library.twenty.write_new(out / "manifest.json", library.twenty.compact(report))
    if args.seed_library.read_bytes() != seed_bytes:
        raise ValueError("Active seed changed during offline preparation.")
    print(json.dumps(dict(output=str(out), candidate_dll_sha256=report["candidate_dll_sha256"], metrics=metrics)))


if __name__ == "__main__":
    main()
