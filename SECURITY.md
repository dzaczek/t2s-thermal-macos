# Security policy

## Reporting a vulnerability

Please report privately, not in a public issue.

Use [**Report a vulnerability**](https://github.com/dzaczek/t2s-thermal-macos/security/advisories/new)
on the Security tab. That opens a private advisory only you and the maintainer
can read. If you would rather use email, write to `jacek@sysop.cat`.

Tell me what you did, what happened, and what you expected instead. A crash log
or a short recipe is worth more than a description. If you have a working proof
of concept, keep it in the private report.

This is a one-person project, not a company with a rota. Expect a first reply
within a week. If a fix is warranted it goes out as a new signed release, and
you get credit in the release notes unless you would rather not.

Please give me a chance to ship a fix before writing about it publicly. If you
hear nothing for three weeks, go ahead and publish — silence is not a reason to
sit on something.

## What is supported

Only the latest release, currently **1.3**. Older versions get nothing; there is
no branch to backport to. Fixes ship as a new release.

## What this software actually does

Worth knowing before you decide whether something is a bug or the design:

- It is **sandboxed** and built with the hardened runtime, signed with a
  Developer ID certificate and notarised by Apple.
- It **makes no network connections**. There is no network entitlement and no
  networking code anywhere in it. It sends no telemetry, checks for no updates
  and phones nobody. If you catch it opening a socket, that is a report I very
  much want.
- It holds entitlements for the **camera**, for **USB** (it writes control
  commands to the camera over IOKit) and for **writing to your Pictures
  folder**, where captures land in `~/Pictures/T2S+ Thermal`.
- It installs a **camera system extension**, which macOS will not load until you
  approve it by hand in System Settings.
- The app and that extension talk through **one file in a shared App Group
  container**: the app writes each rendered frame to `frame.raw`, atomically,
  and the extension reads it. Your calibration lives beside it in
  `shutter_offset.json`.

One consequence deserves saying out loud, because it is the feature working as
intended rather than a flaw: **once the virtual camera is activated and the app
is running, any application on your Mac that can open a camera can see the
thermal image.** That is how it shows up in Teams and Zoom. Quit the app, or
turn off *Publish to Virtual Camera*, and there is nothing to see — the
extension falls back to grey.

## In scope

Anything that lets code or a user reach further than the above allows:

- Escaping the sandbox, or the extension doing more than publish frames
- Reaching or tampering with another user's data through the App Group
  container or the capture files
- Getting the app to run code it did not ship, or to load an unsigned extension
- Memory corruption reachable from a camera frame, a crafted `frame.raw`, or a
  file the app reads
- Anything in the signing, notarisation or update path that would let someone
  hand a user a modified build that still looks legitimate

## Out of scope

- **Wrong temperatures.** Readings depend on emissivity, calibration and the
  camera's own hardware, and the high range is explicitly not trustworthy
  without a two-point calibration. That is a normal issue, not a vulnerability.
  Do not use this app where a wrong reading is dangerous; see the disclaimer
  below.
- Anything needing physical access to an unlocked Mac plus administrator rights
- The Python prototype in the repository root, which is a proof of concept kept
  for reference and is not part of the shipped app
- Findings against `vendor/uvc-util`, which belongs upstream
- Reports produced by running a scanner over the repository with nothing behind
  them

## No warranty

This is GPLv3 software written by one person for their own camera. It is not a
certified instrument and carries no warranty, express or implied. Do not rely on
it for electrical safety, medical decisions, fire assessment or anything else
where being wrong matters.
