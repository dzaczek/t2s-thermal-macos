#!/usr/bin/env python3
"""Xtherm T2S+ thermal viewer for macOS.

Uses irpythermal.py (github.com/diminDDL/IR-Py-Thermal, GPLv3) for frame
capture, hardware calibration, AND (unlike an earlier version of this file)
its physics-based get_temp_table() radiometric model too -- see below for why
that changed.

Capture and control both go through t2s_capture.py instead of cv2.VideoCapture
directly: OpenCV's AVFoundation backend crashes opening this camera on macOS,
so frames come from ffmpeg and control commands go through the vendored
uvc-util (see t2s_capture.py for why).

Why get_temp_table() is used now, after previously being abandoned for a
simple linear model: that physics model uses this unit's real factory
calibration constants (cal_00..cal_05, read from the camera's own metadata),
but two things made it useless at first, both confirmed against the real
camera:
  1. TPD parameter writes (set_emissivity etc.) silently didn't take effect
     on read-back -- irpythermal.py's setters never call the separate
     save_parameters() (UVC command 0x80FF) needed to commit them, so
     emissivity stayed stuck at a bogus factory-default 0.02 (near-mirror
     reflectivity, physically implausible). Calling save_parameters() after
     set_emissivity(0.95) fixed it: read-back confirmed 0.95, and the
     table's NaN count dropped from ~3800/16384 to zero. Caveat, also
     confirmed against the real camera: this only reliably works for the
     FIRST emissivity change in a session -- writes apply on an
     unpredictable delay (a later script's read-back showed a value set by
     an *earlier, already-exited* script), so a change mid-session ('e' key)
     can't be verified pass/fail here. Set it once at launch (--emissivity)
     for a value you can count on; calibrate_shutter_offset() below is
     unaffected since it's pure Python state, no USB write involved.
  2. The remaining input, camera.offset_temp_shutter (a correction hook
     irpythermal.py already defines for its own known-broken shutter-
     temperature reading on this V2 hardware -- "I was unable to determine
     the logic... left that as hard coded room temperature", per the
     library author), still needs calibrating. But once (1) was fixed,
     sweeping it produced a clean, monotonic, smoothly-varying, plausible
     temperature curve with a stable, tight min/max spread -- i.e. the real
     factory-calibrated model working correctly, not a guessed approximation.
     calibrate_shutter_offset() below solves for it against one known
     reference temperature via a couple of probe reads (Newton's method,
     since the local slope isn't exactly 1:1 -- confirmed empirically).

Adds on top of the raw capture: selectable color gradients, on-screen
max/min/center temperature markers (using a percentile-robust min/max so a
single dead/noisy pixel can't produce a wild outlier reading), a labeled
color scale, an in-window help overlay, and calibration.
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path

import cv2
import numpy as np

import irpythermal
import t2s_capture

DISPLAY_SCALE = 3
BAR_WIDTH = 90
SHUTTER_OFFSET_FILE = Path(__file__).with_name("shutter_offset.json")

# --virtual-cam: hand frames to the macOS camera extension in
# camera_extension/ (see its README section), which publishes them as a
# real camera device for Teams/Zoom/etc. The extension reads raw 32BGRA
# bytes from this exact path; dimensions must match Config.swift's
# fixedCamWidth/fixedCamHeight over there, which are the canvas size
# produced below (256*DISPLAY_SCALE + BAR_WIDTH) x (192*DISPLAY_SCALE).
#
# Path is the App Group container, not a normal Application Support dir:
# camera extensions must run sandboxed, so that container is the one place
# both the sandboxed extension and this (unsandboxed) writer can reach.
# Must stay in sync with appGroupID in Config.swift.
# App Group names embed the signing team, so this differs per build. The Swift
# app reads it from its own code signature; this prototype cannot, so set
# T2S_APP_GROUP=<TeamID>.cat.sysop.t2scamera to use --virtual-cam from here.
APP_GROUP_ID = os.environ.get("T2S_APP_GROUP", "")
VIRTUAL_CAM_DIR = Path.home() / "Library" / "Group Containers" / APP_GROUP_ID
VIRTUAL_CAM_FRAME = VIRTUAL_CAM_DIR / "frame.raw"

DEFAULT_EMISSIVITY = 0.95
DEFAULT_DISTANCE_M = 1
DEFAULT_AMBIENT_C = 20.0
DEFAULT_REFLECTED_C = 20.0
# Starting guess for camera.offset_temp_shutter, good enough for a plausible
# image before calibrating: measured empirically to give ~20C (a reasonable
# room temperature) in one test session. Unlike a sensor-electronics slope,
# there's no strong guarantee this is stable across sessions (it corrects a
# register the library's own author couldn't fully characterize on this
# hardware) -- treat it as a convenience starting point, not a promise.
DEFAULT_SHUTTER_OFFSET = 76.0


def build_ironbow_lut():
    stops = [
        (0.00, (0, 0, 0)),
        (0.10, (45, 0, 20)),
        (0.25, (90, 0, 85)),
        (0.40, (70, 10, 160)),
        (0.55, (15, 55, 215)),
        (0.70, (0, 120, 245)),
        (0.85, (30, 200, 250)),
        (1.00, (200, 255, 255)),
    ]
    positions = np.array([s[0] for s in stops])
    colors_bgr = np.array([s[1] for s in stops], dtype=np.float32)
    xs = np.linspace(0.0, 1.0, 256)
    lut = np.zeros((256, 3), dtype=np.uint8)
    for ch in range(3):
        lut[:, ch] = np.interp(xs, positions, colors_bgr[:, ch]).astype(np.uint8)
    return lut.reshape(256, 1, 3)


PALETTES = [
    ("Ironbow", build_ironbow_lut()),
    ("White Hot", None),
    ("Black Hot", None),
    ("Rainbow", cv2.COLORMAP_JET),
    ("Hot", cv2.COLORMAP_HOT),
    ("Inferno", cv2.COLORMAP_INFERNO),
]


def apply_palette(bgr, index):
    name, cmap = PALETTES[index]
    if name == "White Hot":
        return bgr
    if name == "Black Hot":
        return 255 - bgr
    return cv2.applyColorMap(bgr, cmap)


def load_saved_shutter_offset():
    if SHUTTER_OFFSET_FILE.exists():
        try:
            return float(json.loads(SHUTTER_OFFSET_FILE.read_text())["offset_temp_shutter"])
        except (json.JSONDecodeError, KeyError, ValueError):
            pass
    return None


def save_shutter_offset(value):
    SHUTTER_OFFSET_FILE.write_text(json.dumps({"offset_temp_shutter": value}))


def read_center_temp(camera):
    ret, frame = camera.read()
    info, _ = camera.info()
    return info["Tcenter_C"]


def calibrate_shutter_offset(camera, known_temp_c, max_iters=6, tol=0.1, probe_step=5.0):
    """Newton's-method solve for the camera.offset_temp_shutter value that
    makes the center pixel read known_temp_c, using the model's own local
    slope (confirmed empirically to vary with operating point, so not
    assumed to be 1:1)."""
    offset = camera.offset_temp_shutter
    for _ in range(max_iters):
        camera.offset_temp_shutter = offset
        current = read_center_temp(camera)
        if abs(current - known_temp_c) < tol:
            break
        camera.offset_temp_shutter = offset + probe_step
        probed = read_center_temp(camera)
        local_slope = (probed - current) / probe_step
        if abs(local_slope) < 0.05:
            local_slope = 1.0
        offset = offset + (known_temp_c - current) / local_slope
    camera.offset_temp_shutter = offset
    return offset


def calibrate_hardware(camera, num_avg_frames=15, close_wait_timeout=15.0, std_threshold=6.0,
                        stable_checks=3, dead_pixel_cap=50):
    """Replaces camera.calibrate() (irpythermal.py's calibrate_raw()) for the
    'c' key. That function assumes the shutter is fully closed after a fixed
    ~1.5-2s delay before capturing a SINGLE frame as its reference -- but
    shutter timing on this hardware is highly variable (confirmed
    empirically: 0.15s-7.6s just to reopen after closing), so that
    assumption can be wrong: the reference then captures a still-
    transitioning or partially-open view. Confirmed live: this produced 823
    "dead pixels" forming one contiguous block (real scene content
    misidentified as defects, not actual defects), permanently smeared into
    every subsequent frame via inpainting.
    This instead waits for the raw signal to actually go uniform (low
    std, sustained across several checks) before trusting it, averages
    several such frames for a lower-noise reference, and -- as a hard
    safety net regardless of whether the wait was long enough -- refuses to
    apply dead-pixel inpainting at all if the flagged count is implausibly
    high (real defects on this sensor have been a handful of pixels in
    every observed case, never more than ~20)."""
    camera.cap.set(cv2.CAP_PROP_ZOOM, 0x8000)
    start = time.time()
    consecutive_stable = 0
    frame = None
    while time.time() - start < close_wait_timeout:
        camera.cap.set(cv2.CAP_PROP_ZOOM, 0x8000)
        ret, frame = camera.read(raw=True)
        if ret and frame.std() < std_threshold:
            consecutive_stable += 1
            if consecutive_stable >= stable_checks:
                break
        else:
            consecutive_stable = 0
        time.sleep(0.2)
    else:
        print(f"Warning: shutter didn't settle within {close_wait_timeout:.0f}s "
              f"(last std={frame.std():.1f}) -- calibrating anyway, may be imperfect.", file=sys.stderr)

    frames = []
    for _ in range(num_avg_frames):
        camera.cap.set(cv2.CAP_PROP_ZOOM, 0x8000)
        ret, frame = camera.read(raw=True)
        if ret:
            frames.append(frame.astype(np.float32))
    reference = np.mean(frames, axis=0)
    camera.reference_frame = reference
    camera.offset_mean = float(np.mean(reference))

    min_val, max_val = float(reference.min()), float(reference.max())
    threshold = min_val + (max_val - min_val) * 0.05
    dead_count = int(np.count_nonzero(reference < threshold))
    if 0 < dead_count <= dead_pixel_cap:
        camera.dead_pixels_mask = cv2.inRange(reference, 0, threshold).astype(np.uint8)
    else:
        camera.dead_pixels_mask = None
    return dead_count


def smooth_frame(frame, ksize=5):
    """This sensor's per-pixel readout noise is high enough that, with a
    thermally uniform scene (the common case), the auto-contrast display
    stretch turns it into pure structureless static -- confirmed visually:
    a real scene became indistinguishable salt-and-pepper noise. A 20-frame-
    averaged NUC reference only reduced it ~30% (so it's not primarily a
    calibration-reference artifact), while this same light blur every real
    thermal camera applies for exactly this reason recovers clear structure.
    Rounds back to int for use as a lut index, so numeric readouts (which
    read from this same smoothed frame) stay consistent with the display."""
    smoothed = cv2.GaussianBlur(frame.astype(np.float32), (ksize, ksize), 0)
    return np.clip(np.round(smoothed), 0, 16383).astype(np.uint16)


def robust_extremes(temps, low_pct=1.0, high_pct=99.0):
    """Min/max ignoring the top/bottom 1% of pixels, so a single dead or
    noisy pixel (common on this sensor) can't dominate the reading."""
    lo, hi = np.percentile(temps, [low_pct, high_pct])
    clipped = np.clip(temps, lo, hi)
    min_idx = np.unravel_index(np.argmin(clipped), clipped.shape)
    max_idx = np.unravel_index(np.argmax(clipped), clipped.shape)
    return min_idx, float(clipped[min_idx]), max_idx, float(clipped[max_idx])


def draw_scale_bar(canvas, min_t, max_t, palette_index, height):
    x0 = canvas.shape[1] - BAR_WIDTH
    grad = np.linspace(255, 0, height, dtype=np.uint8).reshape(height, 1)
    grad_bgr = np.repeat(cv2.cvtColor(grad, cv2.COLOR_GRAY2BGR), 20, axis=1)
    canvas[0:height, x0 + 10:x0 + 30] = apply_palette(grad_bgr, palette_index)
    cv2.putText(canvas, f"{max_t:.1f}", (x0 + 32, 14), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (255, 255, 255), 1, cv2.LINE_AA)
    cv2.putText(canvas, f"{min_t:.1f}", (x0 + 32, height - 4), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (255, 255, 255), 1, cv2.LINE_AA)


def mark_point(canvas, x, y, temp, color, width, height):
    x = int(np.clip(x, 0, width - 1)) * DISPLAY_SCALE
    y = int(np.clip(y, 0, height - 1)) * DISPLAY_SCALE
    cv2.circle(canvas, (x, y), 5, (0, 0, 0), 2)
    cv2.circle(canvas, (x, y), 5, color, -1)
    cv2.putText(canvas, f"{temp:.1f}C", (x + 8, y - 6), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 0, 0), 2, cv2.LINE_AA)
    cv2.putText(canvas, f"{temp:.1f}C", (x + 8, y - 6), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (255, 255, 255), 1, cv2.LINE_AA)


