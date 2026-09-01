# Building and releasing

[← README](../README.md)

## Build from source

Requires Xcode, [xcodegen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`) and an Apple Developer account for signing — a system
extension cannot be loaded unsigned.

```bash
cd camera_extension
./build.sh            # build, sign, install to /Applications
./build.sh --run      # ... and launch
```

`build.sh` finds Xcode via `xcode-select -p` and the signing team from your
keychain, so there is nothing to edit. If either guess is wrong, copy
`build.config.example` to `build.config` and set `T2S_DEVELOPER_DIR` /
`T2S_TEAM_ID`; that file is git-ignored.

Nothing in the source hard-codes a team identifier: the entitlements use
Xcode's `$(TeamIdentifierPrefix)`, and the App Group name is read back at
runtime from the build's own code signature (`Shared/AppIdentity.swift`).

### Releasing a signed, notarised build

```bash
xcrun notarytool store-credentials T2SCamera \
  --apple-id you@example.com --team-id XXXXXXXXXX --password <app-specific-password>

### Version and build number

`MARKETING_VERSION` in `project.yml` is the version; the build number is a
counter in `camera_extension/build_number.txt` that `build.sh` bumps on every
build and passes to xcodebuild. Both show in the window title and in
**About T2S+ Thermal Camera**.

### Performance

Build **Release**, not Debug. Swift without optimisation is not slightly slower
here, it is catastrophic: the 5x5 blur alone went from 100ms to 1ms, and the
whole frame from 151ms (~6fps) to 8.7ms. `build.sh` already uses Release.

**The camera is the ceiling.** It advertises exactly one mode -- 256x196 at a
fixed 25fps -- so 25fps is all the real thermal data there is. Measured
end to end, the app is already there: frames arrive at 25.4/s and 25.4/s are
processed (nothing dropped), using ~12ms of the 40ms budget, and the virtual
camera outputs a steady 25fps.

Run with `T2S_PROFILE=1` to print that breakdown every 5 seconds. Use it rather
than timing from outside -- polling the published frame file's mtime from a
shell undercounts badly, and reported 20fps for a pipeline actually running at
a full 25.

Never launch it with `sudo`: root does not hold the camera TCC permission and
sees a different, scrambled AVFoundation device list.

### App icon

The icon is generated, not a checked-in binary, so it stays editable and reuses
the Ironbow stops from `Palettes.swift` -- the icon and the live image are the
same colour ramp. To change it, edit `make_icon.swift` and re-run:

```bash
cd camera_extension
swift make_icon.swift T2SCameraApp/Assets.xcassets/AppIcon.appiconset
./build.sh
```

Each size is drawn natively rather than downscaled from one large canvas; the
viewfinder brackets are thin enough that scaling 1024 -> 16 destroys them. The
scan lines and drop shadow are skipped below 128px and the crosshair below
32px, for the same reason.

If a stale icon persists in the Dock or Finder, it is the LaunchServices icon
cache, not the build -- `build.sh` already re-registers the app, but the Dock
can need a restart.
