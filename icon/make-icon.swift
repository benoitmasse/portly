// Draws the Portly app icon and writes icon/AppIcon.png (1024 px) and icon/AppIcon.icns.
// Run from the repo root:  swift icon/make-icon.swift
import SwiftUI
import AppKit

let ink = Color(red: 0.086, green: 0.086, blue: 0.094)
let rowGray = Color(white: 0.9)
let mint = Color(red: 0.881, green: 1, blue: 0.92)

// Values below come from the "Portly icon" frame in Figma (file BENDEN, page Portly).
// Gradient start/end points are converted from Figma's gradient matrices.

/// The server rack: three rows, rounded on the outside, with small gaps between them.
struct Rack: View {
    let width: CGFloat = 600
    let rowHeight: CGFloat = 184
    let gap: CGFloat = 14
    let outer: CGFloat = 64
    let inner: CGFloat = 14

    func row(top: CGFloat, bottom: CGFloat, fill: LinearGradient) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                           bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous)
        return shape
            .fill(fill)
            .overlay(shape.strokeBorder(.white, lineWidth: 3))
            .frame(width: width, height: rowHeight)
    }

    var body: some View {
        VStack(spacing: gap) {
            row(top: outer, bottom: inner,
                fill: LinearGradient(stops: [.init(color: .white, location: 0.317), .init(color: rowGray, location: 1)],
                                     startPoint: UnitPoint(x: 0.4874, y: 0.0034), endPoint: UnitPoint(x: 0.5283, y: 1.6158)))
                .overlay(HappyFace())
            row(top: inner, bottom: inner,
                fill: LinearGradient(stops: [.init(color: rowGray, location: 0), .init(color: .white, location: 0.683)],
                                     startPoint: UnitPoint(x: 0.5099, y: 1.2753), endPoint: UnitPoint(x: 0.4899, y: -0.2894)))
                .overlay(WinkFace())
            row(top: inner, bottom: outer,
                fill: LinearGradient(stops: [.init(color: rowGray, location: 0), .init(color: mint, location: 1)],
                                     startPoint: UnitPoint(x: 0.4235, y: 0.233), endPoint: UnitPoint(x: 0.7583, y: 1.4016)))
                .overlay(Led().offset(x: 232, y: 22))
        }
        .compositingGroup()  // one shadow for the whole rack, not one per eye
        .shadow(color: .black.opacity(0.45), radius: 22, y: 14)
    }
}

struct Eye: View {
    /// Where the small shine sits, from the centre of the eye.
    var shine = CGSize(width: -12.5, height: -15.5)
    var body: some View {
        Circle().fill(ink).frame(width: 66, height: 66)
            .overlay(Circle().fill(.white.opacity(0.9)).frame(width: 9, height: 9).offset(shine))
    }
}

struct Smile: View {
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 0))
            p.addQuadCurve(to: CGPoint(x: 64, y: 0), control: CGPoint(x: 32, y: 44))
        }
        .stroke(ink, style: StrokeStyle(lineWidth: 14, lineCap: .round))
        .frame(width: 64, height: 26)
    }
}

struct HappyFace: View {
    var body: some View {
        ZStack {
            Eye().offset(x: -150, y: -6)
            Eye().offset(x: 150, y: -6)
            Smile().offset(y: 18)
        }
    }
}

struct WinkFace: View {
    var body: some View {
        ZStack {
            Eye(shine: CGSize(width: -13.5, height: -11.5)).offset(x: -150, y: -14)
            Capsule().fill(ink).frame(width: 80, height: 14).offset(x: 150, y: -14)
            Smile().offset(y: 40)
        }
    }
}

struct Led: View {
    var body: some View {
        Circle()
            .fill(RadialGradient(stops: [.init(color: Color(red: 0.19, green: 0.947, blue: 0.436), location: 0.644),
                                         .init(color: Color(red: 0.14, green: 0.65, blue: 0.35), location: 1)],
                                 center: .center, startRadius: 0, endRadius: 27.6))
            .frame(width: 46, height: 46)
            .shadow(color: Color(red: 0.2, green: 0.85, blue: 0.45).opacity(0.7), radius: 12)
    }
}

/// macOS 26 icon grid: an 824 pt continuous rounded square centred on a 1024 canvas.
struct AppIcon: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 185, style: .continuous)
        ZStack {
            shape
                // Lighter toward the lower right, darker at the edges.
                .fill(RadialGradient(colors: [Color(white: 0.25), Color(white: 0.07)],
                                     center: UnitPoint(x: 0.7906, y: 0.7778), startRadius: 0, endRadius: 490.8))
                .overlay(
                    // Soft light from the top, like the system icons.
                    shape.fill(RadialGradient(colors: [.white.opacity(0.14), .clear],
                                              center: UnitPoint(x: 0.5, y: 0), startRadius: 0, endRadius: 520))
                )
                .frame(width: 824, height: 824)
            Rack().offset(y: 4)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor func render() throws {
    let dir = URL(fileURLWithPath: "icon")
    let renderer = ImageRenderer(content: AppIcon())
    renderer.scale = 1
    guard let cg = renderer.cgImage else { fatalError("render failed") }
    let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
    try png.write(to: dir.appendingPathComponent("AppIcon.png"))
}

try MainActor.assumeIsolated { try render() }

// Build the .icns from the 1024 px master.
let iconset = "icon/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
func run(_ path: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
}
for size in [16, 32, 128, 256, 512] {
    run("/usr/bin/sips", ["-z", "\(size)", "\(size)", "icon/AppIcon.png", "--out", "\(iconset)/icon_\(size)x\(size).png"])
    run("/usr/bin/sips", ["-z", "\(size * 2)", "\(size * 2)", "icon/AppIcon.png", "--out", "\(iconset)/icon_\(size)x\(size)@2x.png"])
}
run("/usr/bin/iconutil", ["-c", "icns", iconset, "-o", "icon/AppIcon.icns"])
try? FileManager.default.removeItem(atPath: iconset)
print("Wrote icon/AppIcon.png and icon/AppIcon.icns")
