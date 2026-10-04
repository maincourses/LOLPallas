"""Build ONLY an offline, profile/version-pinned local-library candidate.

Does not install/load a DLL, open a game process, inject, send or use a network.
Appends compiled C with unwind metadata; retains the existing transport size.
"""
from __future__ import annotations
import argparse
import importlib.util
import json
from pathlib import Path
import struct
import subprocess

spec = importlib.util.spec_from_file_location("twenty", Path(__file__).with_name("PallasTwenty.py"))
twenty = importlib.util.module_from_spec(spec)
spec.loader.exec_module(twenty)
BASE = twenty.BASE
MAX_LIBRARY_BYTES = 8192
RECEIVE_CALL = 0x1800422A2
COPY_STRING = 0x180011808
OLD_TWENTY_HASH = "3bceff093d67f86400dd0f3f1ece50f812d531926d5ff64cf72c227904da5d00"
IMPORT_RVAS = {"__imp_CreateFileW": 0xFC138, "__imp_CloseHandle": 0xFC150,
               "__imp_ReadFile": 0xFC1E0, "__imp_GetProcessHeap": 0xFC228,
               "__imp_HeapFree": 0xFC368, "__imp_HeapAlloc": 0xFC370}

def align(n, a):
    return (n + a - 1) & -a

def fnv1a(raw):
    result = 2166136261
    for value in raw:
        result = ((result ^ value) * 16777619) & 0xFFFFFFFF
    return result

def artifacts(scheme):
    # Reuse the exact baseline shape, Unicode, control and 50-unit guards.
    _, metrics = twenty.make_response(scheme, max_json_bytes=MAX_LIBRARY_BYTES)
    ordered = {str(i): scheme[str(i)] for i in range(20)}
    ordered.update(title=scheme["title"], key=scheme["key"])
    raw = twenty.compact(ordered)
    token = f"{len(raw):08X}:{fnv1a(raw):08X}"
    bootstrap = {"_lps_local_v1": token}
    # Keep the first ten native-panel preview rows truthful. The second bank
    # comes only from the library; an old DLL would see empty second-bank rows.
    bootstrap.update({str(i): scheme[str(i)] if i < 10 else "" for i in range(20)})
    bootstrap.update(title=scheme["title"], key=scheme["key"])
    short = twenty.compact(bootstrap)
    if len(short) > 2046:
        raise ValueError("Native preview/bootstrap still exceeds the unchanged transport.")
    import base64
    envelope = twenty.compact({"result": {"error_code": 0},
                               "shout_message": base64.b64encode(short).decode("ascii")})
    metrics.update(library_json_utf8_bytes=len(raw), bootstrap_json_utf8_bytes=len(short),
                   native_whole_scheme_limit=2046,
                   library_limit=MAX_LIBRARY_BYTES, transport_limit=2046,
                   checksum="FNV-1a32 consistency check, NOT authentication", token=token)
    return raw, envelope, metrics

