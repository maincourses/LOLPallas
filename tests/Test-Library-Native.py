"""Isolated own-process instruction tests. Never load Tencent DLLs or games.

Win32 imports, string copy and sender are replaced by recording fixtures. All
native memory belongs to this Python child; even file reads are mocked.
"""
from __future__ import annotations
import argparse
import base64
import copy
import ctypes
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import unittest

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--build", type=Path, required=True)
parser.add_argument("--child", action="store_true")
parser.add_argument("--real-io-child", action="store_true")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("library", root / "tools/native/PallasLibrary.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
original = (root / "engine/assets/TenPallas.original.dll").read_bytes()
obj = (args.build / "library20.obj").read_bytes()
candidate = (args.build / "TenPallas.library.experimental.dll").read_bytes()
manifest = json.loads((args.build / "manifest.json").read_text())
scheme = m.twenty.read_scheme(root / "experiments/local-library/scheme20.example.json")

class Offline(unittest.TestCase):
    def test_reproducible(self):
        rebuilt, info = m.patch_library(original, obj)
        self.assertEqual(rebuilt, candidate)
        self.assertEqual(info, manifest["native"])
        self.assertEqual(m.twenty.sha256(candidate), manifest["candidate_dll_sha256"])

    def test_large_scheme_roundtrip(self):
        raw, response, metrics = m.artifacts(scheme)
        self.assertGreater(len(raw), 2046)
        self.assertEqual(raw, (args.build / "library20-v1.json").read_bytes())
        self.assertEqual(response, (args.build / "local-response.library.json").read_bytes())
        self.assertEqual(json.loads(raw), scheme)
        short = base64.b64decode(json.loads(response)["shout_message"], validate=True)
        self.assertLessEqual(len(short), 2046)
        self.assertEqual(json.loads(short)["_lps_local_v1"], metrics["token"])
        for i in range(10): self.assertEqual(json.loads(short)[str(i)], scheme[str(i)])

    def test_guards_preserved(self):
        for key, value in [("key", True), ("key", 3), ("0", "x" * 51), ("19", ""),
                           ("0", "a\n"), ("0", "\ud800")]:
            bad = copy.deepcopy(scheme); bad[key] = value
            with self.assertRaises((ValueError, UnicodeError)): m.artifacts(bad)
        with self.assertRaises(ValueError): m.twenty.make_response(scheme)
        bad = dict(scheme, extra="no")
        with self.assertRaises(ValueError): m.artifacts(bad)

    def test_original_sections_and_certificate_unchanged(self):
        baseline, _ = m.twenty.patch_copy(original)
        pe = m.twenty.PE64(baseline)
        after = m.twenty.PE64(candidate)
        self.assertEqual(len(after.sections), len(pe.sections) + 1)
        self.assertEqual(after.sections[:-1], pe.sections)
        for s in pe.sections:
            if s["name"] != b".text":
                at, size = s["raw"], s["raw_size"]
                self.assertEqual(candidate[at:at + size], baseline[at:at + size])
        c = slice(pe.certificate_offset, pe.certificate_offset + pe.certificate_size)
        new_c = slice(after.certificate_offset, after.certificate_offset + after.certificate_size)
        self.assertEqual(candidate[new_c], original[c])
        self.assertEqual(after.sections[-1]["name"], b".lpslib")

    def test_original_text_only_two_calls_changed(self):
        baseline, _ = m.twenty.patch_copy(original)
        pe = m.twenty.PE64(baseline)
        s = pe.sections[0]
        expected = set()
        for hook in manifest["native"]["hooks"]:
            at = hook["file_offset"]
            before, after = bytes.fromhex(hook["before_hex"]), bytes.fromhex(hook["after_hex"])
            self.assertEqual(baseline[at:at + 5], before)
            self.assertEqual(candidate[at:at + 5], after)
            expected.update(range(at, at + 5))
        changed = {i for i in range(s["raw"], s["raw"] + s["raw_size"])
                   if baseline[i] != candidate[i]}
        self.assertTrue(changed <= expected)

    def test_unwind_and_aslr(self):
        pe = m.twenty.PE64(candidate)
        at = pe.offset(m.BASE + pe.exception_rva, pe.exception_size)
        records = [struct.unpack_from("<III", candidate, p) for p in range(at, at + pe.exception_size, 12)]
        self.assertEqual(len(records), manifest["native"]["unwind_record_count"])
        for begin, end, info in records:
            self.assertLess(begin, end)
            version = candidate[pe.offset(m.BASE + info, 1)] & 7
            self.assertIn(version, (1, 2))
            if begin >= 0x190000:
                self.assertEqual(version, 1)
        # REL32/ADDR32NB only: rebasing both image and imports leaves bytes equal.
        a = {name: m.BASE + rva for name, rva in m.IMPORT_RVAS.items()}
        a.update(copy_string=m.COPY_STRING, original_send=m.twenty.SENDER_VA)
        first = m.Coff(obj).link(m.BASE, 0x190000, a)[0]
        delta = 0x700000000
        second = m.Coff(obj).link(m.BASE + delta, 0x190000, {k: v + delta for k, v in a.items()})[0]
        self.assertEqual(first, second)

    def test_unknown_and_partial_binary_rejected(self):
        for raw in (original[:-1], candidate):
            with self.assertRaises(ValueError): m.patch_library(raw, obj)

def native(real_io=False):
    if sys.platform != "win32" or struct.calcsize("P") != 8:
        raise ValueError("Requires own x64 Windows process.")
    k = ctypes.WinDLL("kernel32", use_last_error=True)
    k.VirtualAlloc.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_ulong, ctypes.c_ulong]
    k.VirtualAlloc.restype = ctypes.c_void_p
    k.VirtualProtect.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong)]
    k.VirtualProtect.restype = ctypes.c_int
    k.VirtualFree.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_ulong]
    k.FlushInstructionCache.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]
    k.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p,
                             ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
    k.CreateFileW.restype = ctypes.c_void_p
    k.ReadFile.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_void_p]
    k.ReadFile.restype = ctypes.c_int
    k.CloseHandle.argtypes = [ctypes.c_void_p]
    k.CloseHandle.restype = ctypes.c_int
    k.GetProcessHeap.restype = ctypes.c_void_p
    k.HeapAlloc.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_size_t]
    k.HeapAlloc.restype = ctypes.c_void_p
    k.HeapFree.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p]
    k.HeapFree.restype = ctypes.c_int
    ntdll = ctypes.WinDLL("ntdll")
    ntdll.RtlAddFunctionTable.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_uint64]
    ntdll.RtlAddFunctionTable.restype = ctypes.c_ubyte
    ntdll.RtlDeleteFunctionTable.argtypes = [ctypes.c_void_p]
    ntdll.RtlDeleteFunctionTable.restype = ctypes.c_ubyte
    ntdll.RtlLookupFunctionEntry.argtypes = [ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint64), ctypes.c_void_p]
    ntdll.RtlLookupFunctionEntry.restype = ctypes.c_void_p
    base = k.VirtualAlloc(None, 0x4000, 0x3000, 4)
    if not base: raise ctypes.WinError(ctypes.get_last_error())
    callbacks, allocations, state, callback_errors = [], {}, {}, []
    WIN = ctypes.WINFUNCTYPE
    def wrap(kind, func):
        def guarded(*params):
            try:
                return func(*params)
            except BaseException as error:
                callback_errors.append(repr(error))
                return 0
        callback = kind(guarded); callbacks.append(callback)
        return ctypes.cast(callback, ctypes.c_void_p).value
    def create(path, access, share, security, disposition, flags, template):
        state["open"] += 1
        assert ctypes.wstring_at(path) == r"C:\Users\zly\AppData\Local\PallasCustomShout\library20-v1.json"
        assert (access, share, security, disposition, flags, template) == (0x80000000, 1, None, 3, 0x00200080, None)
        if real_io:
            # Only this GENERATED build fixture is opened, NEVER the live path
            # embedded in C. Native flags/ReadFile/heap/close APIs are real.
            handle = k.CreateFileW(str((args.build / "library20-v1.json").resolve()),
                                    access, share, security, disposition, flags, template)
            state["handle"] = handle
            return handle
        return 0x1234 if not state.get("missing") else 0xFFFFFFFFFFFFFFFF
    def heap_alloc(heap, flags, size):
        assert heap == (k.GetProcessHeap() if real_io else 1) and flags == 0 and 3 <= size <= 8193
        state["alloc"] += 1
        if state.get("no_memory"): return None
        if real_io:
            pointer = k.HeapAlloc(heap, flags, size)
            assert pointer
            allocations[pointer] = (None, size)
            return pointer
        buf = ctypes.create_string_buffer(b"\xA5" * (size + 32), size + 32)
        pointer = ctypes.addressof(buf) + 16
        allocations[pointer] = (buf, size)
        return pointer
    def read(handle, pointer, size, count, overlapped):
        assert handle == (state["handle"] if real_io else 0x1234) and overlapped is None
        state["read"] += 1
        if real_io: return k.ReadFile(handle, pointer, size, count, overlapped)
        data = state["file"][:size]
        ctypes.memmove(pointer, data, len(data))
        ctypes.c_uint32.from_address(count).value = len(data)
        return int(not state.get("read_error"))
    def close(handle):
        assert handle == (state["handle"] if real_io else 0x1234)
        state["close"] += 1
        if real_io: return k.CloseHandle(handle)
        return 1
    def free(heap, flags, pointer):
        assert heap == (k.GetProcessHeap() if real_io else 1) and flags == 0
        buf, size = allocations.pop(pointer)
        if real_io:
            state["free"] += 1
            return k.HeapFree(heap, flags, pointer)
        assert buf.raw[:16] == b"\xA5" * 16 and buf.raw[16 + size:] == b"\xA5" * 16
        state["free"] += 1
        return 1
    def copier(destination, source):
        state["copied"] = ctypes.string_at(source)
        state["copy_count"] += 1
        return destination
    def sender(text):
        state["sent"].append(ctypes.string_at(text))
    api = {
        "__imp_CreateFileW": wrap(WIN(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32,
            ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p), create),
        "__imp_ReadFile": wrap(WIN(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32,
            ctypes.c_void_p, ctypes.c_void_p), read),
        "__imp_CloseHandle": wrap(WIN(ctypes.c_int, ctypes.c_void_p), close),
        "__imp_GetProcessHeap": wrap(WIN(ctypes.c_void_p), lambda: None if state.get("no_heap")
                                     else k.GetProcessHeap() if real_io else 1),
        "__imp_HeapAlloc": wrap(WIN(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_size_t), heap_alloc),
        "__imp_HeapFree": wrap(WIN(ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p), free)}
    copy_address = wrap(WIN(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p), copier)
    send_address = wrap(WIN(None, ctypes.c_void_p), sender)
    external = {}
    for i, (name, address) in enumerate(api.items()):
        slot = base + 0x2000 + i * 8
        ctypes.c_uint64.from_address(slot).value = address
        external[name] = slot
    # Nearby absolute-jump stubs make external fixture callbacks REL32 reachable.
    for name, at, target in (("copy_string", 0x1000, copy_address), ("original_send", 0x1020, send_address)):
        stub = b"\x48\xB8" + struct.pack("<Q", target) + b"\xFF\xE0"
        ctypes.memmove(base + at, stub, len(stub)); external[name] = base + at
    code, exports, pdata, _ = m.Coff(obj).link(base, 0, external)
    ctypes.memmove(base, code, len(code))
    protect = ctypes.c_ulong()
    assert k.VirtualProtect(base, 0x2000, 0x20, ctypes.byref(protect))
    k.FlushInstructionCache(ctypes.c_void_p(-1), base, 0x2000)
    table = ctypes.create_string_buffer(pdata)
    registered = bool(ntdll.RtlAddFunctionTable(table, len(pdata) // 12, base))
    assert registered
    image_base = ctypes.c_uint64()
    assert ntdll.RtlLookupFunctionEntry(exports["ReadLocalScheme"] + 40, ctypes.byref(image_base), None)
    assert image_base.value == base
    load = WIN(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)(exports["ReadLocalScheme"])
    send = WIN(None, ctypes.c_void_p)(exports["SendNonempty"])
    cases = 0
    def run(payload, *, source=None, **flags):
        nonlocal cases
        state.clear(); state.update(file=payload, open=0, read=0, alloc=0, close=0, free=0,
                                   copy_count=0, copied=None, sent=[], **flags)
        if source is None:
            source = f'{{"_lps_local_v1":"{len(payload):08X}:{m.fnv1a(payload):08X}","key":1}}'.encode()
        text = ctypes.create_string_buffer(source)
        dest = ctypes.create_string_buffer(8)
        result = load(ctypes.addressof(dest), ctypes.addressof(text))
        assert not callback_errors, callback_errors
        assert result == ctypes.addressof(dest) and state["copy_count"] == 1
        assert not allocations
        assert state["close"] == int(state["open"] > 0 and not state.get("missing"))
        cases += 1
        return state["copied"]
    def empty(raw):
        value = json.loads(raw)
        assert all(value[str(i)] == "" for i in range(20))
        for i in range(20):
            buf = ctypes.create_string_buffer(value[str(i)].encode()); send(ctypes.addressof(buf))
        assert state["sent"] == []
    try:
        real = (args.build / "library20-v1.json").read_bytes()
        assert len(real) == 2294 and run(real) == real
        assert json.loads(state["copied"])["19"].endswith("LIB-END-20")
        if real_io:
            for _ in range(2):
                assert run(real) == real
                assert state["read"] == state["alloc"] == state["close"] == state["free"] == 1
            return dict(passed=True, cases=cases, actual_win32_file_io=True,
                file_scope="Generated build/library20-v1.json fixture ONLY", own_process_only=True,
                real_dll_loaded=False, live_runtime_files_accessed=False, real_game_send_verified=False)
        for n in (2, 2046, 2047, 4096, 8192):
            raw = b"{}" if n == 2 else b'{"x":"' + b"a" * (n - 8) + b'"}'
            assert len(raw) == n and run(raw) == raw
        empty(run(b"a" * 8193))
        empty(run(b"x"))
        short = f'{{"_lps_local_v1":"{len(real):08X}:{m.fnv1a(real):08X}",'.encode()
        for flags in (dict(missing=True), dict(no_memory=True), dict(no_heap=True), dict(read_error=True)):
            empty(run(real, **flags))
        for file in (real[:-1], real + b"x", bytes([real[0] ^ 1]) + real[1:]):
            empty(run(file, source=short))
        with_nul = b"{\0}"
        empty(run(with_nul))
        prefix = b'{"_lps_local_v1":"'
        for length in range(19):
            empty(run(real, source=(short[:len(prefix) + length])))
        empty(run(real, source=prefix + b"00000000:00000000\","))
        empty(run(real, source=prefix + b"00002001:00000000\","))
        empty(run(real, source=prefix + b"000008F6:ebcba822\","))
        for regular in (b"{}", b'{"0":"normal"}', b"x", b""):
            assert run(b"unused", source=regular) == regular and state["open"] == 0
        run(real)
        send(None); zero = ctypes.create_string_buffer(b""); send(ctypes.addressof(zero))
        assert state["sent"] == []
        for i in range(20):
            text = json.loads(real)[str(i)].encode()
            buf = ctypes.create_string_buffer(text); send(ctypes.addressof(buf))
            assert state["sent"][-1] == text
            cases += 1
        assert not callback_errors, callback_errors
        return dict(passed=True, cases=cases, mocked_win32=True, own_process_only=True,
            native_unwind_registered=True, capacity_boundary=8192, real_dll_loaded=False,
            real_files_read=False, real_game_send_verified=False)
    finally:
        if registered: assert ntdll.RtlDeleteFunctionTable(table)
        assert k.VirtualFree(base, 0, 0x8000)

if args.child or args.real_io_child:
    print(json.dumps(native(real_io=args.real_io_child))); raise SystemExit(0)
result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Offline))
if not result.wasSuccessful(): raise SystemExit(1)
child = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--build", str(args.build), "--child"],
                       capture_output=True, text=True, timeout=30)
if child.returncode: raise SystemExit(f"Own-process fixture failed: {child.returncode}\n{child.stdout}\n{child.stderr}")
file_child = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--build", str(args.build), "--real-io-child"],
                            capture_output=True, text=True, timeout=30)
if file_child.returncode:
    raise SystemExit(f"Own-process file fixture failed: {file_child.returncode}\n{file_child.stdout}\n{file_child.stderr}")
report = dict(unit_tests=result.testsRun, unit_tests_passed=True, native=json.loads(child.stdout),
    native_file_io=json.loads(file_child.stdout),
    candidate_dll_sha256=m.twenty.sha256(candidate), installed=False, runtime_verified=False, game_send_verified=False)
with (args.build / "validation.library.json").open("x", encoding="utf-8") as stream:
    json.dump(report, stream, indent=2)
print(json.dumps(report))
