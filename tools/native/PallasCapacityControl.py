"""OFFLINE capacity-only 64 KiB control of the verified legacy 8 KiB pair.

Builds both variants from the same C source. Requires the 8 KiB result to match
the game-tested DLL and permits ONLY the two immediate operands implementing
2 <= length <= capacity to differ. No installer, game access, DLL loading or IO
to live paths. The profile-specific legacy loader and JSON protocol are retained.
"""
from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path
import struct
import subprocess

import PallasLibrary as library

BASELINE_SHA256 = "beb422999a6e8e7f87d93937d9010b15dcaaacce237fd7b11c280d5cf88cca10"
CAPACITY = 65536
# Clang's unsigned range check: (length - (capacity + 1)) <= -capacity
# rejects length < 2 or length > capacity. The lower bound remains unchanged.
RANGE_CHECK_OFFSET = 0xDB


def range_check(capacity):
    return (bytes.fromhex("418d8424") + struct.pack("<I", -(capacity + 1) & 0xFFFFFFFF)
            + b"\x3D" + struct.pack("<I", -capacity & 0xFFFFFFFF))


def verify_capacity_only(baseline, candidate, baseline_info, candidate_info):
    if library.twenty.sha256(baseline) != BASELINE_SHA256:
        raise ValueError("The 8 KiB build does not reproduce the game-tested baseline.")
    if len(candidate) != len(baseline) or candidate_info != baseline_info:
        raise ValueError("Capacity changed PE layout, hooks or unwind metadata.")
    pe = library.twenty.PE64(baseline)
    entry = int(baseline_info["entry_points"]["ReadLocalScheme"], 16)
    at = pe.offset(entry + RANGE_CHECK_OFFSET, 13)
    before, after = range_check(8192), range_check(CAPACITY)
    if baseline[at:at + 13] != before or candidate[at:at + 13] != after:
        raise ValueError("Unexpected compiled range check; no guessed binary offsets.")
    expected = bytearray(baseline)
    expected[at:at + 13] = after
    if candidate != expected:
        raise ValueError("Found changes outside the capacity-check immediate operands.")
    changed = [{"file_offset": i, "before_hex": f"{a:02x}", "after_hex": f"{b:02x}"}
               for i, (a, b) in enumerate(zip(baseline, candidate)) if a != b]
    return dict(changed_byte_count=len(changed), changed_bytes=changed,
                range_check_va=hex(entry + RANGE_CHECK_OFFSET), range_check_file_offset=at,
                range_check_before_hex=before.hex(), range_check_after_hex=after.hex(),
                identical_outside_capacity_check=True, identical_pe_geometry=True,
                original_keyboard_callback_unchanged_from_working_8k=True,
                imports_and_unwind_unchanged_from_working_8k=True,
                no_new_writable_section=True)


