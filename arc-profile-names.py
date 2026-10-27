#!/usr/bin/env python3
"""Map each Arc profile's Claude browser connection to the profile's name.

Every Arc profile that loads the patched extension runs its own copy of it, and
each copy registers with Claude as a separate browser. They all report the same
default name (the computer name), so Claude lists them as "Browser 1..N" and the
numbering shifts as connections come and go, which makes it easy to drive the
wrong profile.

The connection is identified by the `bridgeDeviceId` the extension keeps in its
own chrome.storage.local. This script reads that value from each profile's
storage (a LevelDB directory) without modifying anything, and writes
{device id: "Arc – <profile name>"} for sw-patch.js to apply at startup.

Only the Python standard library is used: the small LevelDB / Snappy readers
below handle exactly what Chromium writes for extension storage.

Usage: arc-profile-names.py OUTPUT_JSON [--rename]
"""

import glob
import json
import os
import struct
import sys
import time

ARC_ROOT = os.path.expanduser("~/Library/Application Support/Arc/User Data")
CLAUDE_IDS = (
    "jlgadfahkiakjhceomgpemiabkpgnlho",
    "cpklelfgbalgamlgfhikjfneldeeilcg",
    "fcoeoabgfenejglbffodgkkbkcdhcgfn",
)
DEVICE_KEY = b"bridgeDeviceId"
SKIP_PROFILES = {"__ARC_SYSTEM_PROFILE"}


# ── LevelDB primitives ───────────────────────────────────────────

def varint(buf, pos):
    result = shift = 0
    while True:
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, pos
        shift += 7


def snappy_decompress(src):
    length, pos = varint(src, 0)
    out = bytearray()
    while pos < len(src):
        tag = src[pos]
        pos += 1
        kind = tag & 3
        if kind == 0:  # literal
            n = tag >> 2
            if n >= 60:
                extra = n - 59
                n = int.from_bytes(src[pos:pos + extra], "little")
                pos += extra
            n += 1
            out += src[pos:pos + n]
            pos += n
            continue
        if kind == 1:
            n = ((tag >> 2) & 7) + 4
            offset = ((tag >> 5) << 8) | src[pos]
            pos += 1
        elif kind == 2:
            n = (tag >> 2) + 1
            offset = int.from_bytes(src[pos:pos + 2], "little")
            pos += 2
        else:
            n = (tag >> 2) + 1
            offset = int.from_bytes(src[pos:pos + 4], "little")
            pos += 4
        for _ in range(n):  # byte by byte: copies may overlap their own output
            out.append(out[-offset])
    if len(out) != length:
        raise ValueError("snappy length mismatch")
    return bytes(out)


def read_block(data, offset, size):
    block = data[offset:offset + size]
    kind = data[offset + size]
    if kind == 1:
        return snappy_decompress(block)
    if kind == 0:
        return block
    raise ValueError("unsupported block compression %d" % kind)


def block_entries(block):
    num_restarts = struct.unpack_from("<I", block, len(block) - 4)[0]
    end = len(block) - 4 - 4 * num_restarts
    pos, key = 0, b""
    while pos < end:
        shared, pos = varint(block, pos)
        unshared, pos = varint(block, pos)
        value_len, pos = varint(block, pos)
        key = key[:shared] + block[pos:pos + unshared]
        pos += unshared
        yield key, block[pos:pos + value_len]
        pos += value_len


def sstable_records(path):
    """(sequence, user key, value) for every live entry in an .ldb file."""
    with open(path, "rb") as f:
        data = f.read()
    footer = data[-48:]
    _, p = varint(footer, 0)          # metaindex handle (unused)
    _, p = varint(footer, p)
    index_off, p = varint(footer, p)
    index_size, p = varint(footer, p)
    for _, handle in block_entries(read_block(data, index_off, index_size)):
        off, q = varint(handle, 0)
        size, _ = varint(handle, q)
        for ikey, value in block_entries(read_block(data, off, size)):
            tag = struct.unpack("<Q", ikey[-8:])[0]
            if tag & 0xFF == 1:  # value (0 = deletion)
                yield tag >> 8, ikey[:-8], value


def log_records(path):
    """(sequence, user key, value) for every put in a LevelDB .log file."""
    with open(path, "rb") as f:
        data = f.read()
    batches, pending, pos = [], b"", 0
    while pos + 7 <= len(data):
        block_left = 32768 - pos % 32768
        if block_left < 7:  # trailer padding at the end of a 32 KB block
            pos += block_left
            continue
        length, rtype = struct.unpack_from("<HB", data, pos + 4)
        payload = data[pos + 7:pos + 7 + length]
        pos += 7 + length
        if rtype == 1:      # full
            batches.append(payload)
        elif rtype == 2:    # first
            pending = payload
        elif rtype == 3:    # middle
            pending += payload
        elif rtype == 4:    # last
            batches.append(pending + payload)
            pending = b""
        elif rtype == 0:    # zero padding / preallocated space
            break
    for batch in batches:
        seq, count = struct.unpack_from("<QI", batch, 0)
        p = 12
        for i in range(count):
            kind = batch[p]
            p += 1
            klen, p = varint(batch, p)
            key = batch[p:p + klen]
            p += klen
            if kind == 1:
                vlen, p = varint(batch, p)
                yield seq + i, key, batch[p:p + vlen]
                p += vlen


def latest_value(db_dir, wanted):
    best = None
    files = glob.glob(os.path.join(db_dir, "*.ldb")) + glob.glob(os.path.join(db_dir, "*.log"))
    for path in files:
        reader = sstable_records if path.endswith(".ldb") else log_records
        try:
            for seq, key, value in reader(path):
                if key == wanted and (best is None or seq > best[0]):
                    best = (seq, value)
        except Exception as e:  # a damaged file must not stop the patcher
            print("  skipped %s: %s" % (os.path.basename(path), e), file=sys.stderr)
    return best and best[1]


# ── Main ─────────────────────────────────────────────────────────

def profile_name(profile_dir):
    try:
        with open(os.path.join(profile_dir, "Preferences"), encoding="utf-8") as f:
            return json.load(f).get("profile", {}).get("name")
    except (OSError, ValueError):
        return None


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    out_path, rename = sys.argv[1], "--rename" in sys.argv[2:]

    names = {}
    for profile_dir in sorted(glob.glob(os.path.join(ARC_ROOT, "*"))):
        name = profile_name(profile_dir)
        if not name or name in SKIP_PROFILES:
            continue
        for ext_id in CLAUDE_IDS:
            db_dir = os.path.join(profile_dir, "Local Extension Settings", ext_id)
            if not os.path.isdir(db_dir):
                continue
            raw = latest_value(db_dir, DEVICE_KEY)
            try:
                device_id = json.loads(raw) if raw else None
            except ValueError:
                device_id = None
            if isinstance(device_id, str) and device_id:
                label = ("Arc – " + name)[:64]
                names[device_id] = label
                print("  %s  %s" % (device_id, label))

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({"generatedAt": int(time.time()), "rename": rename, "names": names},
                  f, ensure_ascii=False, indent=2)
    print("%d profile connection name(s) written" % len(names))
    return 0


if __name__ == "__main__":
    sys.exit(main())
