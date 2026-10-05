"""OFFLINE only: exact PE changes and own-process bank/ABI/guard fixtures.

Never load a Tencent DLL, execute Tencent instructions, access a game process,
or call a real sender. All executable code is our compiled C/ASM and callbacks.
"""
from __future__ import annotations

import argparse
import ctypes
import json
from pathlib import Path
import struct
import subprocess
import sys
import unittest

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--build", type=Path, required=True)
parser.add_argument("--baseline-build", type=Path, required=True)
parser.add_argument("--child", action="store_true")
parser.add_argument("--ten-profile", action="store_true", help="Eight banks of ten; no individual character cap.")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
args.build = args.build.resolve()
if root / "build" not in args.build.parents:
    raise ValueError("Only generated project build fixtures are supported.")
sys.path.insert(0, str(root / "tools/native"))
import PallasBanks80 as m

original = (root / "engine/assets/TenPallas.original.dll").read_bytes()
obj = (args.build / "library80-banks.obj").read_bytes()
candidate = (args.build / ("TenPallas.banks10.experimental.dll" if args.ten_profile else "TenPallas.banks80.experimental.dll")).read_bytes()
manifest = json.loads((args.build / "manifest.json").read_bytes())
if args.ten_profile:
    import PallasBanksTen as ten
    if manifest["experiment"] != ten.EXPERIMENT:
        raise ValueError("Wrong ten-key test profile.")
scheme = m.library.twenty.read_scheme(args.build / "scheme80.json")
INVALID = (1 << 64) - 1


