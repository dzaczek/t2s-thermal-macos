"""T2S+ capture + control shim for irpythermal.Camera, for macOS.

irpythermal.Camera expects a cv2.VideoCapture-like object: it reads raw
frames via .read() and sends commands (raw mode switch, shutter/NUC,
emissivity, ...) via .set(cv2.CAP_PROP_ZOOM, value), which on Linux/V4L2
reaches the camera's UVC "Zoom, Absolute" control.

On this Mac, neither of the two obvious ways to do that in Python work:
- cv2.VideoCapture(index) crashes opening this device (confirmed to match
  an unresolved upstream bug, opencv/opencv#22912 -- AVFoundation backend
  raises an uncaught exception for this camera's descriptor).
- pyusb/libusb can enumerate the device but cannot claim its interface to
  send the control transfer (errno 13, a known libusb-on-macOS/UVC limit).

So this shim gets frames via ffmpeg's avfoundation input (confirmed to open
this device fine) and sends the Zoom control via the vendored uvc-util
(github.com/jtfrey/uvc-util, MIT, pure IOKit), which is not subject to the
libusb restriction. Verified end to end against the real camera: after
sending the raw-mode command through this path, the captured pixel values
land exactly in the range (and match the min/max) the camera's own metadata
reports.
"""

import re
import struct
import subprocess
import sys
from pathlib import Path

import cv2
import numpy as np

VENDOR_ID = 0x1514
PRODUCT_ID = 0x0001
DEVICE_NAME = "T2S+"
SENSOR_WIDTH = 256
FRAME_HEIGHT = 196  # 192 image rows + 4 metadata rows
FPS = 25

UVC_UTIL = Path(__file__).with_name("vendor") / "uvc-util" / "build" / "uvc-util"


def find_avfoundation_index(name=DEVICE_NAME, timeout=10):
    """AVFoundation device indices are not stable across runs/reboots --
    re-discover the camera's current index by name every time we open it.

    The match is anchored to end-of-line on purpose: once the virtual camera
    extension is installed there is also a device called "T2S+ Thermal
    Camera", and an unanchored match happily picks that instead, then fails
    with "Failed to read a complete frame" because its frames are 858x576
    rather than the sensor's 256x196."""
    proc = subprocess.run(
        ["ffmpeg", "-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", ""],
        capture_output=True, text=True, timeout=timeout,
    )
    for line in proc.stderr.splitlines():
        m = re.search(r"\[(\d+)\]\s+" + re.escape(name) + r"\s*$", line)
        if m:
            return int(m.group(1))
    return None


def read_exact(stream, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = stream.read(n - len(buf))
        if not chunk:
            return None
        buf.extend(chunk)
    return bytes(buf)


class FFmpegUVCCapture:
    """Just enough of cv2.VideoCapture's interface for irpythermal.Camera."""

    def __init__(self, device_index=None):
        if device_index is None:
            device_index = find_avfoundation_index()
        if device_index is None:
            raise RuntimeError(f"Could not find a '{DEVICE_NAME}' camera via ffmpeg avfoundation")

        self.frame_bytes = SENSOR_WIDTH * FRAME_HEIGHT * 2
        cmd = [
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            "-f", "avfoundation",
            "-pixel_format", "yuyv422",
            "-video_size", f"{SENSOR_WIDTH}x{FRAME_HEIGHT}",
            "-framerate", str(FPS),
            "-i", str(device_index),
            "-f", "rawvideo", "-pix_fmt", "yuyv422", "-",
        ]
        self._proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=self.frame_bytes * 4)

    def isOpened(self):
        return self._proc.poll() is None

    def get(self, prop_id):
        if prop_id == cv2.CAP_PROP_FRAME_WIDTH:
            return SENSOR_WIDTH
        if prop_id == cv2.CAP_PROP_FRAME_HEIGHT:
            return FRAME_HEIGHT
        if prop_id == cv2.CAP_PROP_FPS:
            return FPS
        return 0

    def set(self, prop_id, value):
        if prop_id == cv2.CAP_PROP_CONVERT_RGB:
            return True  # ffmpeg always delivers raw yuyv422 bytes already
        if prop_id == cv2.CAP_PROP_ZOOM:
            return self._send_zoom(int(value))
        return False

    def _send_zoom(self, value):
        try:
            result = subprocess.run(
                [str(UVC_UTIL), "-V", f"0x{VENDOR_ID:04x}:0x{PRODUCT_ID:04x}",
                 "-s", f"zoom-abs={value & 0xFFFF}"],
                capture_output=True, text=True, timeout=5,
            )
        except (OSError, subprocess.TimeoutExpired) as e:
            print(f"uvc-util control send failed: {e}", file=sys.stderr)
            return False
        if result.returncode != 0:
            print(f"uvc-util error: {result.stderr.strip()}", file=sys.stderr)
            return False
        return True

    def read(self):
        if not self.isOpened():
            return False, None
        raw = read_exact(self._proc.stdout, self.frame_bytes)
        if raw is None:
            return False, None
        frame = np.frombuffer(raw, dtype=np.uint8).reshape(FRAME_HEIGHT, SENSOR_WIDTH, 2).copy()
        return True, frame

    def release(self):
        self._proc.terminate()
        try:
            self._proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self._proc.kill()
