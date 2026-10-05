"""OFFLINE Chinese >8 KiB/80-entry receive experiment. Never install or send.

Retains the working 64 KiB legacy reader/loader/JSON and twenty native keys.
Only widens original string vectors/JSON loop and generalizes receive indexing.
Entries 21..80 have NO selection bindings yet: this is not an 80-key release.
"""
from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path

import PallasLibrary as library

BASELINE_HASH = "60a14666e80b72a0c87807a89740d51e74e2b68074632e052513a91c7b313a28"
COUNT = 80
MAX_UNITS = 100  # OFFLINE candidate only; NOT a measured safe game limit.
CAPACITY = 65536
RECEIVER_MANY = bytes.fromhex("89f831d2b90a000000f7f183fa0975044183e80a9090909090904963c8")
BODY = ("请先确认队友位置和敌方动向，做好河道视野再集合推进，避免落单并保持沟通。"
        "先确认兵线和关键技能，再决定开团时机，注意撤退路线，不要连续重复发送消息。")


def chinese_number(value):
    if type(value) is not int or not 1 <= value <= 99:
        raise ValueError("Fixture numeral requires 1..99.")
    digits = "零一二三四五六七八九"
    if value < 10:
        return digits[value]
    tens, ones = divmod(value, 10)
    return ("" if tens == 1 else digits[tens]) + "十" + (digits[ones] if ones else "")


def make_scheme(seed):
    # Validate the CURRENT twenty texts, without saving/applying/overwriting.
    library.artifacts(seed)
    scheme = {str(i): seed[str(i)] for i in range(20)}
    for i in range(20, COUNT):
        scheme[str(i)] = f"容量检验第{chinese_number(i + 1)}条：{BODY}已核对。"
    scheme.update(title=seed["title"], key=seed["key"])
    return scheme


def artifacts(scheme):
    if not isinstance(scheme, dict) or set(scheme) != {"title", "key", *(str(i) for i in range(COUNT))}:
        raise ValueError("Exactly eighty messages, title and key are required.")
    if type(scheme["key"]) is not int or scheme["key"] not in (1, 2):
        raise ValueError("Unchanged native panel key must be integer 1 or 2.")
    for label in ("title", *(str(i) for i in range(COUNT))):
        value = scheme[label]
        if not isinstance(value, str) or not value.strip() or library.twenty.utf16_length(value) > MAX_UNITS:
            raise ValueError(f"{label}: nonempty text, at most {MAX_UNITS} UTF-16 units; no truncation.")
        if any(ord(c) < 32 or ord(c) == 127 for c in value):
            raise ValueError("Control characters are not supported.")
    ordered = {str(i): scheme[str(i)] for i in range(COUNT)}
    ordered.update(title=scheme["title"], key=scheme["key"])
    raw = library.twenty.compact(ordered)
    if not 8192 < len(raw) <= CAPACITY:
        raise ValueError("This REAL-TEXT capacity fixture must exceed 8 KiB and fit 64 KiB.")
    # Old twenty-entry bootstrap shape stays unchanged and preview is truthful.
    preview = {"_lps_local_v1": f"{len(raw):08X}:{library.fnv1a(raw):08X}"}
    preview.update({str(i): scheme[str(i)] if i < 10 else "" for i in range(20)})
    preview.update(title=scheme["title"], key=scheme["key"])
    short = library.twenty.compact(preview)
    if len(short) > 2046:
        raise ValueError("Unchanged native preview transport exceeds 2046 bytes.")
    response = library.twenty.compact({"result": {"error_code": 0},
                                      "shout_message": base64.b64encode(short).decode("ascii")})
    metrics = dict(message_count=COUNT, native_bound_message_count=20, library_json_utf8_bytes=len(raw),
                   library_capacity_bytes=CAPACITY, bootstrap_json_utf8_bytes=len(short),
                   single_message_utf16_guard=MAX_UNITS, requested_maximum_characters=100,
                   message_utf16_units=[library.twenty.utf16_length(scheme[str(i)]) for i in range(COUNT)],
                   whitespace_padding=False, first_twenty_messages_preserved=True)
    return raw, response, metrics


