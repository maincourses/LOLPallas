"""Read-only validation of the pinned eight-bank candidate and all eighty texts."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import PallasBanksTen as m

CANDIDATE_HASH = "5407dfa6a92640b216f5fba143a5baf63ec68e46a108fc664356df3a037bf3e2"


def validate(build, seed_path):
    root = Path(__file__).resolve().parents[2]
    build = build.resolve()
    if root / "build" not in build.parents:
        raise ValueError("Only this project's generated build artifacts.")
    names = ("scheme80.json", "library80.json", "local-response80.json", "manifest.json",
             "library80-banks.obj", "TenPallas.banks10.experimental.dll", "validation.banks80.json")
    data = {name: (build / name).read_bytes() for name in names}
    seed_bytes = seed_path.read_bytes()
    seed = json.loads(seed_bytes.decode("utf-8-sig"), object_pairs_hook=m.library.twenty.unique_object)
    scheme = json.loads(data["scheme80.json"], object_pairs_hook=m.library.twenty.unique_object)
    if seed != scheme:
        raise ValueError("Existing eighty-message seed changed; no personal text may be replaced.")
    raw, response, metrics = m.artifacts(scheme)
    report = json.loads(data["manifest.json"])
    proof = json.loads(data["validation.banks80.json"])
    rebuilt, native, changes = m.old.patch_banks((root / "engine/assets/TenPallas.original.dll").read_bytes(), data["library80-banks.obj"])
    digest = m.library.twenty.sha256
    if (report["experiment"] != m.EXPERIMENT or report["metrics"] != metrics or
            report["native"] != native or report["changes"] != changes or rebuilt != data["TenPallas.banks10.experimental.dll"] or
            digest(rebuilt) != CANDIDATE_HASH or report["candidate_dll_sha256"] != CANDIDATE_HASH or
            report["object_sha256"] != digest(data["library80-banks.obj"]) or
            report["library_sha256"] != digest(raw) or report["response_sha256"] != digest(response) or
            report["seed_library_sha256"] != digest(seed_bytes) or
            report["required_legacy_pallas_sha256"] != m.library.twenty.PALLAS_LOCAL_SHA256 or
            data["library80.json"] != raw or data["local-response80.json"] != response):
        raise ValueError("Candidate/profile/seed payload cannot be reproduced.")
    own = proof["own_banks"]
    if (proof["candidate_dll_sha256"] != CANDIDATE_HASH or not proof["unit_tests_passed"] or proof["unit_tests"] != 6 or
            not own["passed"] or own["cases"] != 524 or own["unique_message_slots"] != 80 or
            own["bank_count"] != 8 or own["bank_size"] != 10 or own["native_utf8_guard_units"] is not None or
            own["function_keys_send"] is not False or own["tencent_dll_loaded"] is not False or
            proof["installed"] is not False or proof["game_send_verified"] is not False or
            any(not proof["reader_tests"][flag]["passed"] or not proof["reader_tests"][flag]["accepted"]
                for flag in ("--child", "--real-io-child"))):
        raise ValueError("Missing independent mapping, no-cap and reader proofs.")
    if seed_path.read_bytes() != seed_bytes or any((build / k).read_bytes() != v for k, v in data.items()):
        raise ValueError("Inputs changed during validation.")
    return dict(passed=True, candidate_dll_sha256=CANDIDATE_HASH, seed_library_sha256=digest(seed_bytes),
                library_sha256=digest(raw), response_sha256=digest(response), metrics=metrics, game_send_verified=False)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--seed-library", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(validate(args.build, args.seed_library)))
