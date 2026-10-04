"""Read-only decoder for the inspected local TLG log format.

Never accesses processes, credentials, endpoints, or game input. Only filtered
diagnostic lines are printed; account IDs and credential-shaped fields redacted.
The XOR table is read from the installed logging library, not guessed.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import struct


def records(raw, key):
    at = 0
    while at + 168 <= len(raw):
        size, kind = struct.unpack_from('<II', raw, at)
        if size < 170 or size > 1048576 or at + size > len(raw):
            break  # A live log may finish with an incomplete record.
        row = raw[at:at + size]
        start, tag, message, end = struct.unpack_from('<HHHH', row, 56)
        if not 168 <= start <= tag <= message <= end <= size:
            raise ValueError('Unexpected TLG field bounds at ' + hex(at))
        def decode(lo, hi):
            value = bytes(c ^ key[i % len(key)] for i, c in enumerate(row[lo:hi]))
            return value.decode('utf-16-le', errors='strict').rstrip('\0')
        yield dict(offset=at, time=struct.unpack_from('<Q', row, 32)[0],
                   level=kind, tag=decode(tag, message), text=decode(message, end))
        at += size


def redact(value):
    value = re.sub(r'(?i)((?:token|cookie|ticket|openid|uin|user_id|account|password|secret)\s*[=:]\s*)[^,;\s]+', r'\1[REDACTED]', value)
    value = re.sub(r'(?<![\w.])\d{6,}(?![\w.])', '[ID]', value)
    return value


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--logger', type=Path, required=True)
    p.add_argument('--log', type=Path, required=True)
    p.add_argument('--pattern', default=r'TenPallas|shout|inject|loadlibrary|one_key_speak|init.*fail')
    p.add_argument('--since', type=int, default=0, help='UTC Unix seconds, inclusive')
    p.add_argument('--limit', type=int, default=80)
    args = p.parse_args()
    logger = args.logger.read_bytes()
    prefix = bytes.fromhex('e929ce76e145117e3351e960e361542c')
    pos = logger.find(prefix)
    if pos < 0 or logger.find(prefix, pos + 1) >= 0:
        raise ValueError('Inspected logging XOR table is absent or ambiguous.')
    key = logger[pos:pos + 128]
    rows = []
    for row in records(args.log.read_bytes(), key):
        if row['time'] >= args.since and re.search(args.pattern, row['text'], re.I):
            row['time_utc'] = datetime.datetime.fromtimestamp(row.pop('time'), datetime.timezone.utc).isoformat()
            row['text'] = redact(row['text'])
            rows.append(row)
    print(json.dumps(dict(log=str(args.log), logger_sha256=hashlib.sha256(logger).hexdigest(),
                         matching_records=len(rows), records=rows[-args.limit:]), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