HELP_LINES = [
    "p / o    next / previous color gradient",
    "1-6      jump directly to a gradient",
    "k        calibrate: type real temp at center crosshair",
    "         (a few frames while it solves for the right value)",
    "c        hardware shutter/NUC recalibration",
    "e        set emissivity (0.01-1.0)",
    "r        reset to the default starting guess",
    "h        toggle this help",
    "q / Esc  quit",
]


def draw_help_overlay(canvas):
    x0, y0 = 10, 10
    box_w = 440
    box_h = 22 * len(HELP_LINES) + 20
    overlay = canvas.copy()
    cv2.rectangle(overlay, (x0, y0), (x0 + box_w, y0 + box_h), (0, 0, 0), -1)
    canvas[:] = cv2.addWeighted(overlay, 0.75, canvas, 0.25, 0)
    for i, line in enumerate(HELP_LINES):
        y = y0 + 24 + i * 22
        cv2.putText(canvas, line, (x0 + 12, y), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (255, 255, 255), 1, cv2.LINE_AA)


def write_virtual_cam_frame(canvas):
    """Publish one frame to the camera extension as raw 32BGRA.

    Written to a temp file then renamed: rename is atomic on the same
    filesystem, so the extension always reads a complete frame rather than
    catching a half-written one (it reads the file on its own 25fps timer,
    with no locking between the two processes)."""
    bgra = cv2.cvtColor(canvas, cv2.COLOR_BGR2BGRA)
    tmp = VIRTUAL_CAM_FRAME.with_suffix(".tmp")
    tmp.write_bytes(bgra.tobytes())
    tmp.replace(VIRTUAL_CAM_FRAME)


