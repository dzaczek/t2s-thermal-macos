import Cocoa

/// About panel contents.
///
/// Uses the standard macOS about panel rather than a hand-built window, so it
/// picks up the app icon and behaves like every other app's.
enum About {

    /// Change these two if the attribution should read differently; they are
    /// the only place the author appears.
    static let author = "Jacek"
    static let contact = "jacek@sysop.cat"

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// Bumped by build.sh on every build.
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    static var summary: String {
        "T2S+ Thermal Camera \(version) (build \(build))"
    }

    static func show() {
        let credits = NSMutableAttributedString()
        let bold = NSFont.boldSystemFont(ofSize: 11)

        func line(_ text: String, _ font: NSFont = NSFont.systemFont(ofSize: 11)) {
            credits.append(NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ]))
        }

        line("Viewer and virtual camera for the Xinfrared/Xtherm T2S+ "
             + "USB-C thermal camera.\n\n")
        line("Author\n", bold)
        line("\(author) — \(contact)\n\n")
        line("Camera\n", bold)
        line("T2S+ V2, 256×192 sensor, 25 fps, USB 0x1514:0x0001\n\n")
        line("Credits\n", bold)
        line("Radiometry ported from IR-Py-Thermal (GPLv3) by diminDDL, which "
             + "reverse-engineered this camera family's temperature model. "
             + "USB control informed by uvc-util (MIT).\n\n")
        line("Licence\n", bold)
        line("GNU GPL v3. This program comes without warranty.\n")
        for (title, url) in [
            ("Source code and build instructions", URL(string:
                "https://github.com/dzaczek/t2s-thermal-macos/tree/v\(version)")),
            ("GNU GPL v3", Bundle.main.url(forResource: "LICENSE", withExtension: nil)),
            ("Third-party notices", Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"))
        ] {
            if let url {
                credits.append(NSAttributedString(string: title + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .link: url
                ]))
            }
        }

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "T2S+ Thermal Camera",
            .applicationVersion: version,
            .version: build,
            .credits: credits,
        ])
    }
}