class Coff:
    def __init__(self, raw, allow_writable=False):
        self.raw = raw
        machine, count, _, sym_at, sym_count, optional, _ = struct.unpack_from("<HHIIIHH", raw)
        if machine != 0x8664 or optional:
            raise ValueError("Only ordinary x64 COFF objects are supported.")
        self.sections = []
        for i in range(count):
            at = 20 + i * 40
            name = raw[at:at + 8].rstrip(b"\0").decode()
            size, pos, reloc = struct.unpack_from("<III", raw, at + 16)
            nreloc = struct.unpack_from("<H", raw, at + 32)[0]
            flags = struct.unpack_from("<I", raw, at + 36)[0]
            a = (flags >> 20) & 15
            if name not in (".text", ".rdata", ".xdata", ".pdata", ".data", ".bss", ".debug$S"):
                raise ValueError("Unexpected compiler section: " + name)
            if name == ".debug$S" and (nreloc or not flags & 0x02000000):
                raise ValueError("Only non-relocated discardable compiler metadata is ignored.")
            if name in (".data", ".bss") and size and not allow_writable:
                raise ValueError("Writable globals are not supported.")
            self.sections.append(dict(name=name, data=bytes(size) if name == ".bss" else raw[pos:pos + size],
                align=1 << (a - 1) if a else 1, relocs=[struct.unpack_from("<IIH", raw, reloc + j * 10)
                                                     for j in range(nreloc)]))
        strings = sym_at + sym_count * 18
        self.symbols = {}
        i = 0
        while i < sym_count:
            at = sym_at + i * 18
            if raw[at:at + 4] == bytes(4):
                start = strings + struct.unpack_from("<I", raw, at + 4)[0]
                name = raw[start:raw.index(0, start)].decode()
            else:
                name = raw[at:at + 8].rstrip(b"\0").decode()
            value, section = struct.unpack_from("<Ih", raw, at + 8)
            self.symbols[i] = dict(name=name, value=value, section=section)
            i += 1 + raw[at + 17]

    def link(self, image_base, section_rva, externals):
        content = bytearray()
        positions = {}
        for i, section in enumerate(self.sections, 1):
            if section["name"] in (".debug$S", ".data", ".bss"):
                continue
            offset = align(len(content), section["align"])
            content.extend(bytes(offset - len(content)))
            positions[i] = offset
            content.extend(section["data"])
        symbols = {}
        for i, symbol in self.symbols.items():
            if symbol["section"] > 0 and symbol["section"] in positions:
                symbols[i] = image_base + section_rva + positions[symbol["section"]] + symbol["value"]
            elif symbol["section"] == 0 and symbol["name"] in externals:
                symbols[i] = externals[symbol["name"]]
        for i, section in enumerate(self.sections, 1):
            if i not in positions:
                continue
            for offset, symbol, kind in section["relocs"]:
                if symbol not in symbols or offset + 4 > len(section["data"]):
                    raise ValueError("Unresolved or out-of-range relocation.")
                at = positions[i] + offset
                addend = struct.unpack_from("<i", content, at)[0]
                if 4 <= kind <= 9:  # REL32 through REL32_5
                    value = symbols[symbol] + addend - (image_base + section_rva + at + 4 + kind - 4)
                    struct.pack_into("<i", content, at, value)
                elif kind == 3:  # ADDR32NB for compiler-generated unwind records
                    struct.pack_into("<I", content, at, symbols[symbol] + addend - image_base)
                else:
                    raise ValueError(f"Unsupported relocation {kind}; no absolute-ASLR guesses.")
        exports = {symbol["name"]: symbols[i] for i, symbol in self.symbols.items()
                   if i in symbols and symbol["section"] > 0}
        pdata = b"".join(content[positions[i]:positions[i] + len(section["data"])]
                         for i, section in enumerate(self.sections, 1) if section["name"] == ".pdata")
        return bytes(content), exports, pdata, positions

def verify_imports(original):
    pe = twenty.PE64(original)
    head = struct.unpack_from("<I", original, 0x3C)[0] + 24
    rva, size = struct.unpack_from("<II", original, head + 112 + 8)
    at = pe.offset(BASE + rva, size)
    found = {}
    while any(original[at:at + 20]):
        lookup, _, _, name, first = struct.unpack_from("<IIIII", original, at)
        no = pe.offset(BASE + name, 1)
        dll = original[no:original.index(0, no)].decode().upper()
        j = 0
        while True:
            item = struct.unpack_from("<Q", original, pe.offset(BASE + lookup + j * 8, 8))[0]
            if not item:
                break
            if not item >> 63 and dll == "KERNEL32.DLL":
                no = pe.offset(BASE + item + 2, 1)
                fn = "__imp_" + original[no:original.index(0, no)].decode()
                if fn in IMPORT_RVAS:
                    found[fn] = first + j * 8
            j += 1
        at += 20
    if found != IMPORT_RVAS:
        raise ValueError("The known Win32 import slots did not match.")

