import AppKit
import SwiftUI

/// The Orbito mark: a glowing core circled by a tilted orbit and a satellite,
/// on a deep indigo tile. Drawn with shapes so it stays crisp at any size.
struct OrbitoMark: View {
    var size: CGFloat = 40

    private static let tilt = Angle.degrees(-28)
    private static let tile = LinearGradient(
        colors: [Color(red: 0.10, green: 0.11, blue: 0.29), Color(red: 0.24, green: 0.17, blue: 0.53)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    private static let ring = LinearGradient(colors: [Theme.cyan, Theme.blue, Theme.purple, Theme.pink],
                                             startPoint: .leading, endPoint: .trailing)

    var body: some View {
        let ringWidth = size * 0.78, ringHeight = size * 0.30, stroke = size * 0.045

        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(Self.tile)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                        .stroke(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.02)],
                                               startPoint: .top, endPoint: .bottom),
                                lineWidth: max(0.5, size * 0.012))
                )

            // Full orbit behind the core; the front half is redrawn on top below.
            Ellipse()
                .stroke(Self.ring, lineWidth: stroke)
                .frame(width: ringWidth, height: ringHeight)
                .rotationEffect(Self.tilt)

            Circle()
                .fill(RadialGradient(
                    colors: [Color(red: 0.75, green: 0.97, blue: 1.0), Theme.cyan, Theme.blue, Theme.purple],
                    center: UnitPoint(x: 0.34, y: 0.30), startRadius: 0, endRadius: size * 0.24))
                .frame(width: size * 0.36, height: size * 0.36)
                .shadow(color: Theme.cyan.opacity(0.55), radius: size * 0.08)

            // Front half and satellite pass in front of the core.
            ZStack {
                Ellipse()
                    .trim(from: 0, to: 0.5)
                    .stroke(Self.ring, lineWidth: stroke)
                    .frame(width: ringWidth, height: ringHeight)
                Circle()
                    .fill(LinearGradient(colors: [.white, Theme.pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: size * 0.10, height: size * 0.10)
                    .shadow(color: Theme.pink.opacity(0.8), radius: size * 0.04)
                    .offset(x: ringWidth / 2 * cos(.pi * 0.2), y: ringHeight / 2 * sin(.pi * 0.2))
            }
            .rotationEffect(Self.tilt)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Logo tile plus wordmark, used in the window header.
struct OrbitoLockup: View {
    var body: some View {
        HStack(spacing: 11) {
            OrbitoMark(size: 38)
                .shadow(color: Theme.purple.opacity(0.28), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 0) {
                Text(AppInfo.name)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.ink)
                Text("AI Assistant")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(Theme.secondaryInk)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(AppInfo.name) AI Assistant")
    }
}

/// App icon artwork on the standard macOS icon grid (824 pt tile on a 1024 pt canvas).
enum OrbitoIcon {
    @MainActor
    static func image(pixels: CGFloat) -> NSImage? {
        let canvas = pixels
        let view = OrbitoMark(size: canvas * 824 / 1024)
            .shadow(color: .black.opacity(0.22), radius: canvas * 0.02, y: canvas * 0.012)
            .frame(width: canvas, height: canvas)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.nsImage
    }

    /// Writes an .iconset folder (for `iconutil -c icns`). Used by scripts/package.sh.
    @MainActor
    static func exportIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                guard let image = image(pixels: CGFloat(points * scale)),
                      let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try png.write(to: directory.appendingPathComponent(name))
            }
        }
    }
}
