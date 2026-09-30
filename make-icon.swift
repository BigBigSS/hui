import AppKit
import CoreGraphics

// The personal site currently uses favicon.png: a continuous blue hui monogram.
// One vector geometry generates the SVG masters, native template and every icon size.
let outputURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.png").standardizedFileURL
let root = outputURL.deletingLastPathComponent()
let branding = root.appendingPathComponent("Branding", isDirectory: true)
try FileManager.default.createDirectory(at: branding, withIntermediateDirectories: true)

enum Segment {
    case move(CGFloat, CGFloat), line(CGFloat, CGFloat)
    case curve(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
    case close
}
let letterH: [Segment] = [
    .move(122.5, 75.5), .line(168, 75.5), .line(168, 189.5),
    .curve(182, 176.5, 200, 169.5, 219.5, 169.5),
    .curve(270, 169.5, 305.5, 209.5, 305.5, 264.5), .line(305.5, 353),
    .curve(278, 352.5, 262.5, 335.5, 262.5, 309.5), .line(262.5, 268),
    .curve(262.5, 236, 244, 215.5, 217, 215.5),
    .curve(188.5, 215.5, 168, 237.5, 168, 268),
    .line(168, 378), .line(122.5, 378), .close
]
let letterU: [Segment] = [
    .move(194.25, 267.75), .line(238.25, 267.75), .line(238.25, 309.5),
    .curve(238.25, 350, 260.5, 377.5, 297.5, 377.5),
    .curve(335, 377.5, 358, 350, 358, 309.5), .line(358, 189),
    .line(403.5, 189), .line(403.5, 309.5),
    .curve(403.5, 376.75, 364, 423.25, 298, 423.25),
    .curve(232, 423.25, 194.25, 376.75, 194.25, 309.5), .close
]
let dot = CGRect(x: 353.5, y: 112, width: 54, height: 54)
let blue = CGColor(srgbRed: 0.0235, green: 0.2667, blue: 0.7059, alpha: 1)

func path(_ segments: [Segment]) -> CGPath {
    let result = CGMutablePath()
    for segment in segments {
        switch segment {
        case let .move(x, y): result.move(to: CGPoint(x: x, y: y))
        case let .line(x, y): result.addLine(to: CGPoint(x: x, y: y))
        case let .curve(x1, y1, x2, y2, x, y):
            result.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
        case .close: result.closeSubpath()
        }
    }
    return result
}
func svgPath(_ segments: [Segment]) -> String {
    segments.map { segment in
        switch segment {
        case let .move(x, y): return "M\(x) \(y)"
        case let .line(x, y): return "L\(x) \(y)"
        case let .curve(x1, y1, x2, y2, x, y): return "C\(x1) \(y1) \(x2) \(y2) \(x) \(y)"
        case .close: return "Z"
        }
    }.joined(separator: " ")
}
let markSVG = """
<g fill="#0644B4">
  <path d="\(svgPath(letterH))"/>
  <path d="\(svgPath(letterU))"/>
  <circle cx="380.5" cy="139" r="27"/>
</g>
"""
try """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" fill="none">
  <title>hui — personal monogram</title>
  \(markSVG)
</svg>
""".write(to: branding.appendingPathComponent("HuiMark.svg"), atomically: true, encoding: .utf8)
try """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" fill="none">
  <title>hui — application icon</title>
  <defs>
    <linearGradient id="tile" x1="160" y1="102" x2="850" y2="922" gradientUnits="userSpaceOnUse">
      <stop stop-color="#FFFFFF"/><stop offset="1" stop-color="#F3F5FA"/>
    </linearGradient>
    <filter id="shadow" x="0" y="0" width="1024" height="1024" filterUnits="userSpaceOnUse">
      <feDropShadow dx="0" dy="12" stdDeviation="10" flood-color="#16274A" flood-opacity="0.16"/>
    </filter>
  </defs>
  <rect x="102" y="102" width="820" height="820" rx="184" fill="url(#tile)" filter="url(#shadow)"/>
  <rect x="103" y="103" width="818" height="818" rx="183" stroke="#FFFFFF" stroke-width="2"/>
  <g transform="translate(102 102) scale(1.6015625)">\(markSVG)</g>
</svg>
""".write(to: branding.appendingPathComponent("HuiAppIcon.svg"), atomically: true, encoding: .utf8)
// Alpha drives the native template tint. The PDF stays sharp at every display scale.
try """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 18 18" fill="none">
  <title>hui — menu bar template</title>
  <g transform="translate(2.04 0.5) scale(0.04888568799) translate(-122.5 -75.5)" fill="#000000">
    <path d="\(svgPath(letterH))"/>
    <path d="\(svgPath(letterU))"/>
    <circle cx="380.5" cy="139" r="27"/>
  </g>
</svg>
""".write(to: branding.appendingPathComponent("HuiMenuBarTemplate.svg"), atomically: true, encoding: .utf8)

func drawMark(_ context: CGContext, color: CGColor) {
    context.setFillColor(color)
    context.addPath(path(letterH)); context.fillPath()
    context.addPath(path(letterU)); context.fillPath()
    context.fillEllipse(in: dot)
}
func drawIcon(_ context: CGContext) {
    let tile = CGPath(roundedRect: CGRect(x: 102, y: 102, width: 820, height: 820), cornerWidth: 184, cornerHeight: 184, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 20, color: CGColor(srgbRed: 0.086, green: 0.153, blue: 0.290, alpha: 0.16))
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.addPath(tile); context.fillPath()
    context.restoreGState()
    context.saveGState(); context.addPath(tile); context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [CGColor(gray: 1, alpha: 1), CGColor(srgbRed: 0.953, green: 0.961, blue: 0.980, alpha: 1)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 160, y: 102), end: CGPoint(x: 850, y: 922), options: [])
    context.restoreGState()
    context.addPath(CGPath(roundedRect: CGRect(x: 103, y: 103, width: 818, height: 818), cornerWidth: 183, cornerHeight: 183, transform: nil))
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.95)); context.setLineWidth(2); context.strokePath()
    context.saveGState(); context.translateBy(x: 102, y: 102); context.scaleBy(x: 820 / 512, y: 820 / 512)
    drawMark(context, color: blue); context.restoreGState()
}
func png(edge: Int, canvas: CGFloat = 1024, draw: (CGContext) -> Void) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: edge, pixelsHigh: edge,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: edge * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.translateBy(x: 0, y: CGFloat(edge)); context.scaleBy(x: CGFloat(edge) / canvas, y: -CGFloat(edge) / canvas)
    context.setAllowsAntialiasing(true); context.setShouldAntialias(true)
    draw(context)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
