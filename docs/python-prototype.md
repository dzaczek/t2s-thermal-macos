# The Python prototype

[← README](../README.md)

## Setup

```
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
```

`ffmpeg` must be installed (`brew install ffmpeg`) -- everything else needed
(`vendor/uvc-util/build/uvc-util`) is already built and included. If it
doesn't run on your Mac (wrong CPU architecture), rebuild it with:
```
vendor/uvc-util/build.sh
```
(needs Xcode Command Line Tools' `clang`, not full Xcode).

## Run

```
source venv/bin/activate
python3 thermal_view.py
```

The camera is found by name ("T2S+"), not a fixed index -- macOS's
AVFoundation device ordering isn't stable across runs, so don't hardcode one.
If auto-detection ever picks the wrong device, force it with
`--device <n>` using whatever index `ffmpeg -f avfoundation -list_devices
true -i ""` currently shows for it.

**Do not run with `sudo`** -- root does not hold the same camera (TCC)
permission as your normal user, and it changes AVFoundation's device
enumeration entirely.

Startup takes up to ~20 seconds: the camera stabilizes and runs an initial
shutter/NUC calibration, and its physical shutter stays closed for another
1-2 seconds afterward (the app waits this out automatically before showing
the first frame). This is normal -- the library prints progress throughout.

macOS will prompt for camera permission the first time -- allow it.

### Keyboard controls

| Key | Action |
|---|---|
| `p` / `o` | Next / previous color gradient |
| `1`-`6` | Jump directly to a gradient (Ironbow, White Hot, Black Hot, Rainbow, Hot, Inferno) |
| `k` | Calibrate: type the known real temperature at the center crosshair (typed directly in the app window). Takes a few frames while it solves for the right correction -- see Calibration below |
| `c` | Hardware recalibration: closes the shutter and re-runs flat-field (NUC) correction |
| `e` | Attempt to change emissivity (0.01-1.0) on the sensor -- best-effort, see Calibration |
| `r` | Reset to the default starting guess |
| `h` | Toggle this shortcut list on screen |
| `q` / `Esc` | Quit |

The max temperature (red marker), min temperature (blue marker, both robust
to single dead/noisy pixels -- see Calibration) and center spot (white
marker) are always shown, plus a color scale bar on the right edge labeled
with the current frame's min/max.
