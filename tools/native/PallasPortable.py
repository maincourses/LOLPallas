"""Offline profile-neutral candidate + binary deltas. No installs or DLL loads."""
from __future__ import annotations
import argparse
import importlib.util
import json
from pathlib import Path
import struct
import subprocess

spec = importlib.util.spec_from_file_location("hotkeys", Path(__file__).with_name("PallasHotkeys.py"))
base = importlib.util.module_from_spec(spec); spec.loader.exec_module(base)
lib, t, BASE = base.lib, base.t, base.BASE
CAPACITY, MAX_COUNT, KEYS, MODS, binding = base.CAPACITY, base.MAX_COUNT, base.KEYS, base.MODS, base.binding
link_split = base.link_split
EXISTING_IMPORTS = {"__imp_SHGetFolderPathW": 0xFC590,
                    "__imp_GetProcAddress": 0xFC080, "__imp_GetModuleHandleW": 0xFC118}

def artifacts(scheme):
    old, _, canonical, metrics = base.artifacts(scheme)
    records = old[16:]
    raw = b'LPSKEY3\0' + struct.pack('<III', 20 + len(records), scheme['count'], lib.fnv1a(records)) + records
    if len(raw) > CAPACITY: raise ValueError('Portable library exceeds 65536 bytes. Nothing truncated.')
    metrics.update(library_bytes=len(raw), bootstrap_bytes=0, token='', loader_exe_modified=False,
                   cloud_response_required=False, library_format=3)
    return raw, b'', canonical, metrics

def patch(original, obj, native_keys=False):
    pe = t.PE64(original)
    slot = pe.offset(BASE + 0xFC590, 8)
    hint = struct.unpack_from('<Q', original, slot)[0]
    at = pe.offset(BASE + hint + 2, 1)
    if original[at:original.index(0, at)] != b'SHGetFolderPathW':
        raise ValueError('Existing Shell32 import slot mismatch.')
    imports_unchanged = any(s['name'] == '__imp_GetProcAddress' for s in lib.Coff(obj, allow_writable=True).symbols.values())
    if imports_unchanged:
        # Check the two reused function names AND slots in the inspected DLL.
        head = struct.unpack_from('<I', original, 0x3C)[0] + 24
        rva, size = struct.unpack_from('<II', original, head + 120)
        cursor = pe.offset(BASE + rva, size); found = {}
        while any(original[cursor:cursor + 20]):
            lookup, _, _, _, first = struct.unpack_from('<IIIII', original, cursor)
            i = 0
            while True:
                hint = struct.unpack_from('<Q', original, pe.offset(BASE + lookup + i * 8, 8))[0]
                if not hint: break
                if not hint >> 63:
                    at = pe.offset(BASE + hint + 2, 1)
                    name = '__imp_' + original[at:original.index(0, at)].decode()
                    if name in EXISTING_IMPORTS: found[name] = first + i * 8
                i += 1
            cursor += 20
        if found != EXISTING_IMPORTS: raise ValueError('Reused import names/slots mismatch.')
    result, info = base.patch(original, obj, EXISTING_IMPORTS, preserve_iat=True,
                             replace_keyboard=not native_keys, append_user32=not imports_unchanged)
    if imports_unchanged: info['original_import_descriptors_preserved'] = True
    return result, info

def delta(before, after):
    rows, at = [], 0
    import base64
    while at < len(after):
        if at < len(before) and after[at] == before[at]: at += 1; continue
        start = at
        # Merge only small identical gaps, keeping a compact deterministic map.
        while at < len(after):
            at += 1
            if at < min(len(before), len(after)) and after[at] == before[at]:
                end = at
                while end < min(len(before), len(after)) and after[end] == before[end] and end - at < 16: end += 1
                if end - at >= 16: break
                at = end
        rows.append(dict(offset=start, data=base64.b64encode(after[start:at]).decode()))
    result = dict(format=1, source_sha256=t.sha256(before), target_sha256=t.sha256(after),
                  source_size=len(before), target_size=len(after), edits=rows)
    if expand(before, result) != after: raise ValueError('Delta reconstruction failed.')
    return result

