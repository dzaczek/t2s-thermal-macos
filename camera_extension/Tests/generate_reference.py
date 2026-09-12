"""Exercise the vendored author's implementation without opening a camera.

Synthetic frame metadata, not a physical accuracy certificate. Keep the actual
Python info()/get_temp_table() as the oracle, rather than retyping the formulas.
The Swift V2 shutter parameter is absolute; Python's is additive. Set Python's
offset so both evaluate the same shutter temperature. The unverified upstream
high-range scale is intentionally replaced with each test's explicit fit.
"""
import json
from pathlib import Path
import random
import struct
import sys

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from irpythermal import Camera

destination = Path(sys.argv[1])
destination.mkdir(parents=True, exist_ok=True)
rng = random.Random(731)
cases = []
for number in range(48):
    raw = np.zeros(256 * 196, dtype=np.uint16)
    base = 256 * 192
    raw[:base] = 9000
    raw[base + 1] = rng.randint(7500, 9000)
    raw[base + 256] = rng.randint(5000, 10000)
    raw[base + 257] = rng.choice([0, 451, 2048, 2049, 4095])
    # Signed high byte of shutterFix, as decoded by the original implementation.
    raw[base + 559] = 0xFA00  # -0.6 C

    def f32(offset, value):
        raw[base + offset:base + offset + 2] = np.frombuffer(struct.pack('<f', value), dtype='<u2')

    for offset, value in zip([259, 261, 263, 265, 267],
                            [rng.uniform(.1, .4), rng.uniform(20, 45), -.00001,
                             rng.uniform(.004, .02), rng.uniform(.5, 1.5)]):
        f32(offset, value)
    f32(383, rng.uniform(-3, 3))
    f32(385, rng.uniform(10, 30))
    f32(387, rng.uniform(10, 30))
    f32(389, rng.choice([0, .45, 1]))
    f32(391, rng.choice([.2, .5, .95, 1]))
    raw[base + 393] = rng.choice([0, 1, 5, 20, 50])

    camera = Camera.__new__(Camera)  # NEVER call __init__: it opens hardware.
    camera.width = 256
    camera.height = 192
    camera.init_parameters()
    camera.fourLinePara = base
    camera.userArea = 383
    camera.camera_raw = True
    camera.frame_raw_u16 = raw
    camera.userOffset = rng.choice([0, -2.5, 3])
    camera.range = 120 if number % 2 == 0 else 450
    camera.correction_coefficient_m = rng.choice([.1, 1, 2.25])
    camera.correction_coefficient_b = rng.choice([-45, 0, 12])
    shutter = rng.uniform(18, 90)
    with np.errstate(invalid='ignore'):
        info, _ = camera.info()
        camera.offset_temp_shutter = shutter - info['temp_shutter']
        _, expected = camera.info()
    stem = f'frame-{number}'
    raw.astype('<u2').tofile(destination / f'{stem}.raw')
    expected.astype('<f8').tofile(destination / f'{stem}.expected')
    cases.append(dict(name=stem, shutterOffset=shutter, high=number % 2 == 1,
                      scale=camera.correction_coefficient_m,
                      bias=camera.correction_coefficient_b, userOffset=camera.userOffset))
(destination / 'manifest.json').write_text(json.dumps(cases))
print(f'Generated {len(cases)} full-frame fixtures using vendored IR-Py-Thermal.')
