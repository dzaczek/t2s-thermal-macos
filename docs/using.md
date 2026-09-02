# Using the app

[← README](../README.md)

## Window layout

The window is a video area with a control bar under it and a fixed 300pt panel
on the right. All of it is laid out in `viewDidLayout` from the current view
size rather than from fixed frames, so resizing cannot leave a control sitting
on top of the video. The thermal image is aspect-fit inside its area, letterboxed
rather than stretched -- which also keeps click-to-place accurate, since the
mouse mapping uses the same rect the image is drawn into.

The **toolbar** carries what gets changed constantly -- palette, markers, plot
placement, range mode, calibrate, NUC, save photo and record. It sits in the
title bar, so unlike another row of buttons it costs the video area nothing,
and it is customisable: right-click to add, remove or rearrange (new-spot
detection and the virtual-camera toggle are available there too).

The control bar under the image holds the numeric inputs: scale min/max, the
two alarm thresholds and the new-spot threshold.

The menu bar still holds everything, with the keyboard shortcuts and a
checkmark showing the current setting:

- **Capture** -- Save Photo (⌘S), Recording (⇧⌘R), Time-lapse, CSV Log, Open
  Output Folder (⇧⌘O)
- **Camera** -- Calibrate (⌘K), NUC (⌘R), Publish to Virtual Camera
- **View** -- Palette (⌘1..⌘6), Markers, Live Plot, Temperature Range,
  Highlight New Hot / Cold Spots

## Measurement tools

**Click the image to drop a spot; drag to draw whichever of area or line is
selected.** Pick that with **Drag creates** in the toolbar or under
**View ▸ Drag Creates** — and holding ⇧shift inverts it, so the other tool is
always one modifier away without changing the mode. The control bar under the
image spells out what the current setting does.

- A **spot** (`Sp1`, `Sp2`, ...) reports the average of its 3x3 neighbourhood,
  not one pixel. Single-pixel readout on this sensor jitters by around a degree.
- An **area** (`Ar1`, `Ar2`, ...) reports min / average / max, and marks where
  inside it the hottest and coldest pixels actually are -- an average alone
  hides a hot spot in the corner, which is usually what you are looking for.
- A **line** (`Li1`, `Li2`, ...) is a profile: it reports min / average /
  **median** / max along its length and marks **N points** on it. Set how many
  and what they point at in the side panel:
  - **hot** / **cold** — the N most prominent peaks or troughs
  - **avg** / **med** — where the profile *crosses* its own average or median

  The median is worth having next to the average: one hot pixel drags the mean
  but not the median, so a large gap between them says the profile is
  dominated by something small.
- Selecting a row and setting **Emissivity** overrides it for that object only,
  for a scene with two materials in one frame (bare metal reads far too cold
  next to painted steel). Blank means "use the camera-wide value". The override
  is applied host-side; the camera keeps its own setting.

### Why crossings for avg/median, and peaks for hot/cold

Taking the N highest readings along a line is useless: they all land on the
same hot spot, one pixel apart. So **hot/cold** looks for *local* extrema, and
**avg/med** marks where the profile crosses that value -- for those two,
"nearest the average" would again pile every marker onto one stretch, whereas
crossings are distinct places.

Three details that only showed up in testing:

- A peak must be **strictly** better than at least one neighbour. Comparing
  with `>=` on both sides made every pixel of a flat wall a peak, so asking
  for 9 markers on a uniform surface returned 9 identical readings.
- A crossing needs a **strict sign change**. Counting a sample that merely sits
  on the target turned a flat wall -- exactly where the median tends to land --
  into a crossing at every pixel.
- Separation is measured **along the profile**, not by frame pixel index. On any
  line that is not horizontal, consecutive samples differ by about a row width,
  so an index test never fires and the markers pile onto one spot.

If a profile has fewer distinct features than you asked for, you get fewer
markers rather than invented ones.