def expand(before, plan):
    import base64
    if t.sha256(before) != plan['source_sha256'] or len(before) != plan['source_size']: raise ValueError('Delta source mismatch.')
    result = bytearray(plan['target_size']); copied = min(len(before), len(result)); result[:copied] = before[:copied]; last = 0
    for row in plan['edits']:
        data = base64.b64decode(row['data'], validate=True); at = row['offset']
        if at < last or not data or at + len(data) > len(result): raise ValueError('Invalid delta bounds/order.')
        result[at:at + len(data)] = data; last = at + len(data)
    if t.sha256(result) != plan['target_sha256']: raise ValueError('Delta result mismatch.')
    return bytes(result)

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--out-dir', type=Path, required=True)
    p.add_argument('--clang', type=Path, default=Path(r'D:\LLVM\bin\clang.exe'))
    p.add_argument('--original-imports', action='store_true', help='Compatibility control: do not append/move any PE imports.')
    args = p.parse_args(); root = Path(__file__).resolve().parents[2]; out = args.out_dir.resolve()
    if root / 'build' not in out.parents or out.exists(): raise ValueError('Use a NEW build subdirectory.')
    original = (root / 'engine/assets/TenPallas.original.dll').read_bytes()
    source = Path(__file__).with_name('hotkeys4.c' if args.original_imports else 'hotkeys3.c')
    out.mkdir(parents=True); obj = out / 'hotkeys3.obj'
    subprocess.run([str(args.clang), '--target=x86_64-pc-windows-msvc', '-Os', '-ffreestanding', '-fno-builtin',
        '-fno-stack-protector', '-fno-ident', '-fno-addrsig', '-funwind-tables', '-g0', '-c', str(source), '-o', str(obj)],
        check=True, capture_output=True, text=True)
    candidate, native = patch(original, obj.read_bytes())
    raw, response, canonical, metrics = artifacts(t.read_scheme(root / 'messages.example.json'))
    t.write_new(out / 'TenPallas.portable.experimental.dll', candidate)
    t.write_new(out / 'hotkeys-v3.bin', raw)
    # Empty, test-fixture-only compatibility output, never deployed/shipped.
    t.write_new(out / 'local-response.hotkeys.json', response)
    v2 = (root / 'build/hotkeys-v2/TenPallas.hotkeys.experimental.dll').read_bytes()
    if t.sha256(v2) != '4ae8ab0793eebcea5e23c1b8931a6c0057393bbcf413a9af323d91750d3ee143':
        raise ValueError('Known v2 source hash mismatch.')
    patch_hashes = {}
    previous = (root / 'build/portable-v3-c/TenPallas.portable.experimental.dll').read_bytes()
    if t.sha256(previous) != '6b8ccd673e96817095933bdaa170dc76d7995d27ec6cb41921f9e794a92f5ae3':
        raise ValueError('Known superseded portable source hash mismatch.')
    sources = [('original-to-portable.json', original), ('v2-to-portable.json', v2),
               ('portable-v3-to-fixed.json', previous)]
    if args.original_imports:
        fixed = (root / 'build/portable-v3-r2/TenPallas.portable.experimental.dll').read_bytes()
        if t.sha256(fixed) != '52776e6b2d105df4cd0ff7ec8933e8170f7a404d1d6fd68288ca5c44af0cc0ad':
            raise ValueError('Pinned fixed-v3 source mismatch.')
        sources.append(('portable-fixed-to-compatible.json', fixed))
    for name, before in sources:
        data = t.compact(delta(before, candidate)); t.write_new(out / name, data); patch_hashes[name] = t.sha256(data)
    report = dict(experiment='original-imports-compatibility-control' if args.original_imports else 'portable-v3-input-fix', candidate_dll_sha256=t.sha256(candidate),
        source_dll_sha256=t.sha256(original), metrics=metrics, native=native, patch_sha256=patch_hashes,
        installed=False, game_send_verified=False, unsigned_experiment=True,
        loader_exe_modified=False, local_user_path_hardcoded=False,
        shell32_existing_import='SHGetFolderPathW / CSIDL_LOCAL_APPDATA')
    t.write_new(out / 'manifest.json', json.dumps(report, indent=2).encode()); print(json.dumps(report))

if __name__ == '__main__': main()
