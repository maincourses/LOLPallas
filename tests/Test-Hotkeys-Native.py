"""Own-process compiled-C fixtures ONLY. No Tencent DLLs/games are loaded."""
from __future__ import annotations
import argparse
import base64
import copy
import ctypes as c
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import unittest

p = argparse.ArgumentParser(); p.add_argument("--build", type=Path, required=True)
p.add_argument("--child", action="store_true"); p.add_argument("--real-io", action="store_true")
p.add_argument("--portable", action="store_true")
args = p.parse_args(); root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("hotkeys", root / ("tools/native/PallasPortable.py" if args.portable else "tools/native/PallasHotkeys.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
obj = (args.build / ("hotkeys3.obj" if args.portable else "hotkeys2.obj")).read_bytes()
original = (root / "engine/assets/TenPallas.original.dll").read_bytes()
candidate = (args.build / ("TenPallas.portable.experimental.dll" if args.portable else "TenPallas.hotkeys.experimental.dll")).read_bytes()
manifest = json.loads((args.build / "manifest.json").read_text())
scheme = m.t.read_scheme(root / "messages.example.json")
binary_name = 'hotkeys-v3.bin' if args.portable else 'hotkeys-v2.bin'
header_size = 20 if args.portable else 16

def large_scheme(count=512, length=50):
    result = dict(version=2, title="Capacity test", count=count)
    combos = [(vk, mask) for mask in range(1, 16) for vk in m.KEYS if not (mask & 2 and vk == "F4")
              and not (mask & 3 == 3 and vk == "DELETE")]
    for i in range(count):
        vk, mask = combos[i]
        result[str(i)] = "x" * length
        result[f"bind{i}"] = "+".join([k for k, bit in m.MODS.items() if mask & bit] + [vk])
    return result

class Offline(unittest.TestCase):
    def test_reproducible(self):
        rebuilt, info = m.patch(original, obj)
        self.assertEqual(rebuilt, candidate); self.assertEqual(info, manifest["native"])
        self.assertEqual(m.t.sha256(candidate), manifest["candidate_dll_sha256"])
    def test_schema_guards(self):
        for key, value in [("count", True), ("count", 0), ("count", 513), ("version", 2.0),
                           ("0", "x" * 51), ("0", "\ud800"), ("0", "\n"), ("0", " "),
                           ("bind0", "Alt+F4"), ("bind0", "Ctrl+Alt+Delete"), ("bind0", "Q"),
                           ("bind0", "Win+Q"), ("bind0", "Ctrl+Ctrl+Q"), ("bind0", "Ctrl+Alt+Q")]:
            bad = dict(scheme); bad[key] = value
            with self.assertRaises((ValueError, UnicodeError)): m.artifacts(bad)
        with self.assertRaises(ValueError): m.artifacts(dict(scheme, extra="x"))
    def test_capacity(self):
        raw, _, _, _ = m.artifacts(large_scheme())
        self.assertGreater(len(raw), 8192); self.assertEqual(len(raw), 30224 + (4 if args.portable else 0))
        big = large_scheme(); big.update({str(i): "\u4e2d" * 50 for i in range(512)})
        with self.assertRaises(ValueError): m.artifacts(big)
        # Exact capacity: 412*159 + 12*ASCII(1+9) = 65508+120+16=65644;
        # produce a valid <=64 KiB boundary payload using mixed text lengths.
        near = large_scheme(512, 1)
        for i in range(403): near[str(i)] = "\u4e2d" * 50
        raw, _, _, _ = m.artifacts(near); self.assertGreater(len(raw), 64000)
    def test_roundtrip(self):
        raw, response, canonical, metrics = m.artifacts(scheme)
        self.assertEqual(raw, (args.build / binary_name).read_bytes())
        self.assertEqual(response, (args.build / "local-response.hotkeys.json").read_bytes())
        if not args.portable:
            decoded = base64.b64decode(json.loads(response)["shout_message"], validate=True)
            self.assertLess(len(decoded), 2046); self.assertEqual(json.loads(decoded)["_lps_keys_v2"], metrics["token"])
        else: self.assertEqual(response, b'')
        self.assertEqual(struct.unpack_from("<II", raw, 8), (len(raw), 3))
        self.assertEqual(canonical["bind1"], "Ctrl+Alt+Q")
    def test_sections_imports_and_certificate(self):
        baseline, _ = m.t.patch_copy(original); pe = m.t.PE64(baseline); after = m.t.PE64(candidate)
        self.assertEqual(after.sections[:-2], pe.sections)
        for s in pe.sections:
            if s["name"] != b".text":
                self.assertEqual(candidate[s['raw']:s['raw'] + s['raw_size']], baseline[s['raw']:s['raw'] + s['raw_size']])
        self.assertEqual(candidate[after.certificate_offset:], original[pe.certificate_offset:])
        header = struct.unpack_from("<I", candidate, 0x3C)[0] + 24
        rva, size = struct.unpack_from("<II", candidate, header + 112 + 8)
        if manifest['native'].get('original_import_descriptors_preserved'):
            old_header = struct.unpack_from('<I', original, 0x3C)[0] + 24
            self.assertEqual(candidate[header+120:header+128], original[old_header+120:old_header+128])
            at = after.offset(m.BASE + rva, size)
            self.assertEqual(candidate[at:at+size], original[at:at+size])
            self.assertEqual(manifest['native']['added_public_imports'], [])
        else:
            at = after.offset(m.BASE + rva, size) + size - 40
            lookup, _, _, name, iat = struct.unpack_from("<IIIII", candidate, at)
            self.assertEqual(candidate[after.offset(m.BASE + name, 11):][:11], b"USER32.dll\0")
            for i, name in enumerate(("GetAsyncKeyState", "GetForegroundWindow")):
                hint = struct.unpack_from("<Q", candidate, after.offset(m.BASE + lookup + 8 * i, 8))[0]
                self.assertEqual(struct.unpack_from("<Q", candidate, after.offset(m.BASE + iat + 8 * i, 8))[0], hint)
                pos = after.offset(m.BASE + hint + 2, len(name) + 1)
                self.assertEqual(candidate[pos:pos + len(name) + 1], name.encode() + b"\0")
        for s in after.sections:
            flags = struct.unpack_from("<I", candidate, s['header'] + 36)[0]
            self.assertFalse(flags & 0x20000000 and flags & 0x80000000, "No RWX sections")
        if args.portable:
            old_header = struct.unpack_from('<I', original, 0x3C)[0] + 24
            self.assertEqual(candidate[header + 112 + 12 * 8:header + 112 + 13 * 8],
                             original[old_header + 112 + 12 * 8:old_header + 112 + 13 * 8])
            self.assertTrue(manifest['native']['original_iat_directory_preserved'])
    def test_only_pinned_hooks_change_original_code(self):
        baseline, _ = m.t.patch_copy(original); s = m.t.PE64(baseline).sections[0]; expected = set()
        for hook in manifest["native"]["hooks"]:
            at = hook["file_offset"]; expected.update(range(at, at + 5))
            self.assertEqual(baseline[at:at + 5].hex(), hook["before_hex"])
            self.assertEqual(candidate[at:at + 5].hex(), hook["after_hex"])
        self.assertTrue({i for i in range(s['raw'], s['raw'] + s['raw_size']) if baseline[i] != candidate[i]} <= expected)
    def test_aslr_and_unwind(self):
        info = manifest["native"]; externals = {k: m.BASE + v for k, v in m.lib.IMPORT_RVAS.items()}
        externals.update(copy_string=m.lib.COPY_STRING, original_send=m.t.SENDER_VA)
        externals.update({k: m.BASE + v for k, v in getattr(m, 'EXISTING_IMPORTS', {}).items()})
        for i, name in enumerate(info["added_public_imports"]):
            externals["__imp_" + name] = m.BASE + info["data_rva"] + info["iat_offset"] + 8 * i
        first = m.link_split(obj, m.BASE, info["code_rva"], info["data_rva"], externals)
        delta = 0x700000000
        second = m.link_split(obj, m.BASE + delta, info["code_rva"], info["data_rva"], {k: v + delta for k, v in externals.items()})
        self.assertEqual(first[:2], second[:2]); self.assertEqual(first[3], second[3])
        pe = m.t.PE64(candidate); at = pe.offset(m.BASE + pe.exception_rva, pe.exception_size)
        previous = 0
        for p in range(at, at + pe.exception_size, 12):
            begin, end, info = struct.unpack_from("<III", candidate, p)
            self.assertLess(begin, end); self.assertGreaterEqual(begin, previous); previous = end
            self.assertIn(candidate[pe.offset(m.BASE + info, 1)] & 7, (1, 2))
    def test_unknown_binary_refused(self):
        for bad in (original[:-1], candidate):
            with self.assertRaises(ValueError): m.patch(bad, obj)

def native(real_io=False):
    k = c.WinDLL("kernel32", use_last_error=True); WIN = c.WINFUNCTYPE
    k.VirtualAlloc.argtypes = [c.c_void_p, c.c_size_t, c.c_ulong, c.c_ulong]; k.VirtualAlloc.restype = c.c_void_p
    k.VirtualProtect.argtypes = [c.c_void_p, c.c_size_t, c.c_ulong, c.c_void_p]
    k.VirtualFree.argtypes = [c.c_void_p, c.c_size_t, c.c_ulong]
    k.FlushInstructionCache.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t]
    k.CreateFileW.argtypes = [c.c_wchar_p, c.c_uint32, c.c_uint32, c.c_void_p, c.c_uint32, c.c_uint32, c.c_void_p]
    k.CreateFileW.restype = c.c_void_p
    k.ReadFile.argtypes = [c.c_void_p, c.c_void_p, c.c_uint32, c.c_void_p, c.c_void_p]
    k.CloseHandle.argtypes = [c.c_void_p]
    nt = c.WinDLL("ntdll")
    nt.RtlAddFunctionTable.argtypes = [c.c_void_p, c.c_ulong, c.c_uint64]; nt.RtlAddFunctionTable.restype = c.c_ubyte
    nt.RtlDeleteFunctionTable.argtypes = [c.c_void_p]
    base = k.VirtualAlloc(None, 0x50000, 0x3000, 4)
    if not base: raise c.WinError(c.get_last_error())
    callbacks, errors, state = [], [], dict(sent=[], copied=None, opens=0, mods=0, win=False, hwnd=1234, folder=r'C:\Users\Sample\AppData\Local')
    controller = c.create_string_buffer(256)
    c.c_ubyte.from_address(c.addressof(controller) + 0x91).value = 1
    def wrap(kind, fn):
        def safe(*params):
            try: return fn(*params)
            except BaseException as e: errors.append(repr(e)); return 0
        callback = kind(safe); callbacks.append(callback); return c.cast(callback, c.c_void_p).value
    def create(path, access, share, security, disposition, flags, template):
        expected_path = state['folder'] + r'\LOLPallasPortable\hotkeys.bin' if args.portable else r"C:\Users\zly\AppData\Local\PallasCustomShout\hotkeys-v2.bin"
        assert c.wstring_at(path) == expected_path
        assert (access, share, security, disposition, flags, template) == (0x80000000, 1, None, 3, 0x00200080, None)
        state['opens'] += 1
        if real_io:
            state['handle'] = k.CreateFileW(str((args.build / binary_name).resolve()), access, share, security, disposition, flags, template)
            return state['handle']
        return 0xFFFFFFFFFFFFFFFF if state.get('missing') else 42
    def read(handle, data, size, count, overlapped):
        assert size <= 65537 and overlapped is None
        if real_io:
            result = k.ReadFile(handle, data, size, count, overlapped)
            if state.get('corrupt_checksum'): c.c_ubyte.from_address(data + 16).value ^= 1
            return result
        raw = state['file'][:size]; c.memmove(data, raw, len(raw)); c.c_uint32.from_address(count).value = len(raw)
        return int(not state.get('read_error'))
    def close(handle):
        state['closed'] = state.get('closed', 0) + 1
        return k.CloseHandle(handle) if real_io else 1
    api = {
        '__imp_CreateFileW': wrap(WIN(c.c_void_p, c.c_void_p, c.c_uint32, c.c_uint32, c.c_void_p, c.c_uint32, c.c_uint32, c.c_void_p), create),
        '__imp_ReadFile': wrap(WIN(c.c_int, c.c_void_p, c.c_void_p, c.c_uint32, c.c_void_p, c.c_void_p), read),
        '__imp_CloseHandle': wrap(WIN(c.c_int, c.c_void_p), close),
        '__imp_GetAsyncKeyState': wrap(WIN(c.c_short, c.c_int), lambda vk: -32768 if
            (state['win'] if vk in (0x5B, 0x5C) else (0 if args.portable else state['mods'] & {0x11:1, 0x12:2, 0x10:4, 0xC0:8}[vk])) else 0),
        '__imp_GetForegroundWindow': wrap(WIN(c.c_void_p), lambda: state['hwnd'])}
    if args.portable:
        def folder(hwnd, csidl, token, flags, output):
            assert (hwnd, csidl, token, flags) == (None, 0x1C, None, 0)
            if state.get('folder_fail'): return -2147467259
            text = c.create_unicode_buffer(state['folder']); c.memmove(output, text, c.sizeof(text)); return 0
        api['__imp_SHGetFolderPathW'] = wrap(WIN(c.c_int, c.c_void_p, c.c_int, c.c_void_p, c.c_uint32, c.c_void_p), folder)
        if manifest['native'].get('original_import_descriptors_preserved'):
            def module(name):
                assert c.wstring_at(name) == 'USER32.dll'
                return 0 if state.get('api_missing') else 42
            def resolve(handle, name):
                assert handle == 42
                return api['__imp_' + c.string_at(name).decode()]
            api['__imp_GetModuleHandleW'] = wrap(WIN(c.c_void_p, c.c_void_p), module)
            api['__imp_GetProcAddress'] = wrap(WIN(c.c_void_p, c.c_void_p, c.c_void_p), resolve)
    copy_at = wrap(WIN(c.c_void_p, c.c_void_p, c.c_void_p), lambda dest, src: (state.update(copied=c.string_at(src)) or dest))
    send_at = wrap(WIN(None, c.c_void_p), lambda text: state['sent'].append(c.string_at(text)))
    externals = {}
    for i, (name, address) in enumerate(api.items()):
        slot = base + 0x19000 + i * 8; c.c_uint64.from_address(slot).value = address; externals[name] = slot
    for name, at, target in (('copy_string', 0x18000, copy_at), ('original_send', 0x18020, send_at)):
        stub = b'\x48\xB8' + struct.pack('<Q', target) + b'\xFF\xE0'
        c.memmove(base + at, stub, len(stub)); externals[name] = base + at
    code, data, exports, pdata = m.link_split(obj, base, 0, 0x20000, externals)
    c.memmove(base, bytes(code), len(code)); c.memmove(base + 0x20000, bytes(data), len(data))
    old = c.c_ulong(); assert k.VirtualProtect(base, 0x20000, 0x20, c.byref(old))
    assert k.FlushInstructionCache(c.c_void_p(-1), base, 0x20000)
    table = c.create_string_buffer(pdata); assert nt.RtlAddFunctionTable(table, len(pdata) // 12, base)
    load = WIN(c.c_void_p, c.c_void_p, c.c_void_p)(exports['ReadLocalScheme'])
    key = WIN(None, c.c_void_p, c.c_uint32, c.c_size_t, c.c_size_t)(exports['CustomKeyboard'])
    cases = 0
    def check(condition):
        nonlocal cases
        assert condition; assert not errors, errors; cases += 1
    def run(raw, source=None, **flags):
        state.update(file=raw, mods=0, win=False, sent=[], hwnd=1234, opens=0, closed=0, missing=False, read_error=False,
                     folder=r'C:\Users\Sample\AppData\Local', folder_fail=False, corrupt_checksum=False, api_missing=False)
        state.update(flags)
        if source is None: source = b'Cloud text ignored' if args.portable else f'{{"_lps_keys_v2":"{len(raw):08X}:{m.lib.fnv1a(raw):08X}","key":1}}'.encode()
        text = c.create_string_buffer(source); assert load(0x2222, c.addressof(text)) == 0x2222
        if args.portable:
            # Independent test cases start with every key released. Production
            # reloads deliberately retain latches; tested separately below.
            for name in ('event_down', 'pressed', 'blocked'): c.memset(exports[name], 0, 256)
            c.c_uint64.from_address(exports['foreground']).value = 0
            c.c_ubyte.from_address(c.addressof(controller) + 0x92).value = 0
            state['event_mods'] = 0
        return b'LOAD FAILED' not in state['copied']
    def direct(vk, message): key(c.addressof(controller) if args.portable else None, message, vk, 0)
    def event(vk, mods, message=0x100):
        state['mods'] = mods
        if args.portable:
            before = state.get('event_mods', 0)
            for bit, modifier in ((1, 0x11), (2, 0x12), (4, 0x10), (8, 0xC0)):
                if before & bit and not mods & bit: direct(modifier, 0x101)
                elif mods & bit and not before & bit: direct(modifier, 0x100)
            state['event_mods'] = mods
        direct(vk, message)
    try:
        raw = (args.build / binary_name).read_bytes(); check(run(raw))
        event(0x31, 8); check(state['sent'] == [b'Message one'])
        for _ in range(10): event(0x31, 8)
        check(len(state['sent']) == 1)
        event(0x31, 8, 0x101); event(0x31, 8); check(len(state['sent']) == 2)
        event(0x51, 3, 0x104); check(state['sent'][-1] == b'Message two')
        event(0x51, 3, 0x105); event(0x51, 7); check(len(state['sent']) == 3)
        event(0x51, 7, 0x101); event(0x71, 5); check(state['sent'][-1] == b'Message three')
        check(state['opens'] == 1) # Zero file IO per keyboard event.
        event(0x71, 5, 0x101); event(0x71, 0); event(0x71, 5); check(len(state['sent']) == 4)
        event(0x71, 5, 0x101); event(0x71, 5); check(len(state['sent']) == 5)
        state['hwnd'] = None; event(0x51, 3); check(len(state['sent']) == 5)
        state['hwnd'] = 9876
        if args.portable:
            event(0x51, 3); check(len(state['sent']) == 5) # no held-key focus replay
            event(0x51, 0, 0x101); event(0x51, 3)
        else: event(0x51, 3)
        check(len(state['sent']) == 6)
        event(256, 8); event(0x31, 8, 0x102); check(len(state['sent']) == 6)
        state['win'] = True; event(0x71, 5); check(len(state['sent']) == 6)
        state['win'] = False
        if real_io:
            check(not run(raw, corrupt_checksum=True) if args.portable else not run(raw, source=b'{"_lps_keys_v2":"0000004E:00000000","key":1}'))
            event(0x31, 8); check(not state['sent'])
        else:
            many = large_scheme(); big, _, _, _ = m.artifacts(many); check(run(big))
            for i in range(512):
                vk, mask, _ = m.binding(many[f'bind{i}']); event(vk, mask); event(vk, mask, 0x101)
            check(state['sent'] == [b'x' * 50] * 512)
            # Exact-capacity file: extend valid messages to hit 65536 precisely.
            near = large_scheme(512, 1)
            for i in range(405): near[str(i)] = '\u4e2d' * 50
            near['405'] = 'x' * 50; near['406'] = 'x' * (3 if args.portable else 7)
            boundary, _, _, _ = m.artifacts(near); check(len(boundary) == 65536); check(run(boundary))
            failures = [b'x' * 65537, raw[:-1], raw + b'x', bytes(raw), b'x' * 26]
            # Recompute checksums for semantically bad files, not just corruption.
            b = bytearray(raw); b[:8] = b'WRONG!!!'; failures.append(bytes(b))
            for offset, value in ((8, len(raw) + 1), (12, 0), (12, 513), (header_size + 4, 1000)):
                b = bytearray(raw); struct.pack_into('<I', b, offset, value); failures.append(bytes(b))
            b = bytearray(raw); struct.pack_into('<HH', b, header_size, 0x73, 2); failures.append(bytes(b))
            b = bytearray(raw); struct.pack_into('<HH', b, header_size, 0x31, 0); failures.append(bytes(b))
            b = bytearray(raw); b[header_size + 8] = 0; failures.append(bytes(b))
            b = bytearray(raw); b[header_size + 8:header_size + 10] = b'\xC0\x80'; failures.append(bytes(b))
            b = bytearray(raw); b[header_size + 8:header_size + 11] = b'\xED\xA0\x80'; failures.append(bytes(b))
            b = bytearray(raw); b[header_size + 8] = 10; failures.append(bytes(b))
            # A valid payload whose expected checksum was deliberately wrong.
            failures.pop(3)
            for bad in failures:
                if args.portable:
                    bad = bytearray(bad); struct.pack_into('<I', bad, 16, m.lib.fnv1a(bad[20:])); bad = bytes(bad)
                check(not run(bad)); event(0x31, 8); check(not state['sent'])
            # Duplicate bindings within a correctly checksummed binary.
            duplicate = bytearray(raw); second = header_size + 8 + len(b'Message one') + 1
            duplicate[second:second + 4] = duplicate[header_size:header_size + 4]
            if args.portable: struct.pack_into('<I', duplicate, 16, m.lib.fnv1a(duplicate[20:]))
            check(not run(bytes(duplicate)))
            check(not run(raw, missing=True)); check(state['closed'] == 0)
            check(not run(raw, read_error=True)); check(state['closed'] == 1)
            if not args.portable:
                for n in range(19):
                    src = b'{"_lps_keys_v2":"' + b'0000004E:0FD37E87",'[:n]
                    check(not run(raw, source=src))
                check(not run(raw, source=b'{}')); check(not run(raw, source=b'{"_lps_keys_v2":"0000004E:00000000","key":1}'))
            else:
                if manifest['native'].get('original_import_descriptors_preserved'):
                    check(run(raw, api_missing=True)); event(0x31,8); check(not state['sent'])
                    state['api_missing'] = False; event(0x31,8,0x101); event(0x31,8)
                    # Recovery after normal public APIs become available requires
                    # fresh modifier events; focus reset does not replay held keys.
                    check(not state['sent']); event(0x31,0,0x101); event(0x31,8)
                    check(state['sent'] == [b'Message one'])
                check(run(raw, source=b'{}')); check(run(raw, source=b'Bad cloud JSON is not parsed'))
                for path in (r'E:\Profiles\Different\Local', 'C:\\Users\\\u4e2d\u6587\u6635\u79f0\\AppData\\Local'):
                    check(run(raw, folder=path)); event(0x31, 8); check(state['sent'] == [b'Message one'])
                check(not run(raw, folder_fail=True)); check(state['opens'] == 0)
                check(not run(raw, folder='x' * 250)); check(state['opens'] == 0)
                check(run(raw)); c.c_uint32.from_address(exports['load_attempted']).value = 0
                c.c_uint32.from_address(exports['active']).value = 0; state.update(sent=[], opens=0, mods=8)
                event(0x31, 8); check(state['sent'] == [b'Message one'] and state['opens'] == 1)
                # Original native panel gate and held-modifier reuse, even when
                # all async Ctrl/Alt/Shift/~ queries in this fixture return zero.
                check(run(raw)); direct(0xC0, 0x100)
                check(c.c_ubyte.from_address(c.addressof(controller)+0x92).value == 1)
                direct(0x31, 0x100); check(state['sent'] == [b'Message one'])
                direct(0x31, 0x101); direct(0x31, 0x100); check(len(state['sent']) == 2)
                direct(0xC0, 0x101)
                check(c.c_ubyte.from_address(c.addressof(controller)+0x92).value == 0)
                direct(0x31, 0x101); direct(0x31, 0x100); check(len(state['sent']) == 2)
                # Reload must not unlatch a held primary and replay autorepeat.
                check(run(raw)); event(0x31,8)
                cloud = c.create_string_buffer(b'{}'); load(0x2222,c.addressof(cloud))
                direct(0x31,0x100); check(len(state['sent']) == 1)
                direct(0x31,0x101); direct(0x31,0x100); check(len(state['sent']) == 2)
                # Bounded recovery after a missing-file first attempt; no polling.
                check(not run(raw,missing=True)); state['missing'] = False
                event(0x31,8); check(state['sent'] == [b'Message one'])
                check(not run(raw,missing=True))
                for unused in range(8): event(0x31,8); event(0x31,8,0x101)
                check(not state['sent'])
                # Left/right modifiers and system messages.
                check(run(raw)); direct(0xA2,0x100); direct(0xA3,0x100); direct(0xA4,0x104)
                direct(0xA2,0x101); direct(0x51,0x104); check(state['sent'] == [b'Message two'])
                direct(0x51,0x105); direct(0xA3,0x101); direct(0x51,0x104); check(len(state['sent']) == 1)
                # Win event state must suppress even when physical querying is zero.
                check(run(raw)); direct(0x5B,0x100); direct(0xC0,0x100); direct(0x31,0x100)
                check(not state['sent']); direct(0x31,0x101); direct(0x5B,0x101); direct(0x31,0x100)
                check(state['sent'] == [b'Message one'])
                # Native digit previews map by binding, not row order; escaping
                # and worst-case text fit the fixed preview buffer without cuts.
                preview_test=dict(version=2,title='Preview',count=10)
                for i in range(10):
                    preview_test[str(i)]='\u4e2d'*50
                    preview_test['bind'+str(i)]='~+'+str((i+1)%10)
                preview_raw,_,_,_=m.artifacts(preview_test); check(run(preview_raw))
                check(json.loads(state['copied'])['9'] == '\u4e2d'*50 and len(state['copied']) < 2046)
                preview_test['0']='a"\\<> '; preview_raw,_,_,_=m.artifacts(preview_test)
                check(run(preview_raw)); check(json.loads(state['copied'])['0'] == 'a"\\<> ')
            check(run(raw)); c.c_uint32.from_address(exports['gate']).value = 1
            event(0x31, 8); check(not state['sent'])
            check(not run(raw)); c.c_uint32.from_address(exports['gate']).value = 0
            event(0x31, 8); check(state['sent'] == [b'Message one'] if args.portable else not state['sent'])
            check(run(raw))
            for mask in range(1, 16):
                label = '+'.join([name for name, bit in m.MODS.items() if mask & bit] + ['Q'])
                test = dict(version=2, title='Modifier test', count=1, **{'0':'mask'+str(mask), 'bind0':label})
                payload, _, _, _ = m.artifacts(test); check(run(payload))
                event(0x51, mask); check(state['sent'] == [('mask'+str(mask)).encode()])
            for text in ('\u4e2d' * 50, '\U0001f600' * 25, 'a"\\<>'):
                test = dict(version=2, title='Unicode', count=1, **{'0':text, 'bind0':'Ctrl+Q'})
                payload, _, _, _ = m.artifacts(test); check(run(payload)); event(0x51, 1)
                check(state['sent'] == [text.encode()])
            for text in ('x' * 51, '\U0001f600' * 26, '\u4e2d' * 51, '\u3000'):
                encoded = text.encode(); payload = (b'LPSKEY3\0' if args.portable else b'LPSKEY2\0') + struct.pack('<II', header_size + 9 + len(encoded), 1)
                if args.portable: payload += struct.pack('<I', m.lib.fnv1a(struct.pack('<HHI', 0x51, 1, len(encoded)) + encoded + b'\0'))
                payload += struct.pack('<HHI', 0x51, 1, len(encoded)) + encoded + b'\0'
                check(not run(payload)); event(0x51, 1); check(not state['sent'])
            legacy = m.t.read_scheme(root / 'experiments/local-library/scheme20.example.json')
            migrated = dict(version=2, title=legacy['title'], count=20)
            for i in range(20):
                migrated[str(i)] = legacy[str(i)]
                migrated[f'bind{i}'] = '~+' + (str((i + 1) % 10) if i < 10 else 'F'+str(i-9))
            payload, _, _, _ = m.artifacts(migrated); check(run(payload))
            for i in range(20):
                vk, mask, _ = m.binding(migrated[f'bind{i}'])
                event(vk, mask, 0x104 if vk == 0x79 else 0x100)
                event(vk, mask, 0x105 if vk == 0x79 else 0x101)
                check(state['sent'][-1] == legacy[str(i)].encode())
        assert not errors
        return dict(passed=True, cases=cases, real_file_io=real_io, no_game_or_proprietary_dll_loaded=True)
    finally:
        assert nt.RtlDeleteFunctionTable(table); assert k.VirtualFree(base, 0, 0x8000)

if args.child:
    print(json.dumps(native(args.real_io)))
else:
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Offline))
    if not result.wasSuccessful(): sys.exit(1)
    results = []
    for extra in ([], ['--real-io']):
        child = subprocess.run([sys.executable, __file__, '--build', str(args.build), '--child'] + extra + (['--portable'] if args.portable else []),
                               capture_output=True, text=True, timeout=30)
        if child.returncode: raise RuntimeError(child.stdout + child.stderr)
        results.append(json.loads(child.stdout))
    report = dict(candidate_dll_sha256=m.t.sha256(candidate), unit_tests_passed=True,
                  unit_tests=result.testsRun, native=results[0], native_file_io=results[1])
    target = args.build / ('validation.portable.json' if args.portable else 'validation.hotkeys.json')
    if target.exists(): target.unlink() # Only this own generated validation report.
    m.t.write_new(target, json.dumps(report, indent=2).encode()); print(json.dumps(report))