class Offline(unittest.TestCase):
    def test_reproducible(self):
        rebuilt, native, changes = m.patch_banks(original, obj)
        self.assertEqual(rebuilt, candidate)
        self.assertEqual(native, manifest["native"])
        self.assertEqual(changes, manifest["changes"])
        self.assertEqual(m.library.twenty.sha256(obj), manifest["object_sha256"])
        self.assertEqual(m.library.twenty.sha256(candidate), manifest["candidate_dll_sha256"])

    def test_only_declared_native_text_ranges(self):
        baseline, _ = m.library.twenty.patch_copy(original)
        pe = m.library.twenty.PE64(baseline)
        allowed = set()
        for entry in manifest["native"]["hooks"] + manifest["changes"]:
            at = entry["file_offset"]
            old, new = bytes.fromhex(entry["before_hex"]), bytes.fromhex(entry["after_hex"])
            self.assertEqual(baseline[at:at + len(old)], old)
            self.assertEqual(candidate[at:at + len(new)], new)
            allowed.update(range(at, at + len(old)))
        text = pe.sections[0]
        changed = {i for i in range(text["raw"], text["raw"] + text["raw_size"])
                   if baseline[i] != candidate[i]}
        self.assertTrue(changed <= allowed)
        # Original event helper, panel-held/primary-busy gate, prologue/epilogue,
        # sender address and ten-slot statistics logic are not rewritten.
        callback = pe.offset(0x1800424C4, 0xD5)
        self.assertTrue(all(i in allowed for i in range(callback, callback + 0xD5)
                            if candidate[i] != baseline[i]))

    def test_noncode_imports_certificate_and_one_rx_section(self):
        baseline, _ = m.library.twenty.patch_copy(original)
        before, after = m.library.twenty.PE64(baseline), m.library.twenty.PE64(candidate)
        self.assertEqual(after.sections[:-1], before.sections)
        self.assertEqual(after.sections[-1]["name"], b".lpslib")
        flags = struct.unpack_from("<I", candidate, after.sections[-1]["header"] + 36)[0]
        self.assertEqual(flags, 0x60000020)  # RX, not RW or RWX
        for s in before.sections:
            if s["name"] != b".text":
                self.assertEqual(candidate[s["raw"]:s["raw"] + s["raw_size"]],
                                 baseline[s["raw"]:s["raw"] + s["raw_size"]])
        self.assertEqual(candidate[after.certificate_offset:], baseline[before.certificate_offset:])
        m.library.verify_imports(candidate)
        coff = m.library.Coff(obj)
        self.assertTrue(all(not s["data"] for s in coff.sections if s["name"] in (".data", ".bss")))

    def test_unwind_aslr_and_adapter(self):
        pe = m.library.twenty.PE64(candidate)
        at = pe.offset(m.BASE + pe.exception_rva, pe.exception_size)
        records = [struct.unpack_from("<III", candidate, p) for p in range(at, at + pe.exception_size, 12)]
        wrapper = int(manifest["native"]["bank_entry_points"]["BankNormalizeWrapper"], 16) - m.BASE
        matches = [(b, e, u) for b, e, u in records if b == wrapper]
        self.assertEqual(len(matches), 1)
        _, end, unwind = matches[0]
        self.assertGreater(end, wrapper)
        self.assertEqual(candidate[pe.offset(m.BASE + unwind, 1)] & 7, 1)
        offset = pe.offset(m.BASE + wrapper, 4)
        self.assertEqual(candidate[offset:offset + 4], bytes.fromhex("4883ec48"))
        self.assertTrue(all(b < e and (not i or records[i - 1][1] <= b)
                            for i, (b, e, u) in enumerate(records)))
        externals = {name: m.BASE + rva for name, rva in m.library.IMPORT_RVAS.items()}
        externals.update(copy_string=m.library.COPY_STRING, original_send=m.library.twenty.SENDER_VA)
        a = m.library.Coff(obj).link(m.BASE, 0x190000, externals)[0]
        delta = 0x700000000
        b = m.library.Coff(obj).link(m.BASE + delta, 0x190000, {k: v + delta for k, v in externals.items()})[0]
        self.assertEqual(a, b)

    def test_real_chinese_full_library_and_unchanged_seed(self):
        raw, response, metrics = ten.artifacts(scheme) if args.ten_profile else m.count.artifacts(scheme)
        self.assertEqual(raw, (args.build / "library80.json").read_bytes())
        self.assertEqual(response, (args.build / "local-response80.json").read_bytes())
        self.assertGreater(len(raw), 8192)
        if args.ten_profile:
            self.assertIsNone(metrics["single_message_utf16_limit"])
            self.assertEqual(metrics["bank_count"], 8)
            self.assertEqual(metrics["bank_size"], 10)
            self.assertFalse(metrics["function_keys_send"])
            for value in ("中" * 101, "中" * 500, "\U0001F600" * 500):
                long = dict(scheme, **{"0": value})
                long_raw, rsp, _ = ten.artifacts(long)
                self.assertEqual(json.loads(long_raw)["0"], value)
                self.assertLess(len(__import__('base64').b64decode(json.loads(rsp)["shout_message"])), 2047)
            with self.assertRaises(ValueError): ten.artifacts(dict(scheme, **{"0": "中" * 23000}))
        else:
            self.assertFalse(metrics["whitespace_padding"])
            self.assertTrue(all(50 < len(scheme[str(i)]) <= 100 for i in range(20, 80)))
            self.assertEqual(manifest["metrics"]["bank_count"], 4)
            seed = {str(i): scheme[str(i)] for i in range(20)}
            seed.update(title=scheme["title"], key=scheme["key"])
            self.assertEqual(m.library.twenty.sha256(m.library.artifacts(seed)[0]), manifest["seed_library_sha256"])

    def test_foreign_dll_rejected(self):
        for bad in (original[:-1], candidate):
            with self.assertRaises(ValueError): m.patch_banks(bad, obj)


