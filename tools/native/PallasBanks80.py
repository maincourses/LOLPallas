"""Build an OFFLINE four-bank Chinese library candidate; never install or send.

Version-pinned legacy loader/path/JSON, 64 KiB reader, original native key gate
and sender. Eighty message strings plus one legal SSO string for bank state.
This is local-user-specific and not a portable release or game-tested version.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import struct
import subprocess
import sys

import PallasCount80 as count

library = count.library
BASE = library.BASE
VECTOR_COUNT = count.COUNT + 1


def patch_banks(original, object_bytes):
    base, native = library.patch_library(original, object_bytes)
    portable = any(symbol["name"] == "__imp_SHGetFolderPathW" for symbol in library.Coff(object_bytes).symbols.values())
    imports = {**library.IMPORT_RVAS, **(library.PORTABLE_IMPORT_RVAS if portable else {})}
    externals = {name: BASE + rva for name, rva in imports.items()}
    externals.update(copy_string=library.COPY_STRING, original_send=library.twenty.SENDER_VA)
    _, exports, _, _ = library.Coff(object_bytes).link(BASE, native["new_section_rva"], externals)
    wrapper = exports["BankNormalizeWrapper"]
    pe = library.twenty.PE64(base)
    specs = [
        ("initial-vector-80-plus-one-owned-state", 0x180041EB4, bytes.fromhex("ba14000000"),
         b"\xBA" + struct.pack("<I", VECTOR_COUNT)),
        ("received-vector-80-plus-one-owned-state", 0x1800422CB, bytes.fromhex("418d5714"),
         bytes((0x41, 0x8D, 0x57, VECTOR_COUNT))),
        ("received-json-keys-0-to-79", 0x1800422DC, bytes.fromhex("83ff14"), bytes.fromhex("83ff50")),
        ("receive-index-all-eight-tens", 0x1800423B3, library.twenty.RECEIVER_INDEX, count.RECEIVER_MANY),
    ]
    for va in (library.twenty.BODY_VA, library.twenty.BODY_VA + 0x42):
        specs.append(("bank-wrapper-down" if va == library.twenty.BODY_VA else "bank-wrapper-up", va,
                      b"\xE8" + struct.pack("<i", library.twenty.HELPER_VA - va - 5),
                      b"\xE8" + struct.pack("<i", wrapper - va - 5)))
    candidate = bytearray(base)
    changes = []
    for name, va, before, after in specs:
        at = pe.offset(va, len(before))
        if len(before) != len(after) or base[at:at + len(before)] != before:
            raise ValueError("Unexpected fixed native bytes: " + name)
        candidate[at:at + len(after)] = after
        changes.append(dict(name=name, va=hex(va), file_offset=at, before_hex=before.hex(), after_hex=after.hex()))
    inverse = bytearray(candidate)
    for item in changes:
        at = item["file_offset"]; before = bytes.fromhex(item["before_hex"])
        inverse[at:at + len(before)] = before
    if inverse != base:
        raise ValueError("Bank/count changes outside declared native ranges.")
    native["bank_entry_points"] = {k: hex(exports[k]) for k in ("BankNormalize", "BankNormalizeWrapper")}
    return bytes(candidate), native, changes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed-library", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--clang", type=Path, default=Path(r"D:\LLVM\bin\clang.exe"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    out = args.out_dir.resolve()
    if root / "build" not in out.parents or out.exists():
        raise ValueError("Use a NEW offline project build directory; never live paths or prior builds.")
    seed_bytes = args.seed_library.read_bytes()
    baseline = args.baseline.read_bytes()
    original = args.source.read_bytes()
    if library.twenty.sha256(baseline) != count.BASELINE_HASH:
        raise ValueError("Requires the user-verified capacity-only legacy baseline.")
    if library.twenty.sha256(original) != library.twenty.DLL_SHA256:
        raise ValueError("Unknown original component version; nothing installed.")
    seed = json.loads(seed_bytes.decode("utf-8-sig"), object_pairs_hook=library.twenty.unique_object)
    scheme = count.make_scheme(seed)
    raw, response, metrics = count.artifacts(scheme)
    out.mkdir(parents=True, exist_ok=False)
    # Receive-only comparison remains separate and explicitly non-selectable.
    subprocess.run([sys.executable, str(Path(__file__).with_name("PallasCount80.py")),
                    "--seed-library", str(args.seed_library), "--baseline", str(args.baseline),
                    "--out-dir", str(out / "receive-control")], check=True, capture_output=True, text=True)
    c_path = Path(__file__).with_name("library80-banks.c")
    object_path = out / "library80-banks.obj"
    command = [str(args.clang), "--target=x86_64-pc-windows-msvc", "-Os", "-ffreestanding",
               "-fno-builtin", "-fno-stack-protector", "-fno-ident", "-fno-addrsig",
               "-funwind-tables", "-g0", "-Wall", "-Wextra", "-Werror", "-c", str(c_path), "-o", str(object_path)]
    subprocess.run(command, check=True, capture_output=True, text=True)
    object_bytes = object_path.read_bytes()
    candidate, native, changes = patch_banks(original, object_bytes)
    metrics.update(native_bound_message_count=80, bank_count=4, bank_size=20,
                   allocated_string_count=VECTOR_COUNT, reserved_state_strings=1)
    library.twenty.write_new(out / "scheme80.json", json.dumps(scheme, ensure_ascii=False, indent=2).encode("utf-8"))
    library.twenty.write_new(out / "library80.json", raw)
    library.twenty.write_new(out / "local-response80.json", response)
    library.twenty.write_new(out / "TenPallas.banks80.experimental.dll", candidate)
    report = dict(experiment="legacy-four-banks-real-chinese-100-offline-v1", metrics=metrics,
        baseline_dll_sha256=count.BASELINE_HASH, source_dll_sha256=library.twenty.sha256(original),
        candidate_dll_sha256=library.twenty.sha256(candidate), native=native, changes=changes,
        library_sha256=library.twenty.sha256(raw), response_sha256=library.twenty.sha256(response),
        seed_library_sha256=library.twenty.sha256(seed_bytes), object_sha256=library.twenty.sha256(object_bytes),
        c_source_sha256=library.twenty.sha256(c_path.read_bytes()), compile_command=command,
        required_legacy_pallas_sha256=library.twenty.PALLAS_LOCAL_SHA256,
        unchanged_loader_path_json_protocol_and_native_send=True,
        new_imports=False, writable_pe_section=False, panel_bank_display_updated=False,
        bank_previous="native panel key + PageUp", bank_next="native panel key + PageDown",
        initial_bank=1, bank_switch_wraps=True, bank_change_sends_message=False,
        installed=False, game_receive_verified=False, game_send_verified=False,
        invalid_authenticode_digest=True, no_integrity_or_loader_bypass=True,
        limitations=["OFFLINE only: no install tool, game input, game process access or message sending.",
                     "100-unit generator AND native UTF-8 send guard; NOT a measured safe game limit.",
                     "The unchanged native panel preview shows first-bank first ten, NOT current-bank text.",
                     "Four groups are selected internally, without a visible bank indicator yet.",
                     "Own-process tests do not execute Tencent's JSON parser/controller lifecycle/sender.",
                     "Local-user-specific path; personal first twenty texts must not be distributed.",
                     "If normal loader/integrity checks refuse this candidate, stop and restore; never bypass."])
    library.twenty.write_new(out / "manifest.json", library.twenty.compact(report))
    if (args.seed_library.read_bytes() != seed_bytes or args.baseline.read_bytes() != baseline or
        args.source.read_bytes() != original):
        raise ValueError("A source changed during offline preparation.")
    print(json.dumps(dict(output=str(out), metrics=metrics, candidate_dll_sha256=report["candidate_dll_sha256"],
                         installed=False, game_send_verified=False), ensure_ascii=True))


if __name__ == "__main__":
    main()
