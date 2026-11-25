#!/usr/bin/env swift
import AppKit
import SwiftUI
import Foundation

extension Color {
    static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1.0) -> Color {
        Color(.sRGB, red: r / 255.0, green: g / 255.0, blue: b / 255.0, opacity: a)
    }
}

struct SquircleShell<Content: View>: View {
    let top: Color
    let bottom: Color
    let rimLight: Color
    let rimDark: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 185.4, style: .continuous)
        ZStack {
            shape
                .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.24), radius: 14, x: 0, y: 10)

            content()
                .clipShape(shape)

            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [rimLight, rimDark],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 2.5
                )
        }
        .frame(width: 824, height: 824)
        .frame(width: 1024, height: 1024)
    }
}

// 01 · 母带走带 · Braun Offset Reel (不对称单主轮走带 + 右侧磁头桥与朱砂录音灯，彻底消除双轮人脸错觉)
struct IconVariant1: View {
    var body: some View {
        let ink = Color.rgb(28, 27, 25)
        let paperMid = Color.rgb(241, 236, 226)
        let vermilion = Color.rgb(199, 68, 45)

        SquircleShell(
            top: .rgb(248, 244, 236),
            bottom: .rgb(233, 227, 214),
            rimLight: .white.opacity(0.70),
            rimDark: .black.opacity(0.08)
        ) {
            Canvas { ctx, size in
                // Left-anchored large precision Nagra/Braun supply reel (cropped slightly toward left for editorial tension)
                let reelC = CGPoint(x: 318, y: 432)
                let outerR: CGFloat = 212
                let hubR: CGFloat = 82
                let pinR: CGFloat = 24

                // Outer reel disc
                let outerRect = CGRect(x: reelC.x - outerR, y: reelC.y - outerR, width: outerR * 2, height: outerR * 2)
                ctx.fill(Path(ellipseIn: outerRect), with: .color(ink))

                // Concentric tape-pack rings
                for rFactor in [0.78, 0.58] {
                    let gr = outerR * rFactor
                    let gRect = CGRect(x: reelC.x - gr, y: reelC.y - gr, width: gr * 2, height: gr * 2)
                    ctx.stroke(Path(ellipseIn: gRect), with: .color(paperMid.opacity(0.20)), lineWidth: 5)
                }

                // 3 precision machined Braun flange cutouts
                for deg in [-30.0, 90.0, 210.0] {
                    let a1 = Angle.degrees(deg - 24)
                    let a2 = Angle.degrees(deg + 24)
                    var slot = Path()
                    slot.addArc(center: reelC, radius: outerR * 0.76, startAngle: a1, endAngle: a2, clockwise: false)
                    slot.addArc(center: reelC, radius: hubR + 18, startAngle: a2, endAngle: a1, clockwise: true)
                    slot.closeSubpath()
                    ctx.fill(slot, with: .color(paperMid.opacity(0.92)))
                }

                // Center aluminum hub + spindle
                let hubRect = CGRect(x: reelC.x - hubR, y: reelC.y - hubR, width: hubR * 2, height: hubR * 2)
                ctx.fill(Path(ellipseIn: hubRect), with: .color(paperMid))
                let pinRect = CGRect(x: reelC.x - pinR, y: reelC.y - pinR, width: pinR * 2, height: pinR * 2)
                ctx.fill(Path(ellipseIn: pinRect), with: .color(ink))

                // Taut continuous magnetic tape: outer top edge (y=220) mathematically co-tangent to 0.00px with reel top (432 - 212 = 220)!
                let tapeStroke: CGFloat = 20
                let rollerC = CGPoint(x: 658, y: 276)
                let rollerR: CGFloat = 38
                let pathR = rollerR + tapeStroke / 2 - 2 // 46 -> tape centerline top y = 276 - 46 = 230 -> outer top edge = 220.0!
                let tapeTopY = rollerC.y - pathR // 230.0 == reelC.y (432) - outerR (212) + tapeStroke/2 (10)!

                var tapePath = Path()
                tapePath.move(to: CGPoint(x: reelC.x, y: tapeTopY))
                tapePath.addLine(to: CGPoint(x: rollerC.x, y: tapeTopY))
                tapePath.addArc(
                    center: rollerC,
                    radius: pathR,
                    startAngle: .degrees(-90),
                    endAngle: .degrees(0),
                    clockwise: false
                )
                tapePath.addLine(to: CGPoint(x: rollerC.x + pathR, y: 624))
                ctx.stroke(tapePath, with: .color(ink), style: StrokeStyle(lineWidth: tapeStroke, lineCap: .round, lineJoin: .round))

                // Precision guide roller nested cleanly inside the 90-degree tape bend
                ctx.fill(Path(ellipseIn: CGRect(x: rollerC.x - rollerR + 7, y: rollerC.y - rollerR + 7, width: (rollerR - 7) * 2, height: (rollerR - 7) * 2)), with: .color(ink))
                ctx.fill(Path(ellipseIn: CGRect(x: rollerC.x - 12, y: rollerC.y - 12, width: 24, height: 24)), with: .color(paperMid))

                // Bold Cinnabar / Vermilion Tally Dot with generous negative-space clearance from both reel & vertical tape
                let tallyC = CGPoint(x: 612, y: 564)
                let tallyR: CGFloat = 50
                ctx.fill(Path(ellipseIn: CGRect(x: tallyC.x - tallyR, y: tallyC.y - tallyR, width: tallyR * 2, height: tallyR * 2)), with: .color(vermilion))
            }
        }
    }
}