def patch_count(baseline):
    if library.twenty.sha256(baseline) != BASELINE_HASH:
        raise ValueError("Requires the currently game-verified legacy capacity-only DLL.")
    pe = library.twenty.PE64(baseline)
    specs = [
        ("initial-vector-eighty", 0x180041EB4, bytes.fromhex("ba14000000"), bytes.fromhex("ba50000000")),
        ("received-vector-eighty", 0x1800422CB, bytes.fromhex("418d5714"), bytes.fromhex("418d5750")),
        ("received-json-keys-0-to-79", 0x1800422DC, bytes.fromhex("83ff14"), bytes.fromhex("83ff50")),
        ("receive-index-all-eight-groups", 0x1800423B3, library.twenty.RECEIVER_INDEX, RECEIVER_MANY),
    ]
    candidate = bytearray(baseline)
    changes = []
    for name, va, before, after in specs:
        at = pe.offset(va, len(before))
        if len(before) != len(after) or baseline[at:at + len(before)] != before:
            raise ValueError("Unexpected fixed receive bytes: " + name)
        candidate[at:at + len(after)] = after
        changes.append(dict(name=name, va=hex(va), file_offset=at, before_hex=before.hex(), after_hex=after.hex()))
    inverse = bytearray(candidate)
    for change in changes:
        at = change["file_offset"]; old = bytes.fromhex(change["before_hex"])
        inverse[at:at + len(old)] = old
    if inverse != baseline:
        raise ValueError("Changes outside the explicit receive/count ranges.")
    return bytes(candidate), changes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed-library", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    out = args.out_dir.resolve()
    if root / "build" not in out.parents or out.exists():
        raise ValueError("Use a NEW offline project build directory; never overwrite live or prior files.")
    seed_bytes = args.seed_library.read_bytes()
    seed = json.loads(seed_bytes.decode("utf-8-sig"), object_pairs_hook=library.twenty.unique_object)
    baseline = args.baseline.read_bytes()
    candidate, changes = patch_count(baseline)
    scheme = make_scheme(seed)
    raw, response, metrics = artifacts(scheme)
    out.mkdir(parents=True, exist_ok=False)
    library.twenty.write_new(out / "scheme80.json", json.dumps(scheme, ensure_ascii=False, indent=2).encode("utf-8"))
    library.twenty.write_new(out / "library80.json", raw)
    library.twenty.write_new(out / "local-response80.json", response)
    library.twenty.write_new(out / "TenPallas.count80.experimental.dll", candidate)
    report = dict(experiment="legacy-eighty-real-chinese-receive-v1", metrics=metrics,
        baseline_dll_sha256=BASELINE_HASH, candidate_dll_sha256=library.twenty.sha256(candidate), changes=changes,
        library_sha256=library.twenty.sha256(raw), response_sha256=library.twenty.sha256(response),
        seed_library_sha256=library.twenty.sha256(seed_bytes),
        required_legacy_pallas_sha256=library.twenty.PALLAS_LOCAL_SHA256,
        loader_json_reader_and_native_keyboard_unchanged=True, installed=False,
        game_receive_verified=False, game_send_verified=False, invalid_authenticode_digest=True,
        limitations=["New entries 21..80 have no selectable bindings until a separate bank/key extension.",
                     "100 UTF-16 unit offline guard only; game-side length safety is NOT established.",
                     "Real Chinese message bytes, no whitespace padding or ignored padding fields.",
                     "Own-process tests do not execute Tencent's JSON parser or controller initialization.",
                     "First twenty texts are personal; do not distribute this generated fixture.",
                     "Not installed; no game process access, game input or messages sent."])
    library.twenty.write_new(out / "manifest.json", library.twenty.compact(report))
    if args.seed_library.read_bytes() != seed_bytes or args.baseline.read_bytes() != baseline:
        raise ValueError("A source changed during offline preparation.")
    print(json.dumps(dict(output=str(out), metrics=metrics, candidate_dll_sha256=report["candidate_dll_sha256"],
                         installed=False, game_send_verified=False), ensure_ascii=True))


if __name__ == "__main__":
    main()
