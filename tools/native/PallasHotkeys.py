"""Offline 64 KiB / independent-hotkey candidate. Never installs or loads DLLs."""
from __future__ import annotations
import argparse
import base64
import importlib.util
import json
from pathlib import Path
import re
import struct
import subprocess

spec = importlib.util.spec_from_file_location("library", Path(__file__).with_name("PallasLibrary.py"))
lib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lib)
t = lib.twenty
BASE = t.BASE
CAPACITY = 65536
MAX_COUNT = 512
KEYBOARD_VA = 0x1800424C4
KEYS = {**{str(i): 0x30 + i for i in range(10)},
        **{chr(i): i for i in range(0x41, 0x5B)},
        **{f"F{i}": 0x6F + i for i in range(1, 25)},
        **{f"NUMPAD{i}": 0x60 + i for i in range(10)},
        "PAGEUP": 0x21, "PAGEDOWN": 0x22, "END": 0x23, "HOME": 0x24,
        "LEFT": 0x25, "UP": 0x26, "RIGHT": 0x27, "DOWN": 0x28,
        "INSERT": 0x2D, "DELETE": 0x2E}
MODS = {"CTRL": 1, "ALT": 2, "SHIFT": 4, "~": 8}

def binding(text):
    if not isinstance(text, str): raise ValueError("Hotkey must be text.")
    parts = [x.strip().upper() for x in text.split("+")]
    if len(parts) < 2 or parts[-1] not in KEYS:
        raise ValueError("Use modifiers + a primary key, e.g. Ctrl+Alt+Q or ~+F1.")
    mask = 0
    for part in parts[:-1]:
        if part not in MODS or mask & MODS[part]: raise ValueError("Unknown/duplicate modifier.")
        mask |= MODS[part]
    vk = KEYS[parts[-1]]
    if (mask & 2 and vk == 0x73) or (mask & 3 == 3 and vk == 0x2E):
        raise ValueError("System-reserved shortcut is forbidden.")
    label = "+".join([name for name, bit in (("Ctrl", 1), ("Alt", 2), ("Shift", 4), ("~", 8))
                      if mask & bit] + [parts[-1]])
    return vk, mask, label

def check_text(text):
    if not isinstance(text, str) or not text.strip(): raise ValueError("Nonempty text required.")
    raw = text.encode("utf-8", errors="strict")
    units = len(text.encode("utf-16-le", errors="strict")) // 2
    if units > 50 or re.search(r"[\x00-\x1F\x7F]", text):
        raise ValueError("Precautionary 50 UTF-16-unit/control-character guard.")
    return raw

def artifacts(scheme):
    if not isinstance(scheme, dict) or type(scheme.get("version")) is not int or scheme["version"] != 2:
        raise ValueError("Expected version 2 flat JSON.")
    count = scheme.get("count")
    if type(count) is not int or not 1 <= count <= MAX_COUNT: raise ValueError("Message count must be 1..512.")
    expected = {"version", "title", "count"} | {str(i) for i in range(count)} | {f"bind{i}" for i in range(count)}
    if scheme.keys() != expected: raise ValueError("Missing/extra exact fields.")
    check_text(scheme["title"])
    canonical = dict(version=2, title=scheme["title"], count=count)
    data = bytearray(b"LPSKEY2\0" + bytes(4) + struct.pack("<I", count))
    seen = set()
    for i in range(count):
        raw = check_text(scheme[str(i)])
        vk, mods, label = binding(scheme[f"bind{i}"])
        if (vk, mods) in seen: raise ValueError(f"Duplicate shortcut at message {i + 1}: {label}")
        seen.add((vk, mods))
        canonical[str(i)] = scheme[str(i)]; canonical[f"bind{i}"] = label
        data.extend(struct.pack("<HHI", vk, mods, len(raw)) + raw + b"\0")
    if len(data) > CAPACITY: raise ValueError(f"Library uses {len(data)} / {CAPACITY} bytes. Nothing truncated.")
    struct.pack_into("<I", data, 8, len(data))
    token = f"{len(data):08X}:{lib.fnv1a(data):08X}"
    short = t.compact({"_lps_keys_v2": token, **{str(i): "" for i in range(20)},
                       "title": "LOCAL HOTKEYS: USE LOCAL EDITOR", "key": 1})
    if len(short) > 2046: raise ValueError("Unchanged transport overflow.")
    response = t.compact({"result": {"error_code": 0}, "shout_message": base64.b64encode(short).decode()})
    return bytes(data), response, canonical, dict(library_bytes=len(data), capacity_bytes=CAPACITY,
        message_count=count, max_message_count=MAX_COUNT, single_message_utf16_units=50,
        bootstrap_bytes=len(short), transport_unchanged_bytes=2046, token=token)

