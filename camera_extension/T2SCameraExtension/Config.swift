import Foundation
import CoreMedia

let kFrameRate: Int32 = 25
let cameraName = "T2S+ Thermal Camera"
let fixedCamWidth: Int32 = 1716
let fixedCamHeight: Int32 = 1152

let appGroupID = AppIdentity.appGroupID

/// Written by thermal_view.py's --virtual-cam mode: raw 32BGRA bytes,
/// exactly fixedCamWidth*fixedCamHeight*4, via write-to-temp-then-rename so
/// this is always read as a complete frame, never a torn write.
///
/// Lives in the App Group container because camera extensions must be
/// sandboxed (confirmed: the working camera extensions on this machine all
/// carry app-sandbox + application-groups, and without them macOS rejected
/// this one with "extension category returned error"). A sandboxed process
/// can't read arbitrary paths, but the shared group container is reachable
/// from both here and the unsandboxed Python writer.
let sharedFrameURL: URL? = {
    FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
        .appendingPathComponent("frame.raw")
}()