// 02 · 暗房取景 · Obsidian Cinema Gate (35mm 电影长镜头取景框 + 徕卡红核，纯粹沉稳专业暗色)
struct IconVariant2: View {
    var body: some View {
        let ivory = Color.rgb(240, 236, 227)
        let vermilion = Color.rgb(217, 74, 50)

        SquircleShell(
            top: .rgb(33, 33, 36),
            bottom: .rgb(19, 19, 21),
            rimLight: .white.opacity(0.14),
            rimDark: .black.opacity(0.45)
        ) {
            Canvas { ctx, _ in
                // Left & Right precision cinema gate brackets [   ●   ]
                let leftX: CGFloat = 194
                let rightX: CGFloat = 630
                let topY: CGFloat = 236
                let botY: CGFloat = 588
                let arm: CGFloat = 78
                let strokeW: CGFloat = 26

                var leftBracket = Path()
                leftBracket.move(to: CGPoint(x: leftX + arm, y: topY))
                leftBracket.addLine(to: CGPoint(x: leftX, y: topY))
                leftBracket.addLine(to: CGPoint(x: leftX, y: botY))
                leftBracket.addLine(to: CGPoint(x: leftX + arm, y: botY))

                var rightBracket = Path()
                rightBracket.move(to: CGPoint(x: rightX - arm, y: topY))
                rightBracket.addLine(to: CGPoint(x: rightX, y: topY))
                rightBracket.addLine(to: CGPoint(x: rightX, y: botY))
                rightBracket.addLine(to: CGPoint(x: rightX - arm, y: botY))

                let style = StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round)
                ctx.stroke(leftBracket, with: .color(ivory), style: style)
                ctx.stroke(rightBracket, with: .color(ivory), style: style)

                // Luminous Cinnabar core centered in optical gate
                let c = CGPoint(x: 412, y: 412)
                let r: CGFloat = 86
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(vermilion))

                // Subtle bottom timecode vernier scale (5 precision ticks)
                for i in -2...2 {
                    let tx = 412 + CGFloat(i) * 44
                    let tickH: CGFloat = (i == 0) ? 20 : 11
                    var tick = Path()
                    tick.move(to: CGPoint(x: tx, y: 656 - tickH / 2))
                    tick.addLine(to: CGPoint(x: tx, y: 656 + tickH / 2))
                    ctx.stroke(tick, with: .color(ivory.opacity(i == 0 ? 0.55 : 0.25)), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                }
            }
        }
    }
}

