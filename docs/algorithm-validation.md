# Temperature algorithm validation

Checked on 2026-09-12. This is software verification using synthetic inputs,
not a calibration certificate or a physical accuracy measurement.

## Reference and method

The reference is the vendored `irpythermal.py` from
[IR-Py-Thermal](https://github.com/diminDDL/IR-Py-Thermal), GPLv3.
SHA-256 of the reference used for this run:
`b0084a0ca4339e15c6329af248947d6119b1cb1fff1e741167df2d146310cdf8`.

The fixture generator calls the actual Python `Camera.info()` and
`get_temp_table()` methods, without calling the camera constructor or opening
hardware. It builds 48 deterministic synthetic 256×196 frames, varying the
factory coefficients, FPA/shutter readings, emissivity, air and reflected
temperatures, humidity, distance, measurement range, and linear correction.
Swift parses those frames and compares all 16,384 table entries per frame.

Two intentional model choices are explicit in the comparison:

- Swift's shutter parameter is an absolute substitute temperature, while
  Python adds its offset to the decoded register. The reference offset is
  adjusted so both evaluate the same shutter temperature. This follows the
  fixed-temperature workaround described in the
  [author's article](https://dmytroengineering.com/content/projects/t2s-plus-thermal-camera-hacking);
  it does not validate long-term drift compensation.
- The upstream raw-camera high-range scale of 0.1 is marked unverified in
  that library. The app still requires its own measured two-point correction;
  both implementations receive the same explicit scale/bias in these tests.

## Results

- 763,391 finite table values compared; 23,041 invalid values stayed invalid.
- Maximum difference within the unscaled model's −20…450°C interval:
  **0.000708°C**, below the test tolerance of 0.002°C.
- Maximum difference over all finite ADC entries: **0.056686°C**. The larger
  differences occur below the operating temperature interval, near zero
  inferred radiance, where fourth-root inversion amplifies Python float32
  roundoff. Swift uses Double. The full-table comparison tolerance is 0.1°C.
- Calibration tests cover metadata changing between references, identical raw
  counts under different metadata, degenerate/reversed fits, the one-point
  solver with an existing two-point correction, and negative extrapolation
  caused by unsuitable references.
- Processing checks cover NUC offset removal and mean preservation, truncated
  NUC samples, a dead corner pixel, and a small hot target surviving smoothing
  and all four image rotations.

## Corrections made during the audit

- Nonfinite metadata, invalid emissivity/humidity/distance, and unusable model
  coefficients are rejected before generating readings.
- Nonpositive inferred radiance is no longer converted into a fake
  absolute-zero temperature. Its lookup entry is invalid. An affected main
  frame is skipped and its calibration/export snapshot is cleared; an
  affected measurement is omitted. Emissivity overrides do not silently
  fall back to the global setting.
- User offset is applied after the linear scale/bias, matching Python. The
  live app currently leaves this optional decoder argument at zero.
- Capture validates the native pixel format, dimensions and row length.
- The calibration dialog rejects stale samples, the one-point solver stops
  on invalid values, and a stored two-point calibration alone is recognised
  at startup.

## Reproduce

Install the Python dependencies from `requirements.txt`, then run from the
repository root:

```bash
bash camera_extension/Tests/run.sh
```

The runner uses `venv/bin/python` when available, otherwise `python3`.
Set `T2S_TEST_PYTHON` to select another interpreter. It requires NumPy and
OpenCV to import the vendored library, plus the Swift command-line tools.
Generated fixtures and the test executable live in a temporary directory.

## What remains a physical measurement

Agreement with the author's software does not establish the absolute accuracy
of its reverse-engineered model. Check independently measured, high-emissivity
references after warm-up, including temperatures not used for fitting. Repeat
after NUC and after the camera warms further. Each hardware range needs its
own assessment. Do not claim an accuracy specification for other units from
these synthetic tests, or use forehead/pot-wall guesses as temperature standards.

See [reference selection and calibration](using.md#choosing-references-and-checking-the-result).