def link_split(obj, base, code_rva, data_rva, externals):
    coff = lib.Coff(obj, allow_writable=True)
    code, data, positions = bytearray(), bytearray(), {}
    for i, section in enumerate(coff.sections, 1):
        if section["name"] == ".debug$S": continue
        writable = section["name"] in (".data", ".bss")
        content, rva = (data, data_rva) if writable else (code, code_rva)
        at = lib.align(len(content), section["align"])
        content.extend(bytes(at - len(content))); content.extend(section["data"])
        positions[i] = (writable, at, rva)
    symbols = {}
    for i, symbol in coff.symbols.items():
        if symbol["section"] > 0 and symbol["section"] in positions:
            _, at, rva = positions[symbol["section"]]
            symbols[i] = base + rva + at + symbol["value"]
        elif symbol["section"] == 0 and symbol["name"] in externals:
            symbols[i] = externals[symbol["name"]]
    for i, section in enumerate(coff.sections, 1):
        if i not in positions: continue
        writable, pos, rva = positions[i]
        content = data if writable else code
        for offset, symbol, kind in section["relocs"]:
            if symbol not in symbols or offset + 4 > len(section["data"]):
                name = coff.symbols.get(symbol, {}).get("name")
                raise ValueError(f"Unresolved/bad relocation: {name}")
            at = pos + offset
            addend = struct.unpack_from("<i", content, at)[0]
            if 4 <= kind <= 9:
                struct.pack_into("<i", content, at, symbols[symbol] + addend - (base + rva + at + kind))
            elif kind == 3:
                struct.pack_into("<I", content, at, symbols[symbol] + addend - base)
            else: raise ValueError(f"Unsupported relocation {kind}; no absolute-ASLR guesses.")
    exports = {s["name"]: symbols[i] for i, s in coff.symbols.items() if i in symbols and s["section"] > 0}
    pdata = b"".join(code[positions[i][1]:positions[i][1] + len(s["data"])]
                     for i, s in enumerate(coff.sections, 1) if s["name"] == ".pdata")
    return code, data, exports, pdata

