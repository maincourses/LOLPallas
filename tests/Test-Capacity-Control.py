"""Byte-level isolation, legacy JSON and guards for the offline capacity control."""
from __future__ import annotations

import argparse
import base64
import copy
import json
from pathlib import Path
import struct
import sys
import unittest

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--build", type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "tools/native"))
import PallasCapacityControl as control

m = control.library
baseline = (args.build / "TenPallas.baseline8k.dll").read_bytes()
candidate = (args.build / "TenPallas.library.experimental.dll").read_bytes()
manifest = json.loads((args.build / "manifest.json").read_bytes())
scheme = m.twenty.read_scheme(root / "experiments/local-library/scheme20.example.json")


class CapacityOnly(unittest.TestCase):
    def test_exact_baseline_and_candidate_hashes(self):
        self.assertEqual(m.twenty.sha256(baseline), control.BASELINE_SHA256)
        self.assertEqual(m.twenty.sha256(candidate), manifest["candidate_dll_sha256"])
        for obj_name, expected in (("baseline8k.obj", baseline), ("library20.obj", candidate)):
            rebuilt, info = m.patch_library((root / "engine/assets/TenPallas.original.dll").read_bytes(),
                                            (args.build / obj_name).read_bytes())
            self.assertEqual(rebuilt, expected)
            self.assertEqual(info, manifest["native"])

    def test_only_range_check_immediates_differ(self):
        report = control.verify_capacity_only(baseline, candidate, manifest["native"], manifest["native"])
        self.assertEqual(report, manifest["comparison"])
        self.assertEqual(report["changed_byte_count"], 3)
        at = report["range_check_file_offset"]
        self.assertEqual([x["file_offset"] - at for x in report["changed_bytes"]], [5, 6, 10])

    def test_validator_rejects_unrelated_changes(self):
        pe = m.twenty.PE64(baseline)
        positions = (0x10, pe.sections[0]["raw"], pe.sections[-1]["raw"] + 0x234,
                     pe.certificate_offset, manifest["comparison"]["range_check_file_offset"])
        for at in positions:
            altered = bytearray(candidate); altered[at] ^= 1
            with self.assertRaises(ValueError):
                control.verify_capacity_only(baseline, altered, manifest["native"], manifest["native"])
        with self.assertRaises(ValueError):
            control.verify_capacity_only(candidate, candidate, manifest["native"], manifest["native"])
        info = copy.deepcopy(manifest["native"]); info["payload_bytes"] += 1
        with self.assertRaises(ValueError):
            control.verify_capacity_only(baseline, candidate, manifest["native"], info)

    def test_pe_loader_and_original_keyboard_bytes_identical(self):
        p8, p64 = m.twenty.PE64(baseline), m.twenty.PE64(candidate)
        self.assertEqual(p8.sections, p64.sections)
        # Every header/data directory, original section, import table,
        # keyboard callback, twenty-key helper and unwind row is unchanged.
        self.assertEqual(baseline[:p8.sections[-1]["raw"]], candidate[:p8.sections[-1]["raw"]])
        at = p8.offset(m.BASE + p8.exception_rva, p8.exception_size)
        self.assertEqual(baseline[at:at + p8.exception_size], candidate[at:at + p8.exception_size])
        self.assertEqual(manifest["required_legacy_pallas_sha256"], m.twenty.PALLAS_LOCAL_SHA256)

    def test_default_c_profile_stays_8192(self):
        self.assertEqual(m.MAX_LIBRARY_BYTES, 8192)
        self.assertEqual(manifest["metrics"]["library_limit"], 65536)
        self.assertEqual(manifest["metrics"]["compact_scheme_validation_limit"], 8192)
        for capacity, command in manifest["compile_commands"].items():
            self.assertIn(f"-DLPS_LIBRARY_CAPACITY={capacity}", command)
        self.assertFalse(manifest["installed"])
        self.assertFalse(manifest["runtime_verified"])
        self.assertFalse(manifest["game_send_verified"])

    def test_padding_preserves_every_message_and_bootstrap(self):
        old_raw, old_response, metrics = m.artifacts(scheme)
        old_envelope = json.loads(old_response)
        old_preview = json.loads(base64.b64decode(old_envelope["shout_message"]))
        for fixture in manifest["fixtures"]:
            raw, response = control.padded_artifacts(scheme, fixture["bytes"])
            self.assertEqual(raw, (args.build / "fixtures" / fixture["filename"]).read_bytes())
            self.assertEqual(response, (args.build / "fixtures" / f'response-{len(raw)}.json').read_bytes())
            self.assertEqual(raw[:len(old_raw)], old_raw)
            self.assertEqual(raw[len(old_raw):], b" " * (len(raw) - len(old_raw)))
            self.assertEqual(json.loads(raw), scheme)
            preview_raw = base64.b64decode(json.loads(response)["shout_message"], validate=True)
            self.assertEqual(len(preview_raw), metrics["bootstrap_json_utf8_bytes"])
            preview = json.loads(preview_raw)
            self.assertEqual(preview.pop("_lps_local_v1"), f'{len(raw):08X}:{m.fnv1a(raw):08X}')
            self.assertEqual(preview, {k: v for k, v in old_preview.items() if k != "_lps_local_v1"})

    def test_message_count_and_length_guards_remain(self):
        for key, value in (("0", "x" * 51), ("title", "x" * 51), ("0", "\U0001F600" * 26),
                           ("19", ""), ("0", "a\n"), ("0", "\ud800"), ("key", True), ("key", 3)):
            bad = dict(scheme); bad[key] = value
            with self.assertRaises((ValueError, UnicodeError)): control.padded_artifacts(bad, 65536)
        for bad in (dict(scheme, **{"20": "extra"}), {k: v for k, v in scheme.items() if k != "19"}):
            with self.assertRaises(ValueError): control.padded_artifacts(bad, 65536)
        for size in (True, 0, 2293, 65538):
            with self.assertRaises(ValueError): control.padded_artifacts(scheme, size)

    def test_unsigned_range_check_boundaries(self):
        for capacity in (8192, 65536):
            code = control.range_check(capacity)
            subtract = struct.unpack_from("<I", code, 4)[0]
            compare = struct.unpack_from("<I", code, 9)[0]
            # Check both neighborhoods plus large unsigned wraparound values.
            for length in (*range(0, 4), *range(capacity - 3, capacity + 4),
                           0x7FFFFFFF, 0x80000000, 0xFFFFFFFE, 0xFFFFFFFF):
                rejects = ((length + subtract) & 0xFFFFFFFF) <= compare
                self.assertEqual(rejects, not 2 <= length <= capacity)


result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(CapacityOnly))
if not result.wasSuccessful():
    raise SystemExit(1)
report = dict(unit_tests=result.testsRun, passed=True, capacity_only=True,
              changed_byte_count=manifest["comparison"]["changed_byte_count"],
              candidate_dll_sha256=m.twenty.sha256(candidate), installed=False, game_send_verified=False)
m.twenty.write_new(args.build / "validation.capacity-control.json", m.twenty.compact(report))
print(json.dumps(report))
