import Foundation
import Security

/// Identifiers that depend on who built the app.
///
/// An App Group name must start with the signing team's identifier, so a
/// hard-coded one means nobody but the original author can build the project.
/// Reading it back from this build's own code signature keeps the source free
/// of anyone's team ID; the entitlements files get the same value from Xcode's
/// `$(TeamIdentifierPrefix)`.
///
/// Compiled into both the app and the extension -- they must agree on the
/// group name or the frame handoff silently stops working.
enum AppIdentity {

    /// Team identifier of the running bundle, or "" if it cannot be read
    /// (an unsigned build, which cannot use App Groups anyway).
    static let teamID: String = {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode)
                == errSecSuccess,
              let staticCode else { return "" }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode,
                                            SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        else { return "" }
        return team
    }()

    /// Bundle identifier the project is built under, without the team prefix.
    static let baseIdentifier = "cat.sysop.t2scamera"

    /// Shared container the app writes frames into and the extension reads.
    static let appGroupID = "\(teamID).\(baseIdentifier)"
}