## Built-in markers

The hottest and coldest markers report the **true** extremes of the frame and
sit on the pixel they came from.

They did not always. They used to clip to the 1st and 99th percentile so that a
single noisy pixel could not dominate, which threw away any object smaller than
1% of the frame, or 491 pixels of 49152. A soldering iron at 60 °C in a 20 °C
room was reported as 20 °C, with the marker parked on pixel zero. Single-pixel
noise is already handled by the 5x5 blur and the dead-pixel repair, so the
clipping was doing harm and no good.

One consequence worth knowing: with **Colour Scale: Auto**, one small very hot
thing now stretches the palette across the whole frame and everything else goes
dark. That is what a thermal camera should do, and **Manual** is there for when
you would rather keep the contrast on the background.


**max / min / centre** are toggled under **View > Markers**. Turning one off removes its
marker, its plot trace and its CSV column together -- what is on screen is what
is plotted and logged. The global max in particular is worth hiding once you
have placed your own objects, since it tends to latch onto a reflection.

## New hot / cold spots

**View > Highlight New Hot / Cold Spots** outlines areas that changed by more than the
given threshold, in a dashed red (hotter) or cyan (colder) box labelled with
the peak difference -- visually distinct from the solid boxes of placed
objects.

The baseline is captured the moment you tick the box, then drifts slowly (~45s
time constant). So "new" means *recently changed*: a spot that has been hot
since you started is not flagged, one that just appeared is, and one that stays
hot fades out of the highlight once the baseline catches up. Untick and tick
again to re-baseline on the scene as it is now.

Regions smaller than 12 connected pixels are ignored, so sensor noise does not
register as a spot.

## Live plot

**View > Live Plot** places a temperature-vs-time chart **above** or **below** the
image, or draws a small sparkline **next to each point** (that last one is
rendered into the frame itself, so it also reaches the virtual camera). The
chart holds two minutes and autoscales its temperature axis -- a trend of a few
tenths of a degree is what you are watching for, and a fixed axis flattens it
into a straight line.

Everything visible is plotted: enabled built-in markers plus every measurement
object (spots by value, areas by average).

## CSV logging over time

**Start CSV Log** appends a row every N seconds to
`T2S_log_<timestamp>.csv`: `timestamp`, `elapsed_s`, then one column per
visible marker and object (areas get `_min`, `_avg` and `_max`).

Columns are fixed when the log starts, so an object placed later is not logged
-- a CSV whose header stops matching its rows halfway down is worse than one
that misses a late addition. Stop and restart the log to pick up new objects.

This is separate from the per-photo CSV: that one is a single frame's 256x192
matrix, this one is a time series of the measurement objects.

## Level/span and alarms

**View > Temperature Range > Auto** re-stretches the colour ramp to each frame. That is why a
thermally flat scene looks like static, and why the picture flickers when
something hot enters the frame. **Manual** pins the ramp to a fixed
min/max in °C, which is the standard fix and makes small differences readable.

**alarm > / alarm <** paint everything above/below a threshold flat red/blue
(an isotherm). Leave blank for off.

## Saving

Everything goes to **~/Pictures/T2S+ Thermal**.

- **Save Photo** (⌘S) writes a PNG. With **+ CSV** ticked it also writes the
  full 256x192 temperature matrix, which is what makes the capture radiometric
  -- a PNG is only a picture, the CSV stays measurable afterwards.
- **Record Video** (⇧⌘R) writes H.264 .mov. Frames are stamped with real
  elapsed time, so a dropped frame becomes a pause rather than speeding the
  video up.
- **Time-lapse** saves a still every N seconds for M minutes, then stops
  itself. It reuses the CSV setting.

## Calibrating the native app

The shutter offset is solved against one known temperature and then persisted
to `shutter_offset.json` **in the App Group container**, so it survives
restarts.