def patch(original, obj, existing_imports=None):
    existing, _ = t.patch_copy(original)
    lib.verify_imports(original)
    pe = t.PE64(existing)
    header = struct.unpack_from("<I", existing, 0x3C)[0]; optional = header + 24
    if struct.unpack_from("<I", existing, optional + 56)[0] != 0x190000: raise ValueError("PE geometry changed.")
    # Stable separated addresses with >128 KiB space for code/unwind metadata.
    code_rva, data_rva = 0x190000, 0x1B0000
    coff = lib.Coff(obj, allow_writable=True)
    writable_size = 0
    for s in coff.sections:
        if s["name"] in (".data", ".bss"):
            writable_size = lib.align(writable_size, s["align"]) + len(s["data"])
    iat_offset = lib.align(writable_size, 8)
    extra_names = ("GetAsyncKeyState", "GetForegroundWindow")
    externals = {name: BASE + rva for name, rva in lib.IMPORT_RVAS.items()}
    externals.update({name: BASE + rva for name, rva in (existing_imports or {}).items()})
    externals.update(copy_string=lib.COPY_STRING, original_send=t.SENDER_VA)
    externals.update({"__imp_" + name: BASE + data_rva + iat_offset + i * 8 for i, name in enumerate(extra_names)})
    code, data, exports, new_pdata = link_split(obj, BASE, code_rva, data_rva, externals)
    if len(data) != writable_size: raise ValueError("Writable layout mismatch.")
    required = ("ReadLocalScheme", "CustomKeyboard", "SendNonempty")
    if any(name not in exports for name in required): raise ValueError("Missing C exports.")
    old_at = pe.offset(BASE + pe.exception_rva, pe.exception_size)
    records = [existing[p:p + 12] for p in range(old_at, old_at + pe.exception_size, 12)]
    if not new_pdata or len(new_pdata) % 12: raise ValueError("Malformed unwind table.")
    records += [new_pdata[i:i + 12] for i in range(0, len(new_pdata), 12)]
    records.sort(key=lambda row: struct.unpack_from("<I", row)[0])
    for i, row in enumerate(records):
        begin, end, unwind = struct.unpack("<III", row)
        if begin >= end or (i and struct.unpack_from("<I", records[i - 1], 4)[0] > begin):
            raise ValueError("Invalid/overlapping unwind table.")
    while len(code) % 4: code.append(0)
    pdata_offset = len(code); code.extend(b"".join(records))
    # Append a normal USER32 import descriptor. Existing import/IAT bytes stay
    # unchanged. These APIs read keyboard state/focus, not any game's memory.
    old_import_rva, old_import_size = struct.unpack_from("<II", existing, optional + 112 + 8)
    old_import_at = pe.offset(BASE + old_import_rva, old_import_size)
    descriptors = bytearray(); cursor = old_import_at
    while any(existing[cursor:cursor + 20]):
        descriptors.extend(existing[cursor:cursor + 20]); cursor += 20
    while len(code) % 8: code.append(0)
    import_offset = len(code); code.extend(descriptors + bytes(40))
    lookup_rva = code_rva + len(code); lookup_at = len(code); code.extend(bytes(24))
    dll_name_rva = code_rva + len(code); code.extend(b"USER32.dll\0")
    data.extend(bytes(iat_offset - len(data)) + bytes(24))
    for i, name in enumerate(extra_names):
        while len(code) % 2: code.append(0)
        name_rva = code_rva + len(code); code.extend(bytes(2) + name.encode() + b"\0")
        struct.pack_into("<Q", code, lookup_at + i * 8, name_rva)
        struct.pack_into("<Q", data, iat_offset + i * 8, name_rva)
    struct.pack_into("<IIIII", code, import_offset + len(descriptors), lookup_rva, 0, 0,
                     dll_name_rva, data_rva + iat_offset)
    if code_rva + len(code) > data_rva: raise ValueError("RX/RW sections overlap.")
    new_header = pe.sections[-1]["header"] + 40
    if new_header + 80 > min(s["raw"] for s in pe.sections) or existing[new_header:new_header + 80] != bytes(80):
        raise ValueError("No verified section-header slots.")
    cert_at, cert_size = pe.certificate_offset, pe.certificate_size
    if cert_at + cert_size != len(existing) or cert_at < max(s['raw'] + s['raw_size'] for s in pe.sections):
        raise ValueError("Unexpected overlay/certificate layout.")
    patched = bytearray(existing[:cert_at])
    sections = []
    for name, rva, content, flags in ((b".lpsv2", code_rva, code, 0x60000020),
                                      (b".lpscfg", data_rva, data, 0xC0000040)):
        raw_at = lib.align(len(patched), 512); raw_size = lib.align(len(content), 512)
        patched.extend(bytes(raw_at - len(patched)) + content + bytes(raw_size - len(content)))
        struct.pack_into("<8sIIIIIIHHI", patched, new_header + 40 * len(sections), name,
                         len(content), rva, raw_size, raw_at, 0, 0, 0, 0, flags)
        sections.append(dict(name=name.decode(), rva=rva, raw=raw_at, size=len(content), flags=flags))
    new_cert = len(patched); patched.extend(existing[cert_at:])
    struct.pack_into("<H", patched, header + 6, len(pe.sections) + 2)
    for off, added in ((4, lib.align(len(code), 512)), (8, lib.align(len(data), 512))):
        struct.pack_into("<I", patched, optional + off, struct.unpack_from("<I", patched, optional + off)[0] + added)
    struct.pack_into("<I", patched, optional + 56, lib.align(data_rva + len(data), 4096))
    struct.pack_into("<II", patched, optional + 112 + 8, code_rva + import_offset, len(descriptors) + 40)
    struct.pack_into("<II", patched, optional + 112 + 3 * 8, code_rva + pdata_offset, len(records) * 12)
    struct.pack_into("<II", patched, optional + 112 + 4 * 8, new_cert, cert_size)
    # A discontiguous new IAT cannot be described by the old single range.
    # Windows resolves IATs from descriptors; clear optional IAT directory.
    struct.pack_into("<II", patched, optional + 112 + 12 * 8, 0, 0)
    hooks = []
    for va, before, opcode, target in (
        (lib.RECEIVE_CALL, b"\xE8" + struct.pack("<i", lib.COPY_STRING - lib.RECEIVE_CALL - 5), 0xE8, exports["ReadLocalScheme"]),
        (KEYBOARD_VA, bytes.fromhex("48895c2408"), 0xE9, exports["CustomKeyboard"]),
        (t.BODY_VA + 0x2C, b"\xE8" + struct.pack("<i", t.SENDER_VA - (t.BODY_VA + 0x2C) - 5), 0xE8, exports["SendNonempty"])):
        at = pe.offset(va, 5)
        if existing[at:at + 5] != before: raise ValueError("Unknown hook bytes.")
        after = bytes([opcode]) + struct.pack("<i", target - va - 5)
        patched[at:at + 5] = after
        hooks.append(dict(va=hex(va), file_offset=at, before_hex=before.hex(), after_hex=after.hex()))
    for s in pe.sections:
        if s["name"] != b".text" and patched[s['raw']:s['raw'] + s['raw_size']] != existing[s['raw']:s['raw'] + s['raw_size']]:
            raise ValueError("Original non-code section changed.")
    return bytes(patched), dict(sections=sections, entry_points={k: hex(exports[k]) for k in required},
        hooks=hooks, added_unwind_records=len(new_pdata) // 12, unwind_record_count=len(records),
        added_public_imports=list(extra_names), certificate_file_offset=new_cert,
        iat_offset=iat_offset, code_rva=code_rva, data_rva=data_rva)

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--scheme", type=Path, required=True); p.add_argument("--out-dir", type=Path, required=True)
    p.add_argument("--clang", type=Path, default=Path(r"D:\LLVM\bin\clang.exe"))
    args = p.parse_args(); root = Path(__file__).resolve().parents[2]; out = args.out_dir.resolve()
    if root / "build" not in out.parents or out.exists(): raise ValueError("Use a NEW build subdirectory.")
    original = (root / "engine/assets/TenPallas.original.dll").read_bytes()
    raw, response, canonical, metrics = artifacts(t.read_scheme(args.scheme))
    out.mkdir(parents=True, exist_ok=False); obj = out / "hotkeys2.obj"; source = Path(__file__).with_name("hotkeys2.c")
    subprocess.run([str(args.clang), "--target=x86_64-pc-windows-msvc", "-Os", "-ffreestanding", "-fno-builtin",
        "-fno-stack-protector", "-fno-ident", "-fno-addrsig", "-funwind-tables", "-g0", "-c", str(source), "-o", str(obj)],
        check=True, capture_output=True, text=True)
    candidate, native = patch(original, obj.read_bytes())
    for name, data in (("TenPallas.hotkeys.experimental.dll", candidate), ("hotkeys-v2.bin", raw),
                       ("local-response.hotkeys.json", response), ("messages.canonical.json", t.compact(canonical))):
        t.write_new(out / name, data)
    report = dict(experiment="local-hotkeys-v2", candidate_dll_sha256=t.sha256(candidate),
        source_dll_sha256=t.sha256(original), c_source_sha256=t.sha256(source.read_bytes()),
        library_sha256=t.sha256(raw), response_sha256=t.sha256(response), metrics=metrics, native=native,
        installed=False, game_send_verified=False, invalid_authenticode_digest=True,
        no_integrity_bypass=True, transport_unchanged=True)
    t.write_new(out / "manifest.json", json.dumps(report, indent=2).encode())
    print(json.dumps(report))

if __name__ == "__main__": main()
