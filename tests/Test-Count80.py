"""Offline real-Chinese/count patch and own-process receive-index tests only."""
from __future__ import annotations

import argparse
import base64
import copy
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
parser.add_argument("--index-child", action="store_true")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "tools/native"))
import PallasCount80 as m

baseline = (args.baseline_build / "TenPallas.library.experimental.dll").read_bytes()
candidate = (args.build / "TenPallas.count80.experimental.dll").read_bytes()
raw = (args.build / "library80.json").read_bytes()
scheme = m.library.twenty.read_scheme(args.build / "scheme80.json")
manifest = json.loads((args.build / "manifest.json").read_bytes())


def index_native():
    # Run ONLY our assembled fragment in our own allocation, never a Tencent DLL.
    k = ctypes.WinDLL("kernel32", use_last_error=True)
    k.VirtualAlloc.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint32]
    k.VirtualAlloc.restype = ctypes.c_void_p
    k.VirtualProtect.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_void_p]
    k.VirtualProtect.restype = ctypes.c_int
    k.VirtualFree.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32]
    k.FlushInstructionCache.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]
    obj = m.library.Coff((args.build / "receiver-many.obj").read_bytes())
    fragment = next(s["data"] for s in obj.sections if s["name"] == ".text")
    assert fragment == m.RECEIVER_MANY + b"\xC3"
    # Win64 wrapper: preserve RDI, shadow space/alignment; convert argument to
    # exact original receive registers, and return fragment's RCX slot as EAX.
    wrapper = bytearray.fromhex("574883ec2089cf448d4701e80000000089c84883c4205fc3")
    struct.pack_into("<i", wrapper, 12, 0x100 - 16)
    base = k.VirtualAlloc(None, 4096, 0x3000, 4)
    if not base:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        ctypes.memmove(base, bytes(wrapper), len(wrapper))
        ctypes.memmove(base + 0x100, fragment, len(fragment))
        old = ctypes.c_uint32()
        assert k.VirtualProtect(base, 4096, 0x20, ctypes.byref(old))
        assert k.FlushInstructionCache(ctypes.c_void_p(-1), base, 4096)
        function = ctypes.WINFUNCTYPE(ctypes.c_uint32, ctypes.c_uint32)(base)
        slots = [function(i) for i in range(80)]
        assert slots == [(i // 10) * 10 + ((i + 1) % 10) for i in range(80)]
        assert sorted(slots) == list(range(80))
        assert slots[:20] == list(range(1, 10)) + [0] + list(range(11, 20)) + [10]
        return dict(passed=True, index_cases=80, first_twenty_slots_unchanged=True,
                    eighty_slots_bounded_and_unique=True, own_process_only=True,
                    real_dll_loaded=False, game_send_verified=False)
    finally:
        assert k.VirtualFree(base, 0, 0x8000)


if args.index_child:
    print(json.dumps(index_native()))
    raise SystemExit(0)


class CountOnly(unittest.TestCase):
    def test_reproducible_patch(self):
        rebuilt, changes = m.patch_count(baseline)
        self.assertEqual(rebuilt, candidate)
        self.assertEqual(changes, manifest["changes"])
        self.assertEqual(m.library.twenty.sha256(candidate), manifest["candidate_dll_sha256"])

    def test_only_manifest_receive_count_ranges_differ(self):
        inverse = bytearray(candidate)
        allowed = set()
        for change in manifest["changes"]:
            at = change["file_offset"]
            before, after = bytes.fromhex(change["before_hex"]), bytes.fromhex(change["after_hex"])
            self.assertEqual(candidate[at:at + len(after)], after)
            inverse[at:at + len(before)] = before
            allowed.update(range(at, at + len(before)))
        self.assertEqual(inverse, baseline)
        self.assertEqual(m.library.twenty.PE64(baseline).sections, m.library.twenty.PE64(candidate).sections)
        self.assertTrue(all(i in allowed for i, (a, b) in enumerate(zip(baseline, candidate)) if a != b))

    def test_real_chinese_no_whitespace_padding(self):
        rebuilt, response, metrics = m.artifacts(scheme)
        self.assertEqual(raw, rebuilt)
        self.assertGreater(len(raw), 8192)
        self.assertEqual(raw, m.library.twenty.compact(scheme))
        self.assertEqual(response, (args.build / "local-response80.json").read_bytes())
        self.assertEqual(metrics, manifest["metrics"])
        self.assertTrue(all(all(ord(c) > 127 for c in scheme[str(i)]) for i in range(20, 80)))
        self.assertTrue(all(m.library.twenty.utf16_length(scheme[str(i)]) <= m.MAX_UNITS for i in range(80)))
        self.assertTrue(all(m.library.twenty.utf16_length(scheme[str(i)]) > 50 for i in range(20, 80)))
        self.assertEqual(len(set(scheme[str(i)] for i in range(20, 80))), 60)

    def test_first_twenty_source_preserved(self):
        seed = {str(i): scheme[str(i)] for i in range(20)}
        seed.update(title=scheme["title"], key=scheme["key"])
        self.assertEqual(m.make_scheme(seed), scheme)
        self.assertEqual(m.library.twenty.sha256(m.library.artifacts(seed)[0]), manifest["seed_library_sha256"])

    def test_short_native_bootstrap_and_checksum(self):
        response = json.loads((args.build / "local-response80.json").read_bytes())
        short = base64.b64decode(response["shout_message"], validate=True)
        preview = json.loads(short)
        self.assertLessEqual(len(short), 2046)
        self.assertEqual(preview["_lps_local_v1"], f'{len(raw):08X}:{m.library.fnv1a(raw):08X}')
        for i in range(20):
            self.assertEqual(preview[str(i)], scheme[str(i)] if i < 10 else "")

    def test_schema_and_length_guards(self):
        for label, value in (("0", "x" * 101), ("20", "中" * 101), ("79", ""), ("20", "\ud800"),
                             ("key", True), ("key", 3), ("title", "x" * 101), ("20", "a\n")):
            bad = dict(scheme); bad[label] = value
            with self.assertRaises((ValueError, UnicodeError)): m.artifacts(bad)
        for bad in (dict(scheme, **{"80": "extra"}), {k: v for k, v in scheme.items() if k != "79"}):
            with self.assertRaises(ValueError): m.artifacts(bad)
        small = dict(scheme)
        for i in range(20, 80): small[str(i)] = "少"
        with self.assertRaises(ValueError): m.artifacts(small)
        for value in ("中" * 100, "\U0001F600" * 50):
            valid = dict(scheme); valid["20"] = value
            m.artifacts(valid)
        invalid = dict(scheme); invalid["20"] = "\U0001F600" * 51
        with self.assertRaises(ValueError): m.artifacts(invalid)

    def test_unknown_or_partial_dll_rejected(self):
        for value in (candidate, baseline[:-1], bytes([baseline[0] ^ 1]) + baseline[1:]):
            with self.assertRaises(ValueError): m.patch_count(value)


result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(CountOnly))
if not result.wasSuccessful():
    raise SystemExit(1)
object_path = args.build / "receiver-many.obj"
if object_path.exists():
    raise ValueError("Use a fresh build; preserve previous fixture outputs.")
subprocess.run([r"D:\LLVM\bin\clang.exe", "--target=x86_64-pc-windows-msvc", "-c",
                str(root / "tools/native/receiver-many.asm"), "-o", str(object_path)], check=True, capture_output=True)
child = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--build", str(args.build),
                        "--baseline-build", str(args.baseline_build), "--index-child"],
                       capture_output=True, text=True, timeout=30)