try png(edge: 1024, draw: drawIcon).write(to: outputURL, options: .atomic)
let iconset = branding.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for edge in [16, 32, 128, 256, 512] {
    try png(edge: edge, draw: drawIcon).write(to: iconset.appendingPathComponent("icon_\(edge)x\(edge).png"), options: .atomic)
    try png(edge: edge * 2, draw: drawIcon).write(to: iconset.appendingPathComponent("icon_\(edge)x\(edge)@2x.png"), options: .atomic)
}
let pdfURL = branding.appendingPathComponent("HuiMenuBarTemplate.pdf")
var mediaBox = CGRect(x: 0, y: 0, width: 18, height: 18)
let pdf = CGContext(pdfURL as CFURL, mediaBox: &mediaBox, nil)!
pdf.beginPDFPage(nil)
pdf.translateBy(x: 0, y: 18); pdf.scaleBy(x: 1, y: -1)
pdf.translateBy(x: 2.04, y: 0.5); pdf.scaleBy(x: 17 / 347.75, y: 17 / 347.75)
pdf.translateBy(x: -122.5, y: -75.5)
drawMark(pdf, color: CGColor(gray: 0, alpha: 1))
pdf.endPDFPage(); pdf.closePDF()
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try iconutil.run(); iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { throw NSError(domain: "hui.icon", code: Int(iconutil.terminationStatus)) }
print("Generated AppIcon.png, AppIcon.icns and Branding vector assets.")
