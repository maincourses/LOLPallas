#!/usr/bin/env python3
"""OFFLINE ONLY: build a pinned Pallas twenty-message experiment.

No installer, DLL loading, game input, process access, network or cloud writes.
The candidate DLL has an INVALID Authenticode digest. Never bypass validation
or anti-cheat if the normal WeGame loader refuses it.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import struct
import sys

DLL_SHA256 = "97ba57fd47a393a3a4bbfa684d0f03d10cf04344fbd99cb2d2e8626675be9c94"
DLL_SIZE = 1626152
PALLAS_LOCAL_SHA256 = "803870e3fda683443471e835699b065293724dc7e0f3289d0093fc84c8e30935"
DEFAULT_DLL = Path(r"D:\Program Files (x86)\WeGame\apps\Pallas\tp_deps\TenPallas.dll")
DEFAULT_PALLAS = DEFAULT_DLL.parent.parent / "pallas.exe"
BASE = 0x180000000
BODY_VA = 0x18004253B
HELPER_VA = 0x1800FBAC0
EVENT_HELPER_VA = 0x1800FBAF0
SENDER_VA = 0x180019F98
MAX_UTF16 = 50  # Experiment guard, NOT a measured game-side message limit.
MAX_JSON_BYTES = 2046  # Existing Pallas fixed whole-scheme transfer buffer.

# Generated and independently checked against the four accompanying ASM files.
# Relative CALL operands are filled below; the local branches are already fixed.
KEYBOARD_BODY = bytes.fromhex(
    "e80000000085c0784a89cf89c148c1e10548034b40483b4b487338"
    "c683930000000148837918107203488b09e800000000ff44bbd8eb1c"
    "9090909090909039c27511e80000000085c07808c683930000000090")
NORMALIZER = bytes.fromhex(
    "498d40d04883f809761b498d40904883f80977158d480183f90a"
    "750231c98d410a83c130c34489c1c383c8ffc3")
EVENT_NORMALIZER = bytes.fromhex(
    "4983f879751c81fa04010000740f81fa05010000750cba01010000"
    "eb05ba000100008a8191000000c3")
RECEIVER_INDEX = bytes.fromhex(
    "83ff0975054531c0eb0b83ff13750641b80a00000090909090904963c8")
ORIGINAL_BODY = bytes.fromhex(
    "498d40d04883f8097749418d40d0c683930000000183f80977394963f8"
    "488d4fd048c1e10548034b4048837918107203488b09e8257afdff"
    "ff44bbd8eb153bd07511498d40d04883f809770744888b93000000")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def compact(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"),
                      allow_nan=False).encode("utf-8")


def unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON key: " + key)
        result[key] = value
    return result


def utf16_length(text: str) -> int:
    return len(text.encode("utf-16-le")) // 2


def read_scheme(path: Path) -> object:
    return json.loads(path.read_text(encoding="utf-8-sig"),
                      object_pairs_hook=unique_object)


def make_response(value: object) -> tuple[bytes, dict]:
    if not isinstance(value, dict) or set(value) != {
            "title", "key", *(str(i) for i in range(20))}:
        raise ValueError("Exactly title, key and message keys 0..19 are required.")
    if type(value["key"]) is not int or value["key"] not in (1, 2):
        raise ValueError("key must be integer 1 (~) or 2 (Ctrl).")
    title = value["title"]
    messages = [value[str(i)] for i in range(20)]
    for label, text in [("title", title), *enumerate(messages, 1)]:
        if not isinstance(text, str) or not text.strip():
            raise ValueError(f"{label}: a nonempty string is required.")
        if utf16_length(text) > MAX_UTF16:
            raise ValueError(f"{label}: this experiment allows at most {MAX_UTF16} "
                             "UTF-16 units; nothing was truncated.")
        if any(ord(c) < 32 or ord(c) == 127 for c in text):
            raise ValueError(f"{label}: control characters are not supported.")
    ordered = {str(i): messages[i] for i in range(20)}
    ordered.update(title=title, key=value["key"])
    raw = compact(ordered)
    if len(raw) > MAX_JSON_BYTES:
        raise ValueError(f"All twenty messages plus metadata use {len(raw)} UTF-8 "
                         f"bytes; the unchanged transport permits {MAX_JSON_BYTES}.")
    response = compact({"result": {"error_code": 0},
                        "shout_message": base64.b64encode(raw).decode("ascii")})
    return response, {
        "message_count": 20, "scheme_json_utf8_bytes": len(raw),
        "native_whole_scheme_limit": MAX_JSON_BYTES,
        "experimental_per_message_utf16_guard": MAX_UTF16,
        "guard_is_not_a_measured_game_limit": True,
        "message_utf16_units": [utf16_length(x) for x in messages],
        "message_utf8_bytes": [len(x.encode("utf-8")) for x in messages],
        "panel_key": value["key"], "response_bytes": len(response),
    }


class PE64:
    def __init__(self, data: bytes):
        if data[:2] != b"MZ":
            raise ValueError("Not a PE file.")
        self.data = data
        pe = struct.unpack_from("<I", data, 0x3C)[0]
        if data[pe:pe + 4] != b"PE\0\0":
            raise ValueError("Invalid PE signature.")
        machine, count = struct.unpack_from("<HH", data, pe + 4)
        optional = pe + 24
        if machine != 0x8664 or struct.unpack_from("<H", data, optional)[0] != 0x20B:
            raise ValueError("Only the inspected x64 PE32+ DLL is supported.")
        self.base = struct.unpack_from("<Q", data, optional + 24)[0]
        if self.base != BASE:
            raise ValueError("Unexpected preferred image base.")
        table = optional + struct.unpack_from("<H", data, pe + 20)[0]
        self.sections = []
        for i in range(count):
            at = table + i * 40
            virtual_size, rva, raw_size, raw = struct.unpack_from("<IIII", data, at + 8)
            self.sections.append({"name": data[at:at + 8].rstrip(b"\0"),
                                  "header": at, "virtual_size": virtual_size,
                                  "rva": rva, "raw_size": raw_size, "raw": raw})
        self.exception_rva, self.exception_size = struct.unpack_from(
            "<II", data, optional + 112 + 3 * 8)
        self.certificate_offset, self.certificate_size = struct.unpack_from(
            "<II", data, optional + 112 + 4 * 8)

    def offset(self, va: int, size: int) -> int:
        rva = va - self.base
        for section in self.sections:
            delta = rva - section["rva"]
            if 0 <= delta and delta + size <= section["raw_size"]:
                pos = section["raw"] + delta
                if pos + size <= len(self.data):
                    return pos
        raise ValueError(f"Unmapped file-backed range: {va:#x}, {size}.")


def relative_call(code: bytearray, offset: int, origin: int, target: int) -> None:
    if code[offset] != 0xE8:
        raise ValueError("CALL relocation did not point to an E8 instruction.")
    struct.pack_into("<i", code, offset + 1, target - (origin + offset + 5))


def keyboard_body(origin: int = BODY_VA, helper: int = HELPER_VA,
                  sender: int = SENDER_VA) -> bytes:
    code = bytearray(KEYBOARD_BODY)
    relative_call(code, 0, origin, helper)
    relative_call(code, 0x2C, origin, sender)
    relative_call(code, 0x42, origin, helper)
    return bytes(code)


def patch_copy(original: bytes) -> tuple[bytes, list[dict]]:
    if len(original) != DLL_SIZE or sha256(original) != DLL_SHA256:
        raise ValueError("TenPallas version/hash mismatch; refusing this DLL.")
    pe = PE64(original)
    text = next(s for s in pe.sections if s["name"] == b".text")
    start = HELPER_VA - BASE - text["rva"]
    final_size = EVENT_HELPER_VA - BASE - text["rva"] + len(EVENT_NORMALIZER)
    if (start < text["virtual_size"] or final_size > text["raw_size"]
            or HELPER_VA + len(NORMALIZER) > EVENT_HELPER_VA
            or text["virtual_size"] != 0xFAAA9):
        raise ValueError("Unexpected executable padding or .text geometry.")
    # Both helpers are stackless leaves, so they need no unwind entries. Native
    # callback prologue/epilogue bytes and existing .pdata/.xdata are preserved.
    exc = pe.offset(BASE + pe.exception_rva, pe.exception_size)
    unwind = None
    for at in range(exc, exc + pe.exception_size, 12):
        begin, end, info = struct.unpack_from("<III", original, at)
        if begin == 0x424C4:
            if end != 0x42599:
                raise ValueError("Unexpected keyboard callback extent.")
            unwind = pe.offset(BASE + info, 12)
    if unwind is None or original[unwind:unwind + 12] != bytes.fromhex(
            "010a04000a3406000a320670"):
        raise ValueError("Unexpected keyboard unwind record.")
    event_call = bytearray(bytes.fromhex("e80000000090"))
    relative_call(event_call, 0, 0x1800424CE, EVENT_HELPER_VA)
    specs = [
        ("initial-vector-twenty", 0x180041EB4, bytes.fromhex("ba0a000000"),
         bytes.fromhex("ba14000000")),
        ("received-vector-twenty", 0x1800422CB, bytes.fromhex("418d570a"),
         bytes.fromhex("418d5714")),
        ("received-json-keys-0-to-19", 0x1800422DC, bytes.fromhex("83ff0a"),
         bytes.fromhex("83ff14")),
        ("two-bank-receive-index", 0x1800423B3,
         bytes.fromhex("b86766666641f7e8c1fa028bcac1e91f03d18d0c9203c9442bc14963c8"),
         RECEIVER_INDEX),
        ("twenty-key-down-and-up", BODY_VA, ORIGINAL_BODY, keyboard_body()),
        ("stackless-key-normalizer", HELPER_VA, bytes(len(NORMALIZER)), NORMALIZER),
        ("f10-system-event-entry-hook", 0x1800424CE,
         bytes.fromhex("8a8191000000"), bytes(event_call)),
        ("stackless-f10-event-normalizer", EVENT_HELPER_VA,
         bytes(len(EVENT_NORMALIZER)), EVENT_NORMALIZER),
    ]
    patched = bytearray(original)
    changes = []

    def replace(name: str, at: int, before: bytes, after: bytes, va: int | None) -> None:
        if len(before) != len(after) or original[at:at + len(before)] != before:
            raise ValueError("Unexpected fixed-range bytes: " + name)
        patched[at:at + len(after)] = after
        changes.append({"name": name, "va": hex(va) if va is not None else None,
                        "file_offset": at, "before_hex": before.hex(),
                        "after_hex": after.hex()})

    for name, va, before, after in specs:
        replace(name, pe.offset(va, len(before)), before, after, va)
    replace("text-virtual-size-include-leaf-helper", text["header"] + 8,
            struct.pack("<I", text["virtual_size"]),
            struct.pack("<I", final_size), None)
    restored = bytearray(patched)
    for change in changes:
        at = change["file_offset"]
        before = bytes.fromhex(change["before_hex"])
        restored[at:at + len(before)] = before
    if restored != original:
        raise ValueError("Inverse verification found changes outside the manifest.")
    if patched[exc:exc + pe.exception_size] != original[exc:exc + pe.exception_size]:
        raise ValueError("Exception directory unexpectedly changed.")
    cert = slice(pe.certificate_offset, pe.certificate_offset + pe.certificate_size)
    if not pe.certificate_size or patched[cert] != original[cert]:
        raise ValueError("Certificate bytes unexpectedly changed.")
    return bytes(patched), changes


def write_new(path: Path, content: bytes) -> None:
    with path.open("xb") as stream:
        stream.write(content)
    if path.read_bytes() != content:
        raise ValueError("Artifact readback mismatch: " + str(path))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scheme", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True,
                        help="A NEW offline output directory outside live installation/runtime paths.")
    parser.add_argument("--source", type=Path, default=DEFAULT_DLL)
    parser.add_argument("--pallas-source", type=Path, default=DEFAULT_PALLAS)
    parser.add_argument("--compile-only", action="store_true",
                        help="Only validate/compile twenty-message JSON; no DLL is read or produced.")
    args = parser.parse_args()
    scheme = read_scheme(args.scheme)
    response, metrics = make_response(scheme)
    out, source, pallas = args.out_dir.resolve(), args.source.resolve(), args.pallas_source.resolve()
    runtime = Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "PallasCustomShout"
    forbidden = [DEFAULT_DLL.parents[3].resolve(), source.parent,
                 pallas.parent, runtime.resolve()]
    if any(out == root or root in out.parents for root in forbidden):
        raise ValueError("Offline output cannot be inside live/source/runtime directories.")
    if out.exists():
        raise ValueError("Output already exists; never overwriting a config or prior backup.")
    original = candidate = local_exe = None
    changes = []
    if not args.compile_only:
        local_exe = pallas.read_bytes()
        if sha256(local_exe) != PALLAS_LOCAL_SHA256:
            raise ValueError("This experiment requires the already-verified local-file Pallas loader.")
        original = source.read_bytes()
        candidate, changes = patch_copy(original)
    manifest = {
        "experiment": "Twenty simultaneous messages v2 with F10 system events; OFFLINE, NOT INSTALLED",
        "metrics": metrics, "source_dll": str(source) if original is not None else None,
        "original_dll_sha256": sha256(original) if original is not None else None,
        "candidate_dll_sha256": sha256(candidate) if candidate is not None else None,
        "required_local_pallas_sha256": PALLAS_LOCAL_SHA256,
        "response_sha256": sha256(response), "changes": changes,
        "changed_byte_count": sum(a != b for a, b in zip(original, candidate))
                              if original is not None else 0,
        "hotkeys": {"messages_1_to_10": "panel key + main digits 1..9,0",
                    "messages_11_to_20": "panel key + F1..F10"},
        "native_panel_visible_messages": 10,
        "statistics": "Original ten counters retained; paired keys aggregate; packet unchanged.",
        "signature": "Candidate DLL Authenticode digest INVALID; certificate bytes retained."
                     if candidate is not None else "No executable/DLL produced.",
        "no_integrity_or_anti_cheat_bypass": True,
        "installed": False, "runtime_verified": False, "game_send_verified": False,
        "live_files_modified": False,
        "limitations": ["Version-specific and local-user-specific loader prerequisite.",
                        "First native panel still lists only ten messages.",
                        "Current whole-scheme transport remains 2046 UTF-8 bytes.",
                        "Short-text guards are precautionary, not proof of game limits.",
                        "WeGame may reject/replace the candidate or conflict with F-key bindings.",
                        "No support for bypassing validation if loading is refused.",
                        "No installation or real game send has been verified."],
    }
    out.mkdir(parents=True, exist_ok=False)
    write_new(out / "scheme20.json", json.dumps(scheme, ensure_ascii=False, indent=2).encode("utf-8"))
    write_new(out / "local-response20.json", response)
    if candidate is not None:
        write_new(out / "TenPallas.original.dll", original)
        write_new(out / "TenPallas.twenty.experimental.dll", candidate)
        if source.read_bytes() != original or pallas.read_bytes() != local_exe:
            raise ValueError("Live source changed during the OFFLINE build; nothing installed.")
    write_new(out / "manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2).encode("utf-8"))
    print("OFFLINE ONLY; NOT INSTALLED:", out)
    print("Metrics:", json.dumps(metrics, ensure_ascii=True))
    print("Real DLL loading and game sending remain UNVERIFIED.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, UnicodeError, struct.error) as exc:
        print("ERROR:", exc, file=sys.stderr)
        raise SystemExit(1)