if child.returncode:
    raise SystemExit(f"Own index fixture failed: {child.returncode}\n{child.stdout}\n{child.stderr}")
index_report = json.loads(child.stdout)
readers = {}
for flag in ("--child", "--real-io-child"):
    for capacity in (8192, 65536):
        command = [sys.executable, str(root / "tests/Test-Library-Native.py"), "--build", str(args.baseline_build),
                   flag, "--reader-fixture", str(args.build / "library80.json"), "--fixture-max-units", str(m.MAX_UNITS)]
        if capacity == 8192: command.append("--control-baseline")
        child = subprocess.run(command, capture_output=True, text=True, timeout=30)
        if child.returncode:
            raise SystemExit(f"Own Chinese reader fixture failed: {child.returncode}\n{child.stdout}\n{child.stderr}")
        report = json.loads(child.stdout)
        assert report["accepted"] == (capacity == 65536) and report["passed"]
        readers[f"{capacity}:{flag}"] = report
report = dict(unit_tests=result.testsRun, unit_tests_passed=True, own_receive_index=index_report,
    reader_tests=readers, library_bytes=len(raw), actual_chinese_message_count=80,
    native_bound_message_count=20, candidate_dll_sha256=manifest["candidate_dll_sha256"],
    installed=False, game_receive_verified=False, game_send_verified=False)
m.library.twenty.write_new(args.build / "validation.count80.json", m.library.twenty.compact(report))
print(json.dumps(report))