Do not copy the Python prototype's `shutter_offset.json` over it. Both solve
for the same physical quantity, but the value that comes out depends on the
camera state at the moment you calibrate, so a number solved in one is not
meaningful in the other -- calibrate the Swift app once with ⌘K instead.

## Measurement range

The camera has two hardware ranges, **−20 to 120 °C** and **−20 to 450 °C**,
under **Camera ▸ Measurement Range**. They are not a clamp on the same data:
the camera reports different calibration metadata for each, and the decoder
needs different corrections for each.

The app sets the range explicitly at startup rather than inheriting whatever
the camera was last left in, because decoding a frame against the wrong range
gives confidently wrong numbers. Measured on this unit, the same room read
23.6–26.4 °C in the normal range and 77–189 °C in the high range with the
normal-range maths applied.

**Each range needs its own calibration, and its own NUC.** Both are stored per
range and the flat-field reference is dropped automatically when you switch,
because it is raw sensor counts and those differ between ranges by thousands.
Carrying one across would make the image nonsense. So after switching: run
**Recalibrate Sensor** again, then calibrate.

### The high range is not calibrated out of the box

Its readings are **not valid** until you measure the correction yourself, and
the overlay says so in yellow while that is the case.

The correction factor upstream carries a `TODO verify these`, and it is not
guessable from outside. Two attempts to estimate it here from scene spans gave
0.039 and then 1.26, an order of magnitude apart, because each was comparing
different scenes. So the app applies no correction by default: an obviously
wrong number is safer than a plausible wrong one.

**Camera ▸ Calibrate with Two References…** measures it. Aim the crosshair at
something cool, type its temperature, then at something hot and type that. Two
points fix the scale and the offset exactly, and the result is stored for that
range. A pot of just-boiled water and a forehead work well: far apart and easy
to check.

The two temperatures have to be at least 5 °C apart. Entering the same value
twice fits a horizontal line, which renders every pixel as one flat temperature
and looks exactly like a dead camera. The app refuses such a fit rather than
saving it, and **Camera ▸ Reset Calibration for This Range** undoes a bad one.

### If ⌘K gives a wildly wrong reading

Ask for 28 °C and get −22, and the culprit is a stored two-point calibration
that the one-point solve was ignoring. That is fixed, but if a bad pair is
already saved, **Camera ▸ Reset Calibration for This Range** clears it and puts
the range back to defaults.

### When the high range is worth using

Only when the target is hotter than the normal range reaches. It spreads the
same 14 bits over 470 °C instead of 140, trading resolution for reach: the same
room scene gave 1376 counts of raw variation in the normal range and 60 in the
high one. A hot object still stands out clearly, but the background detail
around it does not.

For anything up to about 120 °C, which is most work, stay in the normal range.

## Calibration

**This app uses irpythermal.py's own physics-based temperature formula**
(`get_temp_table()`), which computes absolute temperature from this specific
unit's real factory calibration constants (`cal_00`..`cal_05`, read from the
camera's own metadata every frame) -- not an approximation. That wasn't
always true here: an earlier version of this app abandoned that formula
because it produced NaN across ~3800 of its 16384 entries and wasn't even
monotonic. Both problems traced to the same root cause, confirmed against
the real camera:

- `irpythermal.py`'s parameter setters (`set_emissivity` etc.) never call
  the separate `save_parameters()` command (UVC `0x80FF`) needed to actually
  commit a change, so emissivity was silently stuck at a bogus factory
  default (`0.02` -- near-mirror reflectivity, physically implausible).
  Calling `save_parameters()` right after fixes it (this app does so at
  startup) -- and with a sane emissivity, the NaN count dropped to zero.
