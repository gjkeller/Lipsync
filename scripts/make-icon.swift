// Renders Resources/AppIcon.icns: a waveform that fades from Spotify green to Apple Music red.
// Run with: swift scripts/make-icon.swift
import AppKit

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Big Sur grid: an 824pt rounded square centered on a 1024pt canvas.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.225
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor(calibratedWhite: 0.07, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor(calibratedWhite: 0.16, alpha: 1).cgColor, NSColor(calibratedWhite: 0.05, alpha: 1).cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])

    // Waveform bars.
    let heights: [CGFloat] = [0.22, 0.42, 0.66, 0.9, 0.62, 0.8, 0.5, 0.3, 0.18]
    let barWidth = body.width * 0.058
    let gap = body.width * 0.034
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = body.midX - total / 2
    let bars = CGMutablePath()
    for h in heights {
        let height = body.height * 0.62 * h
        let rect = CGRect(x: x, y: body.midY - height / 2, width: barWidth, height: height)
        bars.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        x += barWidth + gap
    }
    ctx.addPath(bars)
    ctx.clip()
    // Through white rather than straight across, which would muddy the middle bars.
    let colors = [
        NSColor(calibratedRed: 0.11, green: 0.78, blue: 0.36, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.94, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.99, green: 0.2, blue: 0.36, alpha: 1).cgColor,
    ]
    let wave = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0.08, 0.5, 0.92])!
    ctx.drawLinearGradient(wave, start: CGPoint(x: body.minX + total * 0.1, y: body.midY), end: CGPoint(x: body.maxX - total * 0.1, y: body.midY), options: [])
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let output = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
