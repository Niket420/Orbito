import AppKit
import SwiftUI

/// The Orbito "O": a heavy ring circled by a tilted orbit and a satellite.
/// The orbit is a tapered stroke, thickest at the lower left and thinning to points
/// on either side of the satellite. Where it crosses the ring, thin gaps in the
/// `knockout` colour (the background behind the glyph) separate the two.
struct OrbitoGlyph: View {
    /// Outer diameter of the ring.
    var size: CGFloat
    var color: Color
    var knockout: Color

    var orbit = Orbit()

    /// Orbit geometry in units of `size`, relative to the ring's centre. Angles in degrees.
    struct Orbit {
        var semiMajor = 0.84
        var semiMinor = 0.30
        var tilt = -32.0
        var centreOffset = CGPoint(x: 0, y: 0.03)
        var gapCentre = -34.0      // where the satellite sits (upper right)
        var gapHalfWidth = 18.0
        var maxThickness = 0.105
    }

    var body: some View {
        let ringWidth = size * 0.2
        let canvas = CGSize(width: size * 1.9, height: size * 1.4)

        ZStack {
            Circle()
                .stroke(color, lineWidth: ringWidth)
                .frame(width: size - ringWidth, height: size - ringWidth)

            Canvas { context, area in
                let centre = CGPoint(x: area.width / 2, y: area.height / 2)
                let gap = max(1, size * 0.045)
                let samples = orbitSamples(centre: centre)

                // Knockout pass first, so the orbit cuts cleanly through the ring.
                for pass in 0..<2 {
                    for (a, b, width) in samples {
                        var segment = Path()
                        segment.move(to: a)
                        segment.addLine(to: b)
                        let w = pass == 0 ? width + gap * 2 : width
                        context.stroke(segment, with: .color(pass == 0 ? knockout : color),
                                       style: StrokeStyle(lineWidth: w, lineCap: .round))
                    }
                }

                // Satellite in the orbit's opening.
                let dot = point(at: rad(orbit.gapCentre), centre: centre, scale: 1.04)
                let r = size * 0.095
                context.fill(Path(ellipseIn: CGRect(x: dot.x - r - gap, y: dot.y - r - gap,
                                                    width: (r + gap) * 2, height: (r + gap) * 2)),
                             with: .color(knockout))
                context.fill(Path(ellipseIn: CGRect(x: dot.x - r, y: dot.y - r, width: r * 2, height: r * 2)),
                             with: .color(color))
            }
            .frame(width: canvas.width, height: canvas.height)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Line segments along the orbit with their stroke widths.
    private func orbitSamples(centre: CGPoint) -> [(CGPoint, CGPoint, CGFloat)] {
        let steps = 160
        let start = rad(orbit.gapCentre + orbit.gapHalfWidth)
        let sweep = 2 * Double.pi - 2 * rad(orbit.gapHalfWidth)
        return (0..<steps).map { i in
            let t0 = Double(i) / Double(steps), t1 = Double(i + 1) / Double(steps)
            let taper = pow(sin(Double.pi * (t0 + t1) / 2), 0.9)
            let width = size * orbit.maxThickness * max(0.08, taper)
            return (point(at: start + sweep * t0, centre: centre),
                    point(at: start + sweep * t1, centre: centre),
                    width)
        }
    }

    /// A point on the tilted orbit (angles in screen coordinates, y pointing down).
    private func point(at angle: Double, centre: CGPoint, scale: Double = 1) -> CGPoint {
        let x = orbit.semiMajor * cos(angle) * scale, y = orbit.semiMinor * sin(angle) * scale
        let tilt = rad(orbit.tilt)
        let rx = x * cos(tilt) - y * sin(tilt) + orbit.centreOffset.x
        let ry = x * sin(tilt) + y * cos(tilt) + orbit.centreOffset.y
        return CGPoint(x: centre.x + rx * size, y: centre.y + ry * size)
    }

    private func rad(_ degrees: Double) -> Double { degrees * .pi / 180 }
}

/// The full wordmark: the orbit "O" followed by "rbito".
struct OrbitoWordmark: View {
    /// Height of the "O" (roughly the ascender height of the letters).
    var height: CGFloat = 30
    var glyphColor: Color = Theme.accent
    var textColor: Color = Theme.ink
    var knockout: Color = Theme.background

    var body: some View {
        HStack(alignment: .bottom, spacing: height * 0.1) {
            OrbitoGlyph(size: height, color: glyphColor, knockout: knockout)
                .padding(.leading, height * 0.26)  // room for the orbit's left sweep
            Text("rbito")
                .font(.custom("AvenirNext-Bold", size: height * 1.24))
                .tracking(-height * 0.02)
                .foregroundStyle(textColor)
                .alignmentGuide(.bottom) { $0[.lastTextBaseline] }
        }
        .accessibilityElement()
        .accessibilityLabel(AppInfo.name)
    }
}

/// App-icon style mark: the orbit "O" on a tile in the theme's accent colour.
struct OrbitoMark: View {
    var size: CGFloat = 40
    /// Fixed theme (for icon export); nil follows the current theme.
    var theme: AppTheme? = nil

    var body: some View {
        let palette = (theme ?? ThemeStore.shared.theme).palette
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.235, style: .continuous)
                .fill(palette.accent)
            OrbitoGlyph(size: size * 0.44, color: palette.onAccent, knockout: palette.accent)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The header lockup.
struct OrbitoLockup: View {
    var body: some View {
        OrbitoWordmark(height: 30)
    }
}

/// App icon artwork on the standard macOS icon grid (824 pt tile on a 1024 pt canvas).
enum OrbitoIcon {
    @MainActor
    static func image(pixels: CGFloat, theme: AppTheme = ThemeStore.shared.theme) -> NSImage? {
        let view = OrbitoMark(size: pixels * 824 / 1024, theme: theme)
            .shadow(color: .black.opacity(0.22), radius: pixels * 0.02, y: pixels * 0.012)
            .frame(width: pixels, height: pixels)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.nsImage
    }

    /// Writes an .iconset folder (for `iconutil -c icns`). Used by scripts/package.sh.
    /// The bundled icon uses the brand's default orange theme.
    @MainActor
    static func exportIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                guard let image = image(pixels: CGFloat(points * scale), theme: .orange),
                      let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try png.write(to: directory.appendingPathComponent(name))
            }
        }
    }
}