// 03 · 一镜声轨 · Editorial Optical Track (Mono-color 纸墨双色版画: 胶片光学声轨律动 + 朱砂印记)
struct IconVariant3: View {
    var body: some View {
        let charcoal = Color.rgb(27, 26, 24)
        let terracotta = Color.rgb(198, 68, 44)

        SquircleShell(
            top: .rgb(250, 248, 242),
            bottom: .rgb(239, 234, 223),
            rimLight: .white.opacity(0.75),
            rimDark: .black.opacity(0.08)
        ) {
            Canvas { ctx, _ in
                // Top and bottom editorial registration hairlines
                for yPos in [262.0, 562.0] {
                    var rule = Path()
                    rule.move(to: CGPoint(x: 156, y: yPos))
                    rule.addLine(to: CGPoint(x: 668, y: yPos))
                    ctx.stroke(rule, with: .color(charcoal.opacity(0.18)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                }

                // 5 architectural vertical sound-on-film bars (clean geometric rhythm, ZERO worm curves!)
                let heights: [CGFloat] = [96, 172, 124, 196, 112]
                let startX: CGFloat = 178
                let spacing: CGFloat = 62
                for (i, h) in heights.enumerated() {
                    let x = startX + CGFloat(i) * spacing
                    let barRect = CGRect(x: x - 15, y: 412 - h / 2, width: 30, height: h)
                    ctx.fill(Path(roundedRect: barRect, cornerRadius: 15), with: .color(charcoal))
                }

                // Bold Cinnabar / Terracotta recording seal on the right
                let c = CGPoint(x: 590, y: 412)
                let r: CGFloat = 82
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(terracotta))
            }
        }
    }
}

// 04 · 定音刻盘 · Field Recorder Platter (TP-7 精密仪器拉丝暖铝底 + 炭墨母带转盘 + 朱砂偏心刻点)
struct IconVariant4: View {
    var body: some View {
        let platter = Color.rgb(25, 25, 27)
        let vermilion = Color.rgb(204, 68, 44)
        let cap = Color.rgb(236, 232, 224)

        SquircleShell(
            top: .rgb(236, 233, 226),
            bottom: .rgb(214, 209, 199),
            rimLight: .white.opacity(0.75),
            rimDark: .black.opacity(0.10)
        ) {
            Canvas { ctx, _ in
                let c = CGPoint(x: 412, y: 412)

                // Outer recessed machined chamfer ring
                let bezelR: CGFloat = 290
                ctx.stroke(
                    Path(ellipseIn: CGRect(x: c.x - bezelR, y: c.y - bezelR, width: bezelR * 2, height: bezelR * 2)),
                    with: .color(.black.opacity(0.12)),
                    lineWidth: 5
                )

                // Main anodized black platter
                let discR: CGFloat = 264
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - discR, y: c.y - discR, width: discR * 2, height: discR * 2)), with: .color(platter))

                // Subtle inner precision groove
                let innerR: CGFloat = 178
                ctx.stroke(
                    Path(ellipseIn: CGRect(x: c.x - innerR, y: c.y - innerR, width: innerR * 2, height: innerR * 2)),
                    with: .color(.white.opacity(0.12)),
                    lineWidth: 3.5
                )

                // Radial index arm pointing to upper-right (-42 deg in top-left origin coords)
                let rad = CGFloat(-42.0 * .pi / 180.0)
                var arm = Path()
                arm.move(to: CGPoint(x: c.x + 52 * cos(rad), y: c.y + 52 * sin(rad)))
                arm.addLine(to: CGPoint(x: c.x + 150 * cos(rad), y: c.y + 150 * sin(rad)))
                ctx.stroke(arm, with: .color(cap.opacity(0.92)), style: StrokeStyle(lineWidth: 16, lineCap: .round))

                // Center spindle cap
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 26, y: c.y - 26, width: 52, height: 52)), with: .color(cap))

                // Cinnabar record tally dot on outer track
                let tallyC = CGPoint(x: c.x + 206 * cos(rad), y: c.y + 206 * sin(rad))
                ctx.fill(Path(ellipseIn: CGRect(x: tallyC.x - 28, y: tallyC.y - 28, width: 56, height: 56)), with: .color(vermilion))
            }
        }
    }
}

@MainActor
func renderSwiftUIIcon(_ variant: Int, pixelSize: Int) -> NSBitmapImageRep {
    let baseView: AnyView
    switch variant {
    case 1: baseView = AnyView(IconVariant1())
    case 2: baseView = AnyView(IconVariant2())
    case 3: baseView = AnyView(IconVariant3())
    default: baseView = AnyView(IconVariant4())
    }

    let renderer = ImageRenderer(content: baseView)
    renderer.scale = CGFloat(pixelSize) / 1024.0
    guard let cgImage = renderer.cgImage else {
        fatalError("Failed to render CGImage for variant \(variant)")
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: pixelSize, height: pixelSize)
    return rep
}

func savePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconRender", code: 1)
    }
    try data.write(to: url)
}

func resizeRep(_ src: NSBitmapImageRep, size: Int) -> NSBitmapImageRep {
    let dst = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    dst.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    let nsCtx = NSGraphicsContext(bitmapImageRep: dst)!
    NSGraphicsContext.current = nsCtx
    nsCtx.cgContext.interpolationQuality = .high
    let img = NSImage(size: src.size)
    img.addRepresentation(src)
    img.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    return dst
}