def wait_for_shutter_reopen(camera, timeout=20.0):
    """The physical shutter stays closed after calibration until it's
    re-commanded (it has to be sent faster than once/sec to stay shut, per
    irpythermal.py's own comment) -- but how long it then takes to actually
    reopen is highly variable, confirmed empirically anywhere from ~0.15s to
    7.6s, and occasionally longer. Returns the first frame after it reopens,
    or the last (still-flat) frame with a warning if it never does within
    the timeout."""
    start = time.time()
    frame = None
    while time.time() - start < timeout:
        ret, frame = camera.read()
        if ret and frame.std() > 0.5:
            return frame
        time.sleep(0.15)
    print(f"Warning: shutter hasn't visibly reopened after {timeout:.0f}s -- showing a flat frame; "
          "it should catch up on its own, or try c again.", file=sys.stderr)
    return frame


def main():
    parser = argparse.ArgumentParser(description="Xtherm T2S+ thermal viewer")
    parser.add_argument("--device", type=int, default=None, help="Force an AVFoundation index instead of auto-detecting by name")
    parser.add_argument("--emissivity", type=float, default=DEFAULT_EMISSIVITY,
                         help="Target surface emissivity 0.01-1.0 (default 0.95). Set this at launch, not with "
                              "the in-app 'e' key -- this camera only reliably accepts one emissivity change per session.")
    parser.add_argument("--virtual-cam", action="store_true",
                         help="Also publish each frame to the macOS camera extension (camera_extension/), making the "
                              "thermal view available as a camera source in Teams/Zoom/etc. Requires the extension "
                              "to be installed and activated first.")
    args = parser.parse_args()

    if args.virtual_cam:
        if not APP_GROUP_ID:
            print(
                "--virtual-cam needs the App Group of your build of the camera "
                "extension, which embeds your signing team:\n"
                "  T2S_APP_GROUP=<TeamID>.cat.sysop.t2scamera python3 thermal_view.py --virtual-cam\n"
                "Find <TeamID> with: codesign -dv /Applications/T2SCamera.app",
                file=sys.stderr,
            )
            sys.exit(1)
        VIRTUAL_CAM_DIR.mkdir(parents=True, exist_ok=True)
        print(f"Virtual camera output enabled -> {VIRTUAL_CAM_FRAME}")

    try:
        video_dev = t2s_capture.FFmpegUVCCapture(device_index=args.device)
    except RuntimeError as e:
        print(e, file=sys.stderr)
        sys.exit(1)

    print("Opening T2S+ (raw sensor mode) -- this can take up to ~20s while it stabilizes...")
    camera = irpythermal.Camera(video_dev=video_dev, camera_raw=True, fixed_offset=0.0)

    wait_for_shutter_reopen(camera)

    print("Setting radiometric parameters (emissivity, distance, ambient/reflected temp)...")
    startup_emissivity = max(0.01, min(1.0, args.emissivity))
    camera.set_emissivity(startup_emissivity)
    camera.set_distance(DEFAULT_DISTANCE_M)
    camera.set_amb(DEFAULT_AMBIENT_C)
    camera.set_reflection(DEFAULT_REFLECTED_C)
    camera.save_parameters()
    time.sleep(0.3)

    saved_offset = load_saved_shutter_offset()
    camera.offset_temp_shutter = saved_offset if saved_offset is not None else DEFAULT_SHUTTER_OFFSET
    offset_is_measured = saved_offset is not None

    palette_index = 0
    print("T2S+ thermal viewer")
    if saved_offset is not None:
        print(f"Loaded a previously calibrated shutter offset ({saved_offset:.1f}).")
    print("Press k and type a real known temperature at the center crosshair to calibrate --")
    print("the app solves for the right correction over a few frames.")
    print("Keys: p/o = next/prev palette, 1-6 = pick palette, k = calibrate (known ref temp),")
    print("      c = hardware shutter/NUC recalibration, e = set emissivity, r = reset to default, q = quit")
    print("Press h in the app window any time to see this list on screen.")

    win = "T2S+ Thermal"
    cv2.namedWindow(win, cv2.WINDOW_NORMAL)

    input_mode = None
    input_buffer = ""
    show_help = False

    try:
        while True:
            ret, frame = camera.read()
            if not ret:
                print("Failed to read a frame from the camera.", file=sys.stderr)
                break

            frame = smooth_frame(frame)
            info, lut = camera.info()
            temps = lut[frame]
            min_idx, min_t, max_idx, max_t = robust_extremes(temps)
            center_t = float(temps[camera.height // 2, camera.width // 2])

            vis = cv2.normalize(frame.astype(np.float32), None, 0, 255, cv2.NORM_MINMAX).astype(np.uint8)
            vis_bgr = cv2.cvtColor(vis, cv2.COLOR_GRAY2BGR)
            heat = apply_palette(vis_bgr, palette_index)
            heat = cv2.resize(heat, (camera.width * DISPLAY_SCALE, camera.height * DISPLAY_SCALE), interpolation=cv2.INTER_CUBIC)

            canvas = np.zeros((heat.shape[0], heat.shape[1] + BAR_WIDTH, 3), dtype=np.uint8)
            canvas[:, :heat.shape[1]] = heat
            draw_scale_bar(canvas, min_t, max_t, palette_index, heat.shape[0])

            mark_point(canvas, max_idx[1], max_idx[0], max_t, (0, 0, 255), camera.width, camera.height)
            mark_point(canvas, min_idx[1], min_idx[0], min_t, (255, 0, 0), camera.width, camera.height)
            mark_point(canvas, camera.width // 2, camera.height // 2, center_t, (255, 255, 255), camera.width, camera.height)

            if input_mode is None:
                cal_state = "calibrated" if offset_is_measured else "default guess"
                hud = f"{PALETTES[palette_index][0]}  center {center_t:.1f}C  [{cal_state}]"
            elif input_mode == "offset":
                hud = f"Center reads {center_t:.1f}C -- type its REAL temperature, Enter=ok Esc=cancel: {input_buffer}_"
            elif input_mode == "emissivity":
                hud = f"Emissivity 0.01-1.0, Enter=ok Esc=cancel: {input_buffer}_"
            cv2.putText(canvas, hud, (10, canvas.shape[0] - 10), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 0, 0), 3, cv2.LINE_AA)
            cv2.putText(canvas, hud, (10, canvas.shape[0] - 10), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 255), 1, cv2.LINE_AA)

            if show_help:
                draw_help_overlay(canvas)

            if args.virtual_cam:
                write_virtual_cam_frame(canvas)

            cv2.imshow(win, canvas)
            key = cv2.waitKey(1) & 0xFF

            if input_mode is not None:
                if key in (13, 10):
                    try:
                        value = float(input_buffer)
                        if input_mode == "offset":
                            print(f"Calibrating against {value:.1f}C...")
                            solved = calibrate_shutter_offset(camera, value)
                            offset_is_measured = True
                            save_shutter_offset(solved)
                            print(f"Calibrated: offset_temp_shutter={solved:.2f} (saved -- future launches will start from this)")
                        elif input_mode == "emissivity":
                            v = max(0.01, min(1.0, value))
                            camera.set_emissivity(v)
                            camera.save_parameters()
                            print(f"Sent emissivity={v} to the camera. Confirmed limitation: this camera's "
                                  "parameter writes apply on an unpredictable delay -- sometimes not until a "
                                  "later launch, and reading it back immediately can show a stale value even "
                                  "when the write eventually lands, so there's no reliable pass/fail to report "
                                  "here. For a value you can count on, use --emissivity at launch instead.")
                    except ValueError:
                        print("Invalid number, unchanged.")
                    input_mode = None
                elif key == 27:
                    input_mode = None
                elif key in (8, 127):
                    input_buffer = input_buffer[:-1]
                elif key != 255 and chr(key) in "0123456789.-":
                    input_buffer += chr(key)
                continue

            if key in (ord('q'), 27):
                break
            elif key == ord('p'):
                palette_index = (palette_index + 1) % len(PALETTES)
            elif key == ord('o'):
                palette_index = (palette_index - 1) % len(PALETTES)
            elif ord('1') <= key <= ord('6'):
                idx = key - ord('1')
                if idx < len(PALETTES):
                    palette_index = idx
            elif key == ord('k'):
                input_mode = "offset"
                input_buffer = ""
            elif key == ord('r'):
                camera.offset_temp_shutter = DEFAULT_SHUTTER_OFFSET
                offset_is_measured = False
                print(f"Reset: shutter offset back to the default guess ({DEFAULT_SHUTTER_OFFSET:.1f}) "
                      "(previously saved value on disk is untouched -- restart to reload it).")
            elif key == ord('c'):
                print("Recalibrating (closing shutter for flat-field correction)...")
                dead_count = calibrate_hardware(camera)
                if dead_count > 50:
                    print(f"{dead_count} pixels looked defective (way more than normal) -- skipped "
                          "dead-pixel correction rather than risk smearing real scene content. "
                          "Try c again if the image looks off.")
                wait_for_shutter_reopen(camera)
                print("Done.")
            elif key == ord('e'):
                input_mode = "emissivity"
                input_buffer = ""
            elif key == ord('h'):
                show_help = not show_help
    finally:
        camera.release()
        cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