def native():
    banks = 8 if args.ten_profile else 4
    size = 10 if args.ten_profile else 20
    keys = list(range(0x30, 0x3A)) + ([] if args.ten_profile else list(range(0x70, 0x7A)))
    k = ctypes.WinDLL("kernel32", use_last_error=True)
    k.VirtualAlloc.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint32]
    k.VirtualAlloc.restype = ctypes.c_void_p
    k.VirtualProtect.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_void_p]
    k.VirtualProtect.restype = ctypes.c_int
    k.VirtualFree.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32]
    k.FlushInstructionCache.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]
    nt = ctypes.WinDLL("ntdll")
    nt.RtlAddFunctionTable.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint64]
    nt.RtlAddFunctionTable.restype = ctypes.c_ubyte
    nt.RtlDeleteFunctionTable.argtypes = [ctypes.c_void_p]
    nt.RtlDeleteFunctionTable.restype = ctypes.c_ubyte
    nt.RtlLookupFunctionEntry.argtypes = [ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint64), ctypes.c_void_p]
    nt.RtlLookupFunctionEntry.restype = ctypes.c_void_p
    base = k.VirtualAlloc(None, 0x4000, 0x3000, 4)
    if not base: raise ctypes.WinError(ctypes.get_last_error())
    WIN = ctypes.WINFUNCTYPE
    sent, callbacks = [], []
    def record(p): sent.append(ctypes.string_at(p))
    callback = WIN(None, ctypes.c_void_p)(record); callbacks.append(callback)
    target = ctypes.cast(callback, ctypes.c_void_p).value
    stub = b"\x48\xB8" + struct.pack("<Q", target) + b"\xFF\xE0"
    ctypes.memmove(base + 0x2000, stub, len(stub))
    # Reader imports are resolved but NEVER invoked in this banking child.
    externals = {name: base + 0x3000 + i * 8 for i, name in enumerate(m.library.IMPORT_RVAS)}
    externals.update(copy_string=base + 0x2020, original_send=base + 0x2000)
    code, exports, pdata, _ = m.library.Coff(obj).link(base, 0, externals)
    assert len(code) < 0x1800
    ctypes.memmove(base, code, len(code))
    adapter, own, apdata, _ = m.library.Coff((args.build / "banks-adapter.obj").read_bytes()).link(
        base, 0x1800, {"BankNormalizeWrapper": exports["BankNormalizeWrapper"]})
    assert len(adapter) < 0x800
    ctypes.memmove(base + 0x1800, adapter, len(adapter))
    old = ctypes.c_uint32()
    assert k.VirtualProtect(base, 0x3000, 0x20, ctypes.byref(old))
    assert k.FlushInstructionCache(ctypes.c_void_p(-1), base, 0x3000)
    rows = [pdata[i:i + 12] for i in range(0, len(pdata), 12)] + [apdata[i:i + 12] for i in range(0, len(apdata), 12)]
    rows.sort(key=lambda r: struct.unpack_from("<I", r)[0])
    table = ctypes.create_string_buffer(b"".join(rows))
    registered = bool(nt.RtlAddFunctionTable(table, len(rows), base)); assert registered
    image_base = ctypes.c_uint64()
    for address in (exports["BankNormalizeWrapper"] + 5, exports["BankNormalize"] + 8, own["TestBankAdapter"] + 10):
        assert nt.RtlLookupFunctionEntry(address, ctypes.byref(image_base), None) and image_base.value == base
    normalize = WIN(ctypes.c_uint64, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32)(exports["BankNormalize"])
    adapter_fn = WIN(None, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p)(own["TestBankAdapter"])
    send = WIN(None, ctypes.c_void_p)(exports["SendNonempty"])
    cases = 0
    def controller():
        # Red zones protect both sides of owned vector; messages are canaries.
        vector = ctypes.create_string_buffer(b"\xA5" * (81 * 32 + 32), 81 * 32 + 32)
        begin = ctypes.addressof(vector) + 16
        ctypes.memset(begin + 80 * 32, 0, 32)
        ctypes.c_uint64.from_address(begin + 80 * 32 + 24).value = 15
        c = ctypes.create_string_buffer(0x100)
        struct.pack_into("<QQ", c, 0x40, begin, begin + 81 * 32)
        c[0x92] = b"\x01"
        return c, vector, begin
    c, vector, begin = controller()
    def call(key, event=0x100, *, ctrl=c):
        nonlocal cases
        result = (ctypes.c_uint64 * 7)()
        adapter_fn(ctypes.addressof(ctrl), key, event, ctypes.addressof(result))
        assert result[2:] == [event, key, 0x55667788, 0x11223344, ctypes.addressof(ctrl)]
        direct = normalize(ctypes.addressof(ctrl), key, event)
        assert direct == result[0]
        assert result[1] == (direct >> 32)
        assert vector.raw[:16 + 80 * 32] == b"\xA5" * (16 + 80 * 32)
        assert vector.raw[-16:] == b"\xA5" * 16
        cases += 1
        return direct
    def selected(key, bank):
        packed = call(key)
        local = key - 0x30 if 0x30 <= key <= 0x39 else (key - 0x70 + 1) % 10 + 10
        assert packed & 0xFFFFFFFF == bank * size + local
        assert 0x30 <= packed >> 32 <= 0x39  # Original ten statistic counters.
        return packed & 0xFFFFFFFF
    try:
        slots = []
        for bank in range(banks):
            slots.extend(selected(key, bank) for key in keys)
            assert call(0x22) == INVALID
            for _ in range(5): assert call(0x22) == INVALID
            assert selected(0x31, (bank + 1) % banks) == ((bank + 1) % banks) * size + 1
            assert call(0x22, 0x101) == INVALID
        assert sorted(slots) == list(range(80))
        assert call(0x21) == INVALID
        selected(0x31, banks - 1)  # Previous wraps from first to last.
        assert call(0x22) == INVALID
        selected(0x31, banks - 1)  # Opposite page cannot bypass the held latch.
        assert call(0x22, 0x101) == INVALID
        selected(0x31, banks - 1)  # Only matching PageUp release clears the latch.
        c[0x92] = b"\x00"
        assert call(0x21, 0x101) == INVALID
        assert call(0x22) == INVALID
        selected(0x31, banks - 1)  # The native panel gate, not normalizer, decides sends.
        c[0x92] = b"\x01"
        assert call(0x22) == INVALID; assert call(0x22, 0x101) == INVALID
        selected(0x31, 0)
        for key in range(256):
            if key not in (*keys, 0x21, 0x22):
                assert call(key) == INVALID
        for event in (0, 0x104, 0x105, 0x102): assert call(0x31, event) == INVALID
        other, other_vector, other_begin = controller()
        assert call(0x22) == INVALID; assert call(0x22, 0x101) == INVALID
        assert call(0x31, ctrl=other) & 0xFFFFFFFF == 1
        selected(0x31, 1)  # State is per vector, never a writable global.
        for end in (begin, begin - 32, begin + 20 * 32, begin + 80 * 32, begin + 82 * 32):
            struct.pack_into("<Q", c, 0x48, end)
            snapshot = vector.raw
            assert call(0x31) == INVALID and vector.raw == snapshot
        struct.pack_into("<Q", c, 0x48, begin + 81 * 32)
        state = begin + 80 * 32
        saved = ctypes.string_at(state, 32)
        corruptions = ((0, str(banks).encode()), (1, b"3"), (2, b"x"), (16, struct.pack("<Q", 3)),
                       (24, struct.pack("<Q", 16)), (16, struct.pack("<Q", 0)))
        for at, value in corruptions:
            ctypes.memmove(state + at, value, len(value)); snapshot = vector.raw
            assert call(0x31) == INVALID and vector.raw == snapshot
            ctypes.memmove(state, saved, 32)
        assert normalize(None, 0x31, 0x100) == INVALID
        # Strict UTF-8, UTF-16 units, no truncation; record-only sender callback.
        valid = [b"normal", ("中" * 100).encode(), b"a" * 100, ("\U0001F600" * 50).encode(),
                 ("中" * 98 + "\U0001F600").encode(), *[scheme[str(i)].encode() for i in range(80)]]
        if args.ten_profile:
            valid.extend([b"a" * 101, ("中" * 101).encode(), ("中" * 500).encode(),
                          ("中" * 10000).encode(), ("\U0001F600" * 1000).encode(), b"a" * 65535])
        for value in valid:
            buf = ctypes.create_string_buffer(value); before = len(sent)
            send(ctypes.addressof(buf)); assert len(sent) == before + 1 and sent[-1] == value
            cases += 1
        invalid = [b"", b"a\n", b"\x7F", b"\x80", b"\xC0\x80",
                   b"\xE0\x80\x80", b"\xED\xA0\x80", b"\xF4\x90\x80\x80", b"\xFF",
                   b"\xC2", b"\xE1\x80", b"\xF0\x90\x80"]
        if args.ten_profile:
            invalid.extend([b"a" * 65536, b"a" * 65535 + b"\xC2"])
        else:
            invalid.extend([b"a" * 101, ("中" * 101).encode(), ("\U0001F600" * 51).encode(),
                            ("中" * 99 + "\U0001F600").encode()])
        send(None)
        for value in invalid:
            before = len(sent); buf = ctypes.create_string_buffer(value)
            send(ctypes.addressof(buf)); assert len(sent) == before
            cases += 1
        return dict(passed=True, cases=cases, unique_message_slots=80, bank_count=banks, bank_size=size,
                    adapter_registers_preserved=True, native_unwind_registered=True,
                    held_page_debounced=True, state_is_owned_sso=True, red_zones_unchanged=True,
                    native_utf8_guard_units=None if args.ten_profile else 100,
                    function_keys_send=not args.ten_profile, own_process_only=True, record_only_sender=True,
                    tencent_dll_loaded=False, actual_game_callback_or_send_tested=False)
    finally:
        if registered: assert nt.RtlDeleteFunctionTable(table)
        assert k.VirtualFree(base, 0, 0x8000)