- The remaining broken input is `camera.offset_temp_shutter`, a correction
  hook the library already defines for its own known-bad shutter-temperature
  reading on this V2 hardware (the library author: *"I was unable to
  determine the logic... left that as hard coded room temperature"*). Once
  emissivity was fixed, sweeping this value produced a clean, monotonic,
  smoothly-varying, plausible temperature curve with a stable, tight
  min/max spread -- the real calibration working correctly for the first
  time in this whole investigation, not a guessed slope.

- **On startup**, `offset_temp_shutter` defaults to `76.0`
  (`DEFAULT_SHUTTER_OFFSET` in `thermal_view.py`), measured to give a
  plausible ~20C in one test session. This gets you a believable image
  immediately, at the cost of accuracy until you calibrate.
- **`k`**: point the center crosshair at something of known temperature,
  type the real value in (right there in the app window). The app solves
  for the `offset_temp_shutter` value that makes the center read that
  temperature (Newton's method over a few frames, since the relationship
  isn't exactly 1:1 -- confirmed empirically), typically converging in well
  under a second.
- **The solved value is saved** to `shutter_offset.json` and auto-loaded on
  every future launch as the new starting guess. Unlike a sensor-electronics
  property, though, there's no strong guarantee this value is stable across
  sessions (it corrects a register the library's own author couldn't fully
  characterize) -- treat it as a good starting point that may still need a
  quick `k` touch-up, not a guaranteed-permanent fix.
- **`c` — hardware shutter/NUC recalibration**: the real per-pixel flat-field
  correction, done by briefly closing the camera's physical shutter. Run this
  if the image looks noisy/patterned, or after the camera's been running a
  while and drifted. Uses `calibrate_hardware()` rather than
  `irpythermal.py`'s own `camera.calibrate()` -- that function assumes the
  shutter is fully closed after a fixed ~1.5-2s delay before capturing a
  single frame as its reference, but shutter timing here is highly variable
  (confirmed empirically: 0.15s-7.6s just to *reopen*), and when that
  assumption is wrong the reference captures a still-transitioning or
  partially-open view. Confirmed live: this produced 823 "dead pixels"
  forming one contiguous block -- real scene content misread as sensor
  defects, then permanently smeared into every later frame by the library's
  own inpainting correction. `calibrate_hardware()` instead waits for the
  raw signal to actually go uniform (low, sustained std) before trusting
  it, and -- as a hard safety net regardless of whether that wait was
  enough -- refuses to apply dead-pixel correction at all if the flagged
  count is implausibly high (real defects here have never exceeded ~20
  pixels; a run flagging more skips the correction and tells you, rather
  than risk corrupting the image). The app waits for the shutter to
  physically reopen before showing frames again, which can itself take a
  few seconds for the same reason (times out after 20s with a warning
  instead of silently giving up early).

## Known limitation: sensor noise on low-contrast scenes

This sensor's own per-pixel readout noise is high enough that, pointed at a
thermally uniform scene, the auto-contrast display stretch can turn it into
near-structureless static -- confirmed directly: a real scene became
indistinguishable salt-and-pepper noise when the frame's real dynamic range
was very small. A 20-frame-averaged NUC reference (vs `irpythermal.py`'s
default single-frame reference) only reduced it ~30%, so it's not primarily
a calibration artifact; a light 5x5 Gaussian blur before display (`smooth_
frame()` in `thermal_view.py`) recovers real structure much more
effectively (~50% noise reduction, confirmed) and is what every commercial
thermal camera does for exactly this reason. Numeric readouts are computed
from this same smoothed frame, so they stay consistent with what's on
screen. Residual noise will still be more visible on a scene with very
little real temperature variation -- that's the sensor's actual noise floor
showing through, not a bug.
- **`e` — emissivity**: sends a real, working command (confirmed above) --
  but only the *first* emissivity change in a session reliably takes effect.
  Changing it again was confirmed to apply on an unpredictable delay (one
  test read back a value set by an *already-exited* earlier script), so
  there's no reliable way to confirm success or failure for an in-session
  change, and the app says so rather than guessing. For a value you can
  count on, set it once at launch: `python3 thermal_view.py --emissivity
  0.95`.
