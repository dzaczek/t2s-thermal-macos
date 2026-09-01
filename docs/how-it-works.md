# How it works

[← README](../README.md)

## Supported hardware

| | |
|---|---|
| Camera | Xinfrared / Xtherm **T2S+** (also sold as InfiRay T2S+), hardware revision **V2** |
| USB identity | `0x1514:0x0001` — macOS reports `UVC Camera VendorID_5396 ProductID_1` |
| Sensor | 256×192 microbolometer, plus 4 rows of metadata = 256×196 frames |
| Stream | YUY2 (`yuvs`), fixed **25 fps**, one format only |
| macOS | 14.0 or later (the camera extension needs `.external` device support) |
| Mac | Apple Silicon and Intel; developed and tested on Apple Silicon |

Other cameras in this family (P2 Pro, T2L, 384×288 models) are **not**
supported as-is: the decoder's layout constants are specific to the 256-wide
sensor. The radiometry itself comes from
[IR-Py-Thermal](https://github.com/diminDDL/IR-Py-Thermal), which covers more
of the family, so porting is mostly a matter of the constants.

Any T2S+ unit should work, but **each camera needs its own one-point
calibration** — see
[Using a different unit](#using-a-different-unit-of-the-same-camera).

## From raw counts to temperature

The camera is a UVC device, but it does not behave like a webcam.

**1. It streams raw sensor counts, not a picture.** Put into raw mode, each
frame is 256×196 of 14-bit ADC values smuggled through a YUY2 container: 192
rows of image plus 4 rows of metadata. The metadata carries the unit's factory
calibration constants (`cal00`..`cal05`), the focal-plane-array and shutter
readings, and the current emissivity / distance / humidity settings.

**2. Temperature comes from a physics model, not a lookup.** Those constants
feed a radiometric model — Planck-style radiance inversion with atmospheric
transmittance — which is evaluated once per frame into a 16384-entry table
mapping raw count to °C. Every pixel is then a table lookup. The model is
ported from [IR-Py-Thermal](https://github.com/diminDDL/IR-Py-Thermal), which
reverse-engineered it for this camera family.

Two things had to be solved on top of it:

- The parameters must be **committed to the camera** with a save command, or
  they sit at a bogus factory default (emissivity 0.02) and the whole table
  comes out `NaN`.
- This hardware revision's **shutter-temperature register is unusable**, and
  upstream gave up on it. The app treats it as one unknown and solves for it
  by Newton's method against a single known temperature — that is what ⌘K
  does, and the result is persisted.

**3. Control goes over a UVC register back door.** The firmware reuses the
standard "Zoom, Absolute" control as a general register-poke channel. libusb
cannot claim the interface on macOS (the system UVC driver owns it), so
control writes go through IOKit directly.

**4. The virtual camera is a CoreMediaIO system extension.** The app renders
one frame and publishes it into a shared App Group container; the extension,
which macOS runs as a separate process, reads that and serves it as a capture
device. One render feeds the window, the virtual camera and the recorder, so
a call participant sees exactly what is in the window.

## Why this isn't a simple `cv2.VideoCapture` app

Two things about this specific camera don't work the normal way on macOS:

1. **`cv2.VideoCapture` cannot open this camera at all** -- it raises
   `VIDEOIO(AVFOUNDATION): raised unknown C++ exception!` on open, every time,
   with every OpenCV version tried. This matches a confirmed, unresolved
   upstream bug (`opencv/opencv#22912`) where someone else hit the identical
   crash with their own USB thermal camera. `ffmpeg`'s AVFoundation input
   opens it fine, so this app captures frames via an `ffmpeg` subprocess
   instead.

2. **The camera's calibration/mode commands go over the UVC "Zoom, Absolute"
   control** (confirmed by decoding its USB descriptor: Camera Terminal ID 1
   declares that control, selector `0x0B`). On Linux, `cv2.CAP_PROP_ZOOM`
   reaches it directly. On this Mac, `pyusb`/`libusb` can *read* the
   descriptor but cannot *claim the interface* to send it (`errno 13:
   insufficient permissions` -- a known libusb-on-macOS/UVC limitation, root
   included). The vendored `uvc-util` (`vendor/uvc-util/`, pure IOKit, MIT)
   sends the same control successfully instead.

`t2s_capture.py` is a small shim presenting just enough of a
`cv2.VideoCapture`-like interface (`.read()`, `.set()`, `.get()`,
`.release()`) backed by those two, so `irpythermal.py` (the capture/decode
library, see Credits) runs completely unmodified on top of it.

This was verified against the live camera: after switching to raw sensor
mode through this path, the captured pixel values land exactly in the range
the camera's own embedded metadata reports as min/max -- i.e. the frame
layout, the control command, and the decode math all check out against real
hardware, not just in theory.

### Virtual camera

The app writes each rendered frame into the App Group container
`<TeamID>.cat.sysop.t2scamera`, and a CoreMediaIO camera extension bundled
inside the app publishes that as **"T2S+ Thermal Camera"**.

Install it once via the app menu -> *Install / Manage Camera Extension...* ->
**Activate**, then approve it in System Settings -> General -> Login Items &
Extensions -> Camera Extensions. The virtual camera only produces live frames
while the app is running (it shows mid-grey otherwise).

Because the app itself is sandboxed, it needs `com.apple.security.device.camera`
and `com.apple.security.device.usb`. Without the camera entitlement
`AVCaptureSession` yields no frames *and no error*, which looks exactly like a
dead camera.

### Render resolution

The frame is rendered at **1716x1152** and shown in the window downscaled by
two. That is driven by the virtual camera, not the window: a video-call client
scales the feed up into its tile, and at the old 858x576 the readouts came out
unreadable. Overlay text and strokes are scaled by 2.6 rather than 2, so they
also take up more of the frame than they used to -- sharpness alone does not
help in a small tile.

**Changing the render size means re-activating the extension.** The extension
hard-codes the frame size in `Config.swift` (`fixedCamWidth`/`fixedCamHeight`)
and must match the app exactly; if it does not, it rejects every frame and
publishes flat grey. After changing it:

```bash
./build.sh
/Applications/T2SCamera.app/Contents/MacOS/T2SCamera --activate-extension
```

Check with `systemextensionsctl list` that the new build number is the one
marked `[activated enabled]`. The superseded copy sits at `[terminated waiting
to uninstall on reboot]`, which is normal.

Cost of the larger render, measured: 11.9ms -> 15.5ms per frame, still 25.2
frames arriving and 25.2 processed, so nothing is dropped.

### Using a different unit of the same camera

Mostly yes, with one thing you must redo per camera.

**Portable, because it comes from the camera itself:** the factory calibration
constants `cal00..cal05`, the FPA and shutter readings, emissivity and the
atmospheric parameters are all read out of each frame's own metadata rows, so
another unit brings its own. The NUC reference and the dead-pixel map are
rebuilt per unit by **Recalibrate Sensor**.

**Not portable: `shutter_offset.json`.** It corrects this hardware revision's
unusable shutter-temperature register and is solved against a known
temperature, so its value belongs to the unit (and to the conditions) it was
solved on. Copying it to another camera gives confidently wrong readings.
Delete it and press ⌘K on the new camera instead.

**Device matching** no longer depends on the name. The app looks for USB
`VendorID_5396 ProductID_1` (0x1514:0x0001), falling back to any device
advertising a 256x196 format, and only then to the name "T2S+". That survives a
unit or firmware revision that names itself differently, and it cannot latch
onto our own virtual camera, which is 1716x1152.

**Model-level constants** in `ThermalDecoder` (`fpaOffset`, `fpaDivisor`,
`cal00Offset`) come from irpythermal's 256-wide profile, so they hold for this
sensor family but not for a different resolution.

Untested: only one physical unit was ever available here, so the above is
reasoning from where each value comes from, not from two cameras side by side.

## Files

### Native app (`camera_extension/`)

- `T2SCameraApp/` -- the Swift app: `ThermalCapture` (AVFoundation),
  `ThermalDecoder` (metadata + temperature table), `UVCControl` (IOKit register
  writes), `Palettes`, `ThermalProcessor`, `ThermalRenderer`, `Calibration`,
  `VirtualCameraFeed`, `ThermalViewController`, `ExtensionInstaller`
- `T2SCameraExtension/` -- the CoreMediaIO camera extension that publishes the
  virtual camera
- `project.yml` / `build.sh` -- xcodegen project and one-shot build + install
- `make_icon.swift` -- generates the app icon set

### Python prototype

- `thermal_view.py` -- the app: capture loop, calibration solver, palettes,
  overlay, calibration UI
- `irpythermal.py` -- vendored library: frame capture, hardware calibration/
  control, AND its physics-based temperature formula (see Calibration above
  for what it took to make that formula trustworthy on this camera);
  unmodified except a 3-line NumPy 2.x compatibility fix (see its own
  comments -- upstream was written against NumPy 1.x; `python_int |
  numpy.uint8` now raises `OverflowError` instead of upcasting)
- `t2s_capture.py` -- the ffmpeg + uvc-util shim described above
- `vendor/uvc-util/` -- vendored native control-sending tool
- `shutter_offset.json` -- your calibrated `offset_temp_shutter` value,
  created after your first `k` calibration; delete it to go back to the
  built-in guess
