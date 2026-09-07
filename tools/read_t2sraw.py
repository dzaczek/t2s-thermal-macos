#!/usr/bin/env python3
"""Read a .t2sraw capture: the sensor's own counts, exactly as they came out.

The app also writes a CSV of temperatures beside each photo, but a temperature
is an interpretation -- it depends on the emissivity, the calibration and the
air settings that were in force at the time, and those are judgements that
turn out to be wrong. The counts are not an interpretation, so a capture kept
this way can be decoded again later with better numbers.

Usage:
    python3 tools/read_t2sraw.py shot.t2sraw          # what is in it
    python3 tools/read_t2sraw.py shot.t2sraw --csv out.csv   # counts as CSV

The file is deliberately dull so anything can read it:

    "T2SRAW01"        8 bytes
    header length     uint32, little endian
    header            that many bytes of JSON
    samples           width * totalRows uint16, little endian, row major

Rows past `imageRows` are the four metadata rows the camera appends. They are
not picture: they carry that frame's own calibration constants, which is why
they are kept. See docs/how-it-works.md.
"""

import json
import struct
import sys

MAGIC = b"T2SRAW01"


def read(path):
    """Returns (header, rows) where rows is a list of lists of ints."""
    with open(path, "rb") as f:
        blob = f.read()

    if blob[:8] != MAGIC:
        raise ValueError(f"{path} does not start with {MAGIC.decode()}")

    (header_length,) = struct.unpack_from("<I", blob, 8)
    header = json.loads(blob[12:12 + header_length])

    width = header["width"]
    total_rows = header["totalRows"]
    expected = width * total_rows
    samples = struct.unpack_from(f"<{expected}H", blob, 12 + header_length)
    if len(samples) != expected:
        raise ValueError(f"expected {expected} samples, found {len(samples)}")

    rows = [list(samples[y * width:(y + 1) * width]) for y in range(total_rows)]
    return header, rows


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1

    header, rows = read(argv[1])
    width = header["width"]
    image_rows = header["imageRows"]

    print(f"{argv[1]}")
    for key in sorted(header):
        print(f"  {key}: {header[key]}")

    picture = [v for row in rows[:image_rows] for v in row]
    print(f"\n  picture: {width}x{image_rows}, counts {min(picture)}..{max(picture)}")
    print(f"  metadata rows: {len(rows) - image_rows}")

    if "--csv" in argv:
        out = argv[argv.index("--csv") + 1]
        with open(out, "w") as f:
            for row in rows[:image_rows]:
                f.write(",".join(str(v) for v in row) + "\n")
        print(f"\n  picture counts written to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
