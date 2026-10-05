"""Read-only validation of the EXACT already-tested bank candidate and seed.

No compiling, installation, executable loading, game discovery or sending.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path

import PallasBanks80 as m

CANDIDATE_HASH = "f261f5e75dc8dbf88d1eeafe2d6b2ddf4f241803309c20100e50a08097177119"


def validate(build, seed_path):
    root = Path(__file__).resolve().parents[2]
    build = build.resolve()
    if root / "build" not in build.parents:
        raise ValueError("Requires this project's generated candidate directory.")
    names = ("scheme80.json", "library80.json", "local-response80.json", "manifest.json",
             "library80-banks.obj", "TenPallas.banks80.experimental.dll", "validation.banks80.json")
    snapshots = {name: (build / name).read_bytes() for name in names}
    seed_bytes = seed_path.read_bytes()
    seed = json.loads(seed_bytes.decode("utf-8-sig"), object_pairs_hook=m.library.twenty.unique_object)
    scheme = json.loads(snapshots["scheme80.json"], object_pairs_hook=m.library.twenty.unique_object)
    # Retain all twenty PERSONAL texts and original metadata exactly.
    m.library.artifacts(seed)
    if any(scheme[k] != seed[k] for k in ["title", "key", *(str(i) for i in range(20))]):
        raise ValueError("The seed changed: candidate would replace an existing personal message.")
    raw, response, metrics = m.count.artifacts(scheme)
    metrics.update(native_bound_message_count=80, bank_count=4, bank_size=20,
                   allocated_string_count=81, reserved_state_strings=1)
    report = json.loads(snapshots["manifest.json"])
    proof = json.loads(snapshots["validation.banks80.json"])
    if (report["experiment"] != "legacy-four-banks-real-chinese-100-offline-v1" or
        report["metrics"] != metrics or raw != snapshots["library80.json"] or
        response != snapshots["local-response80.json"] or
        report["seed_library_sha256"] != m.library.twenty.sha256(seed_bytes) or
        report["candidate_dll_sha256"] != CANDIDATE_HASH or
        m.library.twenty.sha256(snapshots["TenPallas.banks80.experimental.dll"]) != CANDIDATE_HASH or
        m.library.twenty.sha256(snapshots["library80-banks.obj"]) != report["object_sha256"] or
        m.library.twenty.sha256(raw) != report["library_sha256"] or
        m.library.twenty.sha256(response) != report["response_sha256"]):
        raise ValueError("Candidate/seed/library/response/manifest mismatch.")
    original = (root / "engine/assets/TenPallas.original.dll").read_bytes()
    rebuilt, native, changes = m.patch_banks(original, snapshots["library80-banks.obj"])
    if (rebuilt != snapshots["TenPallas.banks80.experimental.dll"] or report["native"] != native or
        report["changes"] != changes or report["baseline_dll_sha256"] != m.count.BASELINE_HASH or
        report["required_legacy_pallas_sha256"] != m.library.twenty.PALLAS_LOCAL_SHA256):
        raise ValueError("The pinned receive, adapter and guarded sender cannot be reproduced.")
    own = proof["own_banks"]
    if (proof["candidate_dll_sha256"] != CANDIDATE_HASH or proof["unit_tests_passed"] is not True or
        proof["unit_tests"] != 6 or own["passed"] is not True or own["cases"] != 478 or
        own["unique_message_slots"] != 80 or own["native_utf8_guard_units"] != 100 or
        proof["reader_tests"]["--child"]["passed"] is not True or
        proof["reader_tests"]["--child"]["accepted"] is not True or
        proof["reader_tests"]["--real-io-child"]["passed"] is not True or
        proof["reader_tests"]["--real-io-child"]["accepted"] is not True or
        proof["installed"] is not False or proof["game_send_verified"] is not False):
        raise ValueError("Missing or inconsistent offline proofs; no game success inferred.")
    if seed_path.read_bytes() != seed_bytes or any((build / k).read_bytes() != v for k, v in snapshots.items()):
        raise ValueError("Input changed during read-only validation.")
    return dict(passed=True, candidate_dll_sha256=CANDIDATE_HASH,
                seed_library_sha256=m.library.twenty.sha256(seed_bytes),
                library_sha256=m.library.twenty.sha256(raw), response_sha256=m.library.twenty.sha256(response),
                library_bytes=len(raw), bootstrap_bytes=metrics["bootstrap_json_utf8_bytes"],
                message_count=80, bank_count=4, single_message_utf16_guard=100,
                game_send_verified=False)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--seed-library", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(validate(args.build, args.seed_library)))
