#!/usr/bin/env python3
"""Rebuild the bundled fastText derivative using only the Python standard library."""
import argparse
import gzip
import hashlib
from pathlib import Path
import struct
import tempfile
from urllib.request import Request, urlopen

SOURCE = "https://dl.fbaipublicfiles.com/fasttext/vectors-crawl/cc.zh.300.vec.gz"
DIGEST = "f53c9b9cbfa6f7243506025d4431753a98f4e16cda933dc4528b651c5055b285"
COUNT = 48_000
DIMENSIONS = 64
PROJECTION = [
    (index % DIMENSIONS, 1 if hashlib.sha256(str(index).encode()).digest()[0] & 1 else -1)
    for index in range(300)
]


def term_key(word):
    value = 14695981039346656037
    for byte in word.encode("utf-8"):
        value = ((value ^ byte) * 1099511628211) & 0xffffffffffffffff
    return value


def read_entries(compressed):
    entries = {}
    with gzip.GzipFile(fileobj=compressed) as source:
        if source.readline().split() != [b"2000000", b"300"]:
            raise ValueError("Unexpected source dimensions")
        for line in source:
            name, _, fields = line.partition(b" ")
            word = name.decode("utf-8", errors="replace")
            if not 2 <= len(word) <= 4 or not all(0x4e00 <= ord(c) <= 0x9fff for c in word):
                continue
            if word in entries:
                continue
            values = fields.split()
            if len(values) != len(PROJECTION):
                continue
            folded = [0.0] * DIMENSIONS
            for value, (index, sign) in zip(values, PROJECTION):
                folded[index] += float(value) * sign
            peak = max(abs(value) for value in folded)
            if peak:
                entries[word] = struct.pack("<64b", *(round(127 * v / peak) for v in folded))
            if len(entries) == COUNT:
                return entries
    raise ValueError("Source did not contain the expected number of terms")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="Local copy of cc.zh.300.vec.gz")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[2] /
                        "Keyboard/ContextModel/vectors.dat")
    args = parser.parse_args()
    request = Request(SOURCE, headers={"Range": "bytes=0-134217727"})
    with (args.source.open("rb") if args.source else urlopen(request, timeout=60)) as compressed:
        entries = read_entries(compressed)
    ordering = sorted((term_key(word), word, vector) for word, vector in entries.items())
    if len({key for key, _, _ in ordering}) != COUNT:
        raise ValueError("Hash collision in selected vocabulary")
    image = bytearray(struct.pack("<8sII", b"YAHVEC01", COUNT, DIMENSIONS))
    for key, word, vector in ordering:
        image.extend(struct.pack("<Q12s", key, word.encode("utf-8")))
        image.extend(vector)
    if hashlib.sha256(image).hexdigest() != DIGEST:
        raise ValueError("Generated image does not match the published digest")
    with tempfile.NamedTemporaryFile(dir=args.output.parent, delete=False) as temporary:
        temporary.write(image)
    result = Path(temporary.name)
    result.chmod(0o644)
    result.replace(args.output)


if __name__ == "__main__":
    main()