def padded_artifacts(scheme, size):
    """Valid legacy twenty-entry JSON padded with whitespace, NOT more messages.

    Padding exercises the reader's byte limit without changing any string,
    schema, key, length guard or parser meaning. Never installs these fixtures.
    """
    raw, response, metrics = library.artifacts(scheme)
    if type(size) is not int or not len(raw) <= size <= CAPACITY + 1:
        raise ValueError("Unexpected capacity fixture size.")
    raw += b" " * (size - len(raw))
    if json.loads(raw, object_pairs_hook=library.twenty.unique_object) != scheme:
        raise ValueError("Padding changed JSON semantics.")
    envelope = json.loads(response)
    preview = json.loads(base64.b64decode(envelope["shout_message"], validate=True))
    preview["_lps_local_v1"] = f"{size:08X}:{library.fnv1a(raw):08X}"
    short = library.twenty.compact(preview)
    if len(short) != metrics["bootstrap_json_utf8_bytes"] or len(short) > 2046:
        raise ValueError("Legacy bootstrap geometry changed.")
    envelope["shout_message"] = base64.b64encode(short).decode("ascii")
    return raw, library.twenty.compact(envelope)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scheme", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--clang", type=Path, default=Path(r"D:\LLVM\bin\clang.exe"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    out = args.out_dir.resolve()
    if root / "build" not in out.parents or out.exists():
        raise ValueError("Use a NEW offline project build directory; never live paths.")
    original = args.source.read_bytes()
    pinned = args.baseline.read_bytes()
    if library.twenty.sha256(original) != library.twenty.DLL_SHA256:
        raise ValueError("Unknown original DLL version.")
    if library.twenty.sha256(pinned) != BASELINE_SHA256:
        raise ValueError("Unknown baseline; requires the verified 8 KiB DLL.")
    scheme = library.twenty.read_scheme(args.scheme)
    raw, response, metrics = library.artifacts(scheme)
    out.mkdir(parents=True, exist_ok=False)
    c_path = Path(__file__).with_name("library20.c")
    commands, results = {}, {}
    for capacity in (8192, CAPACITY):
        object_path = out / ("baseline8k.obj" if capacity == 8192 else "library20.obj")
        command = [str(args.clang), "--target=x86_64-pc-windows-msvc", "-Os", "-ffreestanding",
                   "-fno-builtin", "-fno-stack-protector", "-fno-ident", "-fno-addrsig",
                   "-funwind-tables", "-g0", f"-DLPS_LIBRARY_CAPACITY={capacity}",
                   "-c", str(c_path), "-o", str(object_path)]
        subprocess.run(command, check=True, capture_output=True, text=True)
        object_bytes = object_path.read_bytes()
        dll, info = library.patch_library(original, object_bytes)
        commands[str(capacity)] = command
        results[capacity] = (dll, info, library.twenty.sha256(object_bytes))
    baseline, info8, _ = results[8192]
    candidate, info64, object_hash = results[CAPACITY]
    comparison = verify_capacity_only(baseline, candidate, info8, info64)
    if baseline != pinned:
        raise ValueError("The compiled baseline is not byte-identical to the verified artifact.")
    library.twenty.write_new(out / "TenPallas.baseline8k.dll", baseline)
    library.twenty.write_new(out / "TenPallas.library.experimental.dll", candidate)
    library.twenty.write_new(out / "library20-v1.json", raw)
    library.twenty.write_new(out / "local-response.library.json", response)
    fixture_dir = out / "fixtures"
    fixture_dir.mkdir()
    fixtures = []
    for size in (8192, 8193, 65535, 65536, 65537):
        content, packet = padded_artifacts(scheme, size)
        filename = f"library-{size}.json"
        library.twenty.write_new(fixture_dir / filename, content)
        library.twenty.write_new(fixture_dir / f"response-{size}.json", packet)
        fixtures.append(dict(filename=filename, bytes=size, sha256=library.twenty.sha256(content),
                             expected_8k_accept=size <= 8192, expected_64k_accept=size <= CAPACITY,
                             unchanged_twenty_messages=True, padding_only=True))
    metrics.update(library_limit=CAPACITY, compact_scheme_validation_limit=8192)
    report = dict(experiment="legacy-capacity-only-64k-control-v1",
        source_dll_sha256=library.twenty.sha256(original), baseline_8k_sha256=BASELINE_SHA256,
        baseline_twenty_sha256=library.OLD_TWENTY_HASH,
        candidate_dll_sha256=library.twenty.sha256(candidate),
        required_legacy_pallas_sha256=library.twenty.PALLAS_LOCAL_SHA256,
        c_source_sha256=library.twenty.sha256(c_path.read_bytes()), object_sha256=object_hash,
        library_sha256=library.twenty.sha256(raw), response_sha256=library.twenty.sha256(response),
        metrics=metrics, native=info64, comparison=comparison, compile_commands=commands,
        fixtures=fixtures, installed=False, runtime_verified=False, game_send_verified=False,
        baseline_game_verified_by_user=True, baseline_user_report_date="2026-10-05",
        invalid_authenticode_digest=True, no_loader_or_integrity_bypass=True,
        transport_unchanged=True, json_format="legacy _lps_local_v1 length/FNV JSON bootstrap",
        hotkeys="Unchanged native twenty-key callback: panel key + digits/F1..F10",
        limitations=["Local-user-specific legacy profile; not a portable release.",
                     "Twenty messages only; 50 UTF-16 units per entry including title.",
                     "First native panel displays ten rows as before.",
                     "Compact twenty-entry schemes generally fit below 8 KiB; padded fixtures only test reader capacity.",
                     "64 KiB actual loader, JSON parser and game sending remain unverified.",
                     "Do not install padded boundary fixtures or the newer independent-hotkey EXE."])
    library.twenty.write_new(out / "manifest.json", library.twenty.compact(report))
    if args.source.read_bytes() != original or args.baseline.read_bytes() != pinned:
        raise ValueError("An input binary changed during the offline build.")
    print(json.dumps(report, ensure_ascii=True))


if __name__ == "__main__":
    main()