def patch_library(original, object_bytes):
    existing, _ = twenty.patch_copy(original)
    if twenty.sha256(existing) != OLD_TWENTY_HASH:
        raise ValueError("Baseline twenty-message candidate is not reproducible.")
    verify_imports(original)
    pe = twenty.PE64(existing)
    header = struct.unpack_from("<I", existing, 0x3C)[0]
    optional = header + 24
    section_alignment, file_alignment = struct.unpack_from("<II", existing, optional + 32)
    new_rva = struct.unpack_from("<I", existing, optional + 56)[0]
    if new_rva != 0x190000 or section_alignment != 4096 or file_alignment != 512:
        raise ValueError("Unexpected PE geometry.")
    externals = {name: BASE + rva for name, rva in IMPORT_RVAS.items()}
    externals.update(copy_string=COPY_STRING, original_send=twenty.SENDER_VA)
    content, exports, new_pdata, _ = Coff(object_bytes).link(BASE, new_rva, externals)
    for name in ("ReadLocalScheme", "SendNonempty"):
        if name not in exports:
            raise ValueError("Required C entry point is missing.")
    old_pdata_at = pe.offset(BASE + pe.exception_rva, pe.exception_size)
    records = [existing[at:at + 12] for at in range(old_pdata_at, old_pdata_at + pe.exception_size, 12)]
    if not new_pdata or len(new_pdata) % 12:
        raise ValueError("Malformed compiler unwind table.")
    records.extend(new_pdata[i:i + 12] for i in range(0, len(new_pdata), 12))
    records.sort(key=lambda row: struct.unpack_from("<I", row)[0])
    for i, row in enumerate(records):
        begin, end, unwind = struct.unpack("<III", row)
        if begin >= end or (i and struct.unpack_from("<I", records[i - 1], 4)[0] > begin):
            raise ValueError("Unwind table contains overlapping/invalid functions.")
    pdata_offset = align(len(content), 4)
    payload = content + bytes(pdata_offset - len(content)) + b"".join(records)
    new_header = pe.sections[-1]["header"] + 40
    if new_header + 40 > min(s["raw"] for s in pe.sections) or existing[new_header:new_header + 40] != bytes(40):
        raise ValueError("No verified empty PE section-header slot.")
    # Keep the certificate table at the end of the file. It is retained only
    # for provenance: its digest WILL NOT validate the changed executable.
    cert_offset, cert_size = pe.certificate_offset, pe.certificate_size
    last_raw_end = max(s['raw'] + s['raw_size'] for s in pe.sections)
    if cert_offset < last_raw_end or cert_offset + cert_size != len(existing):
        raise ValueError("Unexpected certificate/overlay layout; no arbitrary overlay moves.")
    raw_offset = align(cert_offset, file_alignment)
    raw_size = align(len(payload), file_alignment)
    new_cert_offset = raw_offset + raw_size
    patched = bytearray(existing[:cert_offset] + bytes(raw_offset - cert_offset) + payload
                        + bytes(raw_size - len(payload)) + existing[cert_offset:])
    struct.pack_into("<8sIIIIIIHHI", patched, new_header, b".lpslib\0", len(payload), new_rva,
                     raw_size, raw_offset, 0, 0, 0, 0, 0x60000020)
    struct.pack_into("<H", patched, header + 6, len(pe.sections) + 1)
    code_size = struct.unpack_from("<I", patched, optional + 4)[0]
    struct.pack_into("<I", patched, optional + 4, code_size + raw_size)
    struct.pack_into("<I", patched, optional + 56, align(new_rva + len(payload), section_alignment))
    struct.pack_into("<II", patched, optional + 112 + 3 * 8, new_rva + pdata_offset, len(records) * 12)
    struct.pack_into("<II", patched, optional + 112 + 4 * 8, new_cert_offset, cert_size)
    hooks = []
    for va, old_target, new_target in [(RECEIVE_CALL, COPY_STRING, exports["ReadLocalScheme"]),
            (twenty.BODY_VA + 0x2C, twenty.SENDER_VA, exports["SendNonempty"])]:
        at = pe.offset(va, 5)
        expected = b"\xE8" + struct.pack("<i", old_target - va - 5)
        replacement = b"\xE8" + struct.pack("<i", new_target - va - 5)
        if existing[at:at + 5] != expected:
            raise ValueError("Unexpected original CALL bytes.")
        patched[at:at + 5] = replacement
        hooks.append(dict(va=hex(va), file_offset=at, before_hex=expected.hex(), after_hex=replacement.hex()))
    # The certificate, original unwind bytes, imports and other existing
    # non-code sections remain intact. Authenticode DIGEST will be invalid.
    for section in pe.sections:
        if section["name"] != b".text":
            at, n = section["raw"], section["raw_size"]
            if patched[at:at + n] != existing[at:at + n]:
                raise ValueError("An existing non-code section was altered.")
    if patched[new_cert_offset:new_cert_offset + cert_size] != existing[cert_offset:cert_offset + cert_size]:
        raise ValueError("Certificate bytes were altered.")
    return bytes(patched), dict(new_section_rva=new_rva, new_section_file_offset=raw_offset,
        payload_bytes=len(payload), compiled_payload_bytes=len(content),
        certificate_file_offset=new_cert_offset,
        added_unwind_records=len(new_pdata) // 12, unwind_record_count=len(records),
        entry_points={k: hex(exports[k]) for k in ("ReadLocalScheme", "SendNonempty")}, hooks=hooks)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scheme", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--clang", type=Path, default=Path(r"D:\LLVM\bin\clang.exe"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    out = args.out_dir.resolve()
    if root / "build" not in out.parents or out.exists():
        raise ValueError("Use a NEW directory strictly inside project build; never live paths.")
    source = args.source.resolve()
    original = source.read_bytes()
    raw, response, metrics = artifacts(twenty.read_scheme(args.scheme))
    if twenty.sha256(original) != twenty.DLL_SHA256:
        raise ValueError("Original signed version/hash mismatch.")
    out.mkdir(parents=True, exist_ok=False)
    object_path = out / "library20.obj"
    c_path = Path(__file__).with_name("library20.c")
    command = [str(args.clang), "--target=x86_64-pc-windows-msvc", "-Os", "-ffreestanding",
               "-fno-builtin", "-fno-stack-protector", "-fno-ident", "-fno-addrsig",
               "-funwind-tables", "-g0", "-c", str(c_path), "-o", str(object_path)]
    subprocess.run(command, check=True, capture_output=True, text=True)
    object_bytes = object_path.read_bytes()
    candidate, details = patch_library(original, object_bytes)
    twenty.write_new(out / "TenPallas.library.experimental.dll", candidate)
    twenty.write_new(out / "library20-v1.json", raw)
    twenty.write_new(out / "local-response.library.json", response)
    report = dict(experiment="local-library-v1", source_dll_sha256=twenty.sha256(original),
        baseline_twenty_sha256=OLD_TWENTY_HASH, candidate_dll_sha256=twenty.sha256(candidate),
        c_source_sha256=twenty.sha256(c_path.read_bytes()), object_sha256=twenty.sha256(object_bytes),
        library_sha256=twenty.sha256(raw), response_sha256=twenty.sha256(response), metrics=metrics,
        native=details, compile_command=command, installed=False, runtime_verified=False,
        game_send_verified=False, invalid_authenticode_digest=True,
        no_loader_or_integrity_bypass=True, transport_unchanged=True)
    twenty.write_new(out / "manifest.json", json.dumps(report, ensure_ascii=False, indent=2).encode("utf-8"))
    if source.read_bytes() != original:
        raise ValueError("Source changed during offline build.")
    print(json.dumps(report, ensure_ascii=True))

if __name__ == "__main__":
    main()
