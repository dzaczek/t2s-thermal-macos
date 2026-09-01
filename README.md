# T2S+ Thermal Camera for macOS

![The app: toolbar, a line profile with its markers, measurement areas with inline trend plots, and the side panel](docs/app.png)

The Xinfrared T2S+ is a decent little thermal camera that ships with no Mac
software at all. This is Mac software for it.

Every pixel is a real temperature, not a false-colour guess. Drop spots and
boxes on the things you care about, drag a line across a wall and read the
profile along it, then write the numbers out to CSV.

## Thermal video calls

The app installs a virtual camera, so **T2S+ Thermal Camera** shows up in the
camera list in Teams, Zoom, Meet and FaceTime. Pick it and the people on the
call see heat instead of your face. Your measurement boxes, readouts and trend
plots go out with the picture.

Handy for showing a client the hot connector you just found, without exporting
anything first. Also a reliable way to derail a standup.

## What you get

* Six palettes, with the temperature scale locked to a range you set or
  stretched to whatever is in frame
* Spots, boxes and lines. A box gives you min, average and max, and marks which
  pixel the max actually came from. A line gives you a profile, and marks the
  peaks along it (or the troughs, or where it crosses its own average)
* Per-object emissivity, set per box, because bare metal sitting next to
  painted steel reads far too cold on a single global setting
* Threshold alarms that flood everything hotter or colder than a value in flat
  colour
* Highlighting for anything that has warmed up or cooled down since you started
  watching, which is what you want when you are hunting for a fault
* Live temperature-vs-time plots, docked above or below the image, or drawn as
  sparklines next to each measurement
* PNG stills with the full 256x192 temperature matrix beside them as CSV,
  H.264 video, time-lapse, and a running CSV log of your measurements

## Get it

[**Download the latest release**](https://github.com/dzaczek/t2s-thermal-macos/releases/latest),
open the disk image and drag the app to Applications. It is signed and
notarised, so it opens without any Gatekeeper argument.

It has to live in `/Applications`. macOS refuses to load a system extension
from anywhere else, and the virtual camera is a system extension.

For the virtual camera, open **Install / Manage Camera Extension…** from the
app menu, click Activate, then approve it under **System Settings ▸ General ▸
Login Items & Extensions ▸ Camera Extensions**. That is a one-off.

## Calibrate it first

This hardware revision reports a shutter temperature that is unusable, so the
app solves for the correction instead of trusting it. Aim the centre crosshair
at something whose temperature you actually know and press **⌘K**.

Skip this and the picture is still right, but the numbers on it are not. The
value is saved, so it is genuinely a one-off per camera. Do not copy it between
cameras: it belongs to the unit it was solved on.

## What you need

macOS 14 or later, and an Xinfrared or Xtherm **T2S+**, hardware revision V2
(USB `0x1514:0x0001`). Other cameras in the family are not supported by this
build; see [how it works](docs/how-it-works.md) for what it would take.

## Build it yourself

You need Xcode, `brew install xcodegen`, and an Apple Developer account,
because a system extension will not load unsigned.

```bash
cd camera_extension
./build.sh --run
```

That finds Xcode and your signing team on its own, so there is nothing to edit
first. Nothing in the source hard-codes anybody's team identifier.
[Building and releasing](docs/building.md) covers signing, notarisation and
producing a disk image.

## Documentation

* [Using the app](docs/using.md), for the measurement tools and everything the
  window does
* [How it works](docs/how-it-works.md), on the radiometry, the USB back door
  the firmware exposes, and why the obvious approaches all fail on macOS
* [Building and releasing](docs/building.md)
* [The Python prototype](docs/python-prototype.md), kept as the reference
  implementation the Swift port is checked against

## Licence

GPLv3, because the temperature model is a port of
[IR-Py-Thermal](https://github.com/diminDDL/IR-Py-Thermal) by diminDDL, who
reverse-engineered it for this camera family. Without that work this project
would not exist. USB control in the prototype uses
[uvc-util](https://github.com/jtfrey/uvc-util) (MIT).

You can use, change, sell and pass this on. Anything you pass on has to be
GPLv3 too, with its source.