@MainActor
func buildSheet(designDir: URL, reps: [Int: NSBitmapImageRep]) throws {
    let w = 2240
    let h = 1180
    let sheet = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    sheet.size = NSSize(width: w, height: h)

    NSGraphicsContext.saveGraphicsState()
    let nsCtx = NSGraphicsContext(bitmapImageRep: sheet)!
    NSGraphicsContext.current = nsCtx
    let ctx = nsCtx.cgContext
    ctx.interpolationQuality = .high

    // Top half: Warm Paper Light Mode; Bottom half: Obsidian Dark Mode
    ctx.setFillColor(NSColor(srgbRed: 245/255, green: 242/255, blue: 235/255, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: h / 2, width: w, height: h / 2))
    ctx.setFillColor(NSColor(srgbRed: 22/255, green: 22/255, blue: 24/255, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 2))

    let titles = [
        1: "01 · 母带走带 (Braun Offset Reel)",
        2: "02 · 暗房取景 (Obsidian Gate)",
        3: "03 · 一镜声轨 (Editorial Track)",
        4: "04 · 定音刻盘 (Field Platter)"
    ]

    for idx in 1...4 {
        guard let rep = reps[idx] else { continue }
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)

        let colX = CGFloat(84 + (idx - 1) * 536)
        // Light mode: 340px + 72px (Dock) + 32px (Finder list)
        img.draw(in: NSRect(x: colX, y: CGFloat(h / 2) + 148, width: 340, height: 340))
        img.draw(in: NSRect(x: colX + 362, y: CGFloat(h / 2) + 286, width: 76, height: 76))
        img.draw(in: NSRect(x: colX + 382, y: CGFloat(h / 2) + 216, width: 36, height: 36))

        // Dark mode: 340px + 72px (Dock) + 32px (Finder list)
        img.draw(in: NSRect(x: colX, y: 120, width: 340, height: 340))
        img.draw(in: NSRect(x: colX + 362, y: 258, width: 76, height: 76))
        img.draw(in: NSRect(x: colX + 382, y: 188, width: 36, height: 36))

        let lightAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 21, weight: .semibold),
            .foregroundColor: NSColor(srgbRed: 30/255, green: 29/255, blue: 27/255, alpha: 1)
        ]
        let darkAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 21, weight: .medium),
            .foregroundColor: NSColor(srgbRed: 235/255, green: 231/255, blue: 223/255, alpha: 1)
        ]
        NSString(string: titles[idx]!).draw(in: NSRect(x: colX + 22, y: CGFloat(h / 2) + 72, width: 460, height: 36), withAttributes: lightAttrs)
        NSString(string: titles[idx]!).draw(in: NSRect(x: colX + 22, y: 44, width: 460, height: 36), withAttributes: darkAttrs)
    }

    NSGraphicsContext.restoreGraphicsState()
    try savePNG(sheet, to: designDir.appendingPathComponent("candidates-v2-sheet.png"))
}

@MainActor
func main() throws {
    let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let designDir = repoRoot.appendingPathComponent("design")
    let appIconSetDir = repoRoot.appendingPathComponent("QuickRecorder/Assets.xcassets/AppIcon.appiconset")
    try FileManager.default.createDirectory(at: designDir, withIntermediateDirectories: true)

    var installVariant: Int? = nil
    let args = CommandLine.arguments
    if let idx = args.firstIndex(of: "--install"), idx + 1 < args.count, let v = Int(args[idx + 1]), (1...4).contains(v) {
        installVariant = v
    }

    var master1024: [Int: NSBitmapImageRep] = [:]
    for v in 1...4 {
        let hiRes = renderSwiftUIIcon(v, pixelSize: 2048)
        let rep1024 = resizeRep(hiRes, size: 1024)
        master1024[v] = rep1024
        try savePNG(rep1024, to: designDir.appendingPathComponent("v2-option-\(v).png"))
    }

    try buildSheet(designDir: designDir, reps: master1024)

    guard let variant = installVariant else {
        print("Rendered 4 native SwiftUI icon candidates to design/. Pass --install <1..4> to update AppIcon.appiconset.")
        return
    }

    let chosenHiRes = renderSwiftUIIcon(variant, pixelSize: 2048)
    let iconTargets: [(String, Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024)
    ]

    for (filename, px) in iconTargets {
        let rep = resizeRep(chosenHiRes, size: px)
        try savePNG(rep, to: appIconSetDir.appendingPathComponent(filename))
    }
    print("Successfully rendered 4 native SwiftUI continuous-squircle variants and installed variant \(variant).")
}

try MainActor.assumeIsolated {
    try main()
}
