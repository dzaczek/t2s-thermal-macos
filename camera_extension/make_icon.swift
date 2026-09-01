// Generates the app icon and writes AppIcon.appiconset.
//
// The icon is drawn rather than shipped as a binary blob so it stays editable
// and so the heat bloom uses the same Ironbow stops as Palettes.swift -- the
// icon and the live image are then literally the same colour ramp.
//
//   swift make_icon.swift T2SCameraApp/Assets.xcassets/AppIcon.appiconset
//
// Each size is rendered natively instead of downscaling one big canvas: the
// viewfinder brackets are thin, and scaling 1024 -> 16 turns them to mush.

import AppKit
import Foundation

// Ironbow stops from Palettes.swift, cold -> hot.
let ironbow: [(CGFloat, (CGFloat, CGFloat, CGFloat))] = [
    (0.00, (0, 0, 0)), (0.10, (20, 0, 45)), (0.25, (85, 0, 90)),
    (0.40, (160, 10, 70)), (0.55, (215, 55, 15)), (0.70, (245, 120, 0)),
    (0.85, (250, 200, 30)), (1.00, (255, 255, 200)),
]

func rgb(_ c: (CGFloat, CGFloat, CGFloat), _ a: CGFloat = 1) -> CGColor {
    CGColor(red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: a)
}

/// Rounded-rect path in the macOS icon idiom: continuous-looking corners on an
/// inset square rather than the full canvas.
func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon(size S: CGFloat, into ctx: CGContext) {
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let inset = S * 0.085
    let body = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let corner = S * 0.20

    // Drop shadow, skipped at small sizes where it just muddies the edge.
    if S >= 128 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012),
                      blur: S * 0.03,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
        ctx.addPath(squircle(body, radius: corner))
        ctx.setFillColor(rgb((10, 6, 20)))
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(squircle(body, radius: corner))
    ctx.clip()

    // Cold background: near-black with a faint purple lift, so the bloom has
    // somewhere to fall off to.
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [rgb((28, 18, 52)), rgb((8, 5, 16))] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg,
                           start: CGPoint(x: 0, y: body.maxY),
                           end: CGPoint(x: 0, y: body.minY),
                           options: [])

    // The heat signature: Ironbow run outward from hot centre to cold edge.
    let centre = CGPoint(x: body.midX, y: body.midY + S * 0.015)
    var colors: [CGColor] = []
    var locs: [CGFloat] = []
    for (pos, c) in ironbow.reversed() {
        let t = 1 - pos                       // centre = hottest stop
        colors.append(rgb(c, pos < 0.10 ? 0 : 1))
        locs.append(t)
    }
    let bloom = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: colors as CFArray, locations: locs)!
    ctx.drawRadialGradient(bloom,
                           startCenter: centre, startRadius: 0,
                           endCenter: centre, endRadius: S * 0.335,
                           options: [])

    // Scan lines, a thermal-display cue. Only where there are enough pixels to
    // render them as lines instead of grey haze.
    if S >= 128 {
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.10))
        let step = max(2, S / 64)
        var y = body.minY
        while y < body.maxY {
            ctx.fill(CGRect(x: body.minX, y: y, width: body.width, height: step / 2))
            y += step
        }
    }

    // Glass highlight along the top edge.
    ctx.saveGState()
    let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.18),
                                    CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(gloss,
                           start: CGPoint(x: 0, y: body.maxY),
                           end: CGPoint(x: 0, y: body.midY + body.height * 0.08),
                           options: [])
    ctx.restoreGState()

    // Viewfinder brackets + centre reticle: the part that says "camera" rather
    // than "abstract gradient".
    let pad = body.width * 0.155
    let f = body.insetBy(dx: pad, dy: pad)
    let arm = f.width * 0.26
    let lw = max(1, S * 0.026)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.setLineWidth(lw)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    for (cx, cy, dx, dy) in [(f.minX, f.maxY, 1.0, -1.0), (f.maxX, f.maxY, -1.0, -1.0),
                             (f.minX, f.minY, 1.0, 1.0), (f.maxX, f.minY, -1.0, 1.0)] {
        ctx.move(to: CGPoint(x: cx + CGFloat(dx) * arm, y: cy))
        ctx.addLine(to: CGPoint(x: cx, y: cy))
        ctx.addLine(to: CGPoint(x: cx, y: cy + CGFloat(dy) * arm))
        ctx.strokePath()
    }

    // Crosshair. Dropped below 32px, where it collides with the brackets.
    if S >= 32 {
        let r = S * 0.045
        ctx.setLineWidth(max(1, S * 0.018))
        ctx.setLineCap(.butt)
        ctx.move(to: CGPoint(x: centre.x - r, y: centre.y))
        ctx.addLine(to: CGPoint(x: centre.x + r, y: centre.y))
        ctx.move(to: CGPoint(x: centre.x, y: centre.y - r))
        ctx.addLine(to: CGPoint(x: centre.x, y: centre.y + r))
        ctx.strokePath()
    }

    ctx.restoreGState()
}

func render(size: Int) -> Data {
    let S = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    drawIcon(size: S, into: ctx)
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

// (point size, scale) -> the set Xcode expects for a macOS app icon.
let entries: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                             (256, 1), (256, 2), (512, 1), (512, 2)]

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
                 ? CommandLine.arguments[1] : "AppIcon.appiconset")
try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var images: [[String: String]] = []
for (pt, scale) in entries {
    let px = pt * scale
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    try! render(size: px).write(to: outDir.appendingPathComponent(name))
    images.append(["size": "\(pt)x\(pt)", "idiom": "mac",
                   "filename": name, "scale": "\(scale)x"])
    print("wrote \(name) (\(px)px)")
}

let contents: [String: Any] = ["images": images,
                               "info": ["version": 1, "author": "xcode"]]
let json = try! JSONSerialization.data(withJSONObject: contents,
                                       options: [.prettyPrinted, .sortedKeys])
try! json.write(to: outDir.appendingPathComponent("Contents.json"))
print("wrote Contents.json")