if args.child:
    print(json.dumps(native())); raise SystemExit(0)

result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Offline))
if not result.wasSuccessful(): raise SystemExit(1)
adapter_obj = args.build / "banks-adapter.obj"
if adapter_obj.exists(): raise ValueError("Preserve prior results: use a NEW build directory.")
subprocess.run([r"D:\LLVM\bin\clang.exe", "--target=x86_64-pc-windows-msvc", "-c",
                str(root / "tests/fixtures/banks-adapter.asm"), "-o", str(adapter_obj)], check=True, capture_output=True)
child = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--build", str(args.build),
                        "--baseline-build", str(args.baseline_build), "--child"] + (["--ten-profile"] if args.ten_profile else []),
                       capture_output=True, text=True, timeout=30)
if child.returncode: raise SystemExit(f"Own banks child failed: {child.returncode}\n{child.stdout}\n{child.stderr}")
bank_report = json.loads(child.stdout)
readers = {}
for flag in ("--child", "--real-io-child"):
    command = [sys.executable, str(root / "tests/Test-Library-Native.py"), "--build", str(args.baseline_build),
               flag, "--reader-fixture", str(args.build / "library80.json"), "--fixture-max-units", "0" if args.ten_profile else "100",
               "--banks-object-build", str(args.build)]
    child = subprocess.run(command, capture_output=True, text=True, timeout=30)
    if child.returncode: raise SystemExit(f"Own banks reader failed: {child.returncode}\n{child.stdout}\n{child.stderr}")
    readers[flag] = json.loads(child.stdout)
    assert readers[flag]["accepted"] and readers[flag]["passed"]
report = dict(unit_tests=result.testsRun, unit_tests_passed=True, own_banks=bank_report,
              reader_tests=readers, library_bytes=manifest["metrics"]["library_json_utf8_bytes"],
              candidate_dll_sha256=manifest["candidate_dll_sha256"], installed=False,
              game_receive_verified=False, game_send_verified=False)
m.library.twenty.write_new(args.build / "validation.banks80.json", m.library.twenty.compact(report))
print(json.dumps(report))
