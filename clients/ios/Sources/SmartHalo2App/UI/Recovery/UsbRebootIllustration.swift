import SwiftUI

/// Recovery step 2: a micro-USB cable plugs into the bottom of the Halo and comes out again, on an
/// 8 s loop. Left, the Halo side-on, the plug going up into the port on its bottom face; right, the
/// Halo from above. While the cable is in, the ring runs the firmware's charge animation
/// (`battery_AnimationsLibrary`, AnimationsLibrary.c): a 500 ms fill from 6 o'clock clockwise, red to
/// green over the first 60 % of the lap, a 500 ms retract to the battery level (60 % here), then a
/// pulse along the lit arc at 50 ms per LED. The OLED shows the battery icon filling up.
///
/// The same drawing and timings as `docs/img/usb-reboot.svg` (built by `docs/img/usb-reboot.mjs`):
/// its 340 × 200 box, scaled to fit. Reduce Motion shows one still frame, plugged in and charging.
struct UsbRebootIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            Canvas { gc, size in
                let frame = reduceMotion ? Frame.still : Frame(at: context.date.timeIntervalSinceReferenceDate)
                Self.draw(frame, in: &gc, size: size)
            }
        }
        .clipped()
    }
}

// MARK: - Timeline

/// The loop, in seconds.
private enum Loop {
    static let length = 8.0
    static let inStart = 0.5, click = 1.45, unplug = 5.9, outEnd = 6.8
    static let fillStart = 1.5, fillEnd = 2.0, retractEnd = 2.5
    static let pulses = [2.9, 4.3]
    /// LEDs lit at 60 % (the firmware leaves 23 × 40 / 100 ≈ 9 off).
    static let litCount = 15
    /// How far the plug is pulled out, in plug units.
    static let pullDistance = 46.0
    static let insert = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.45, y: 0), endControlPoint: UnitPoint(x: 0.2, y: 1))
    static let pull = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.5, y: 0), endControlPoint: UnitPoint(x: 0.6, y: 1))
}

/// Piecewise-linear through `stops` (time, value); flat before the first and after the last.
private func ramp(_ x: Double, _ stops: [(Double, Double)]) -> Double {
    guard let first = stops.first, let last = stops.last else { return 0 }
    if x <= first.0 { return first.1 }
    if x >= last.0 { return last.1 }
    for (a, b) in zip(stops, stops.dropFirst()) where x < b.0 {
        return a.1 + (b.1 - a.1) * (x - a.0) / (b.0 - a.0)
    }
    return last.1
}

extension UsbRebootIllustration {
    /// Everything that moves, at one instant.
    fileprivate struct Frame {
        /// 0 plugged in … 1 pulled out.
        var plugOut: Double
        /// Per LED in fill order (0 = 6 o'clock, clockwise): the charge colour's opacity.
        var lit: [Double]
        /// Per LED in fill order: the pulse's white on top.
        var pulse: [Double]
        var oled: Double
        /// The OLED battery bar, 0…1.
        var bar: Double
        /// Light leaking out of the glass in the side view.
        var glow: Double
        /// Progress of the ring that pops out of the port as the plug clicks in, if it's showing.
        var click: Double?

        static let still = Frame(plugOut: 0, lit: (0..<24).map { $0 < Loop.litCount ? 1.0 : 0.0 },
                                 pulse: Array(repeating: 0, count: 24), oled: 1, bar: 0.6, glow: 0.55, click: nil)
    }
}

extension UsbRebootIllustration.Frame {
    init(at time: TimeInterval) {
        let t = time.truncatingRemainder(dividingBy: Loop.length)
        let fadeOut = t < Loop.unplug ? 1 : max(0, 1 - (t - Loop.unplug) / 0.15)

        let plugOut: Double
        switch t {
        case ..<Loop.inStart: plugOut = 1
        case ..<Loop.click: plugOut = 1 - Loop.insert.value(at: (t - Loop.inStart) / (Loop.click - Loop.inStart))
        case ..<Loop.unplug: plugOut = 0
        case ..<Loop.outEnd: plugOut = Loop.pull.value(at: (t - Loop.unplug) / (Loop.outEnd - Loop.unplug))
        default: plugOut = 1
        }

        // Fill: one LED after another over 500 ms. Retract: the ones above the battery level go out
        // again, from the far end back, over the next 500 ms.
        let lit = (0..<24).map { j -> Double in
            guard t >= Loop.fillStart + Double(j) / 24 * 0.5 else { return 0 }
            if j >= Loop.litCount {
                let off = Loop.fillEnd + Double(23 - j) / Double(24 - Loop.litCount) * 0.5
                return t < off ? 1 : 0
            }
            return fadeOut
        }
        // The pulse: one LED every 50 ms, with a dimmer LED either side.
        let pulse = (0..<24).map { j -> Double in
            guard j < Loop.litCount else { return 0 }
            return Loop.pulses.map { start in
                ramp(t - (start + Double(j) * 0.05), [(-0.1, 0), (-0.05, 0.3), (0, 0.8), (0.05, 0.3), (0.1, 0)])
            }.max() ?? 0
        }
        // The OLED's bar steps up 20 % every 0.45 s and starts over, like the firmware's chargingProgress.
        let bar = t < Loop.click ? 0 : Double(Int((min(t, Loop.unplug) - Loop.click) / 0.45) % 5 + 1) * 0.2
        var glowStops: [(Double, Double)] = [(Loop.fillStart, 0), (Loop.fillStart + 0.35, 0.9), (Loop.retractEnd, 0.55)]
        for start in Loop.pulses {
            glowStops += [(start, 0.55), (start + 0.35, 0.9), (start + 0.8, 0.55)]
        }
        glowStops += [(Loop.unplug, 0.55), (Loop.unplug + 0.15, 0)]
        let oledStops: [(Double, Double)] = [(Loop.click, 0), (Loop.click + 0.05, 1), (Loop.unplug, 1), (Loop.unplug + 0.15, 0)]
        let click: Double? = t >= Loop.click && t < Loop.click + 0.45 ? (t - Loop.click) / 0.45 : nil

        self.init(plugOut: plugOut, lit: lit, pulse: pulse, oled: ramp(t, oledStops),
                  bar: bar, glow: ramp(t, glowStops), click: click)
    }
}

// MARK: - Drawing

extension UsbRebootIllustration {
    // The device's materials (the UI's colours are on `Theme`).
    private static let shellColor = Color(hex: 0x22272F)
    private static let edgeColor = Color(hex: 0x363D48)
    private static let glassColor = Color(hex: 0x0C0E12)
    private static let seamColor = Color(hex: 0x2B313A)
    private static let holeColor = Color(hex: 0x040506)

    /// `hsl(h, 92 %, 56 %)`, the SVG's charge colours, in SwiftUI's HSB.
    private static func chargeHue(_ h: Double) -> Color {
        Color(hue: h / 360, saturation: 0.839, brightness: 0.965)
    }

    /// The firmware's charge colour for LED `j` in fill order: red to green over the first 60 % of the lap.
    private static func chargeColor(_ j: Int) -> Color {
        let f = (Double(j) + 0.5) / 24
        return chargeHue(f < 0.6 ? 120 * f / 0.6 : 120)
    }

    private static func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
    }

    private static func line(_ a: CGPoint, _ b: CGPoint) -> Path {
        Path { p in
            p.move(to: a)
            p.addLine(to: b)
        }
    }

    fileprivate static func draw(_ f: Frame, in gc: inout GraphicsContext, size: CGSize) {
        // The SVG's 340 × 200 box, scaled to fit and centred; `u` is view points per box unit.
        let u = min(size.width / 340, size.height / 200)
        let box = CGAffineTransform(translationX: (size.width - 340 * u) / 2, y: (size.height - 200 * u) / 2)
            .scaledBy(x: u, y: u)

        drawSideView(f, in: &gc, box: box, u: u)
        gc.stroke(line(CGPoint(x: 181, y: 40), CGPoint(x: 181, y: 160)).applying(box), with: .color(Theme.stroke),
                  style: StrokeStyle(lineWidth: 1.2 * u, lineCap: .round, dash: [2 * u, 5 * u]))
        drawTopView(f, in: &gc, at: box.translatedBy(x: 252, y: 100).scaledBy(x: 0.744, y: 0.744), u: u)
    }

    private static func drawSideView(_ f: Frame, in gc: inout GraphicsContext, box: CGAffineTransform, u: CGFloat) {
        // Light leaking out of the glass while the ring charges.
        if f.glow > 0 {
            var light = gc
            light.opacity = f.glow
            light.addFilter(.blur(radius: 5 * u))
            let r = CGRect(x: 44, y: 70, width: 102, height: 9).applying(box)
            light.fill(Path(roundedRect: r, cornerRadius: 4.5 * u),
                       with: .linearGradient(Gradient(colors: [chargeHue(8), chargeHue(55), chargeHue(120)]),
                                             startPoint: CGPoint(x: r.minX, y: r.midY),
                                             endPoint: CGPoint(x: r.maxX, y: r.midY)))
        }

        // The plug goes behind the body, so its metal tip disappears into the port.
        let plug = box.translatedBy(x: 95, y: 106 + Loop.pullDistance * 0.9 * f.plugOut).scaledBy(x: 0.9, y: 0.9)
        drawPlug(in: &gc, at: plug, u: 0.9 * u)

        let shell = rounded(31, 82, 128, 24, 9).applying(box)
        gc.fill(shell, with: .color(shellColor))
        gc.stroke(shell, with: .color(edgeColor), lineWidth: 1.2 * u)
        gc.stroke(line(CGPoint(x: 36, y: 94.5), CGPoint(x: 154, y: 94.5)).applying(box), with: .color(seamColor), lineWidth: u)
        let glass = rounded(38, 77, 114, 7, 3.5).applying(box)
        gc.fill(glass, with: .color(glassColor))
        gc.stroke(glass, with: .color(edgeColor), lineWidth: u)
        gc.fill(rounded(85.5, 101.5, 19, 4.5, 1.2).applying(box), with: .color(holeColor))

        if let p = f.click {
            let s = 0.5 + 1.2 * p
            let ring = Path(ellipseIn: CGRect(x: 95 - 15 * s, y: 106 - 4.5 * s, width: 30 * s, height: 9 * s)).applying(box)
            gc.stroke(ring, with: .color(Theme.accent.opacity(1 - p)), lineWidth: 2 * s * u)
        }
    }

    /// The micro-USB plug, tip up. `m` maps the plug's units into the view; their origin is where
    /// the metal meets the plastic. `u` is view points per plug unit.
    private static func drawPlug(in gc: inout GraphicsContext, at m: CGAffineTransform, u: CGFloat) {
        gc.stroke(line(CGPoint(x: 0, y: 37), CGPoint(x: 0, y: 170)).applying(m), with: .color(Color(hex: 0x4C5563)),
                  style: StrokeStyle(lineWidth: 5.5 * u, lineCap: .round))
        var relief = Path()
        relief.addLines([CGPoint(x: -7, y: 27.5), CGPoint(x: 7, y: 27.5), CGPoint(x: 4.6, y: 37), CGPoint(x: -4.6, y: 37)])
        relief.closeSubpath()
        gc.fill(relief.applying(m), with: .color(Color(hex: 0x30363F)))

        let grip = rounded(-11, 0, 22, 28, 4.5).applying(m)
        gc.fill(grip, with: .color(Color(hex: 0x3A424D)))
        gc.stroke(grip, with: .color(Color(hex: 0x56606D)), lineWidth: u)
        gc.fill(rounded(-8.5, 1.6, 17, 1.2, 0.6).applying(m), with: .color(Color(hex: 0x4C5662)))
        var ridges = Path()
        for y: CGFloat in [17.5, 20.5, 23.5] {
            ridges.move(to: CGPoint(x: -6, y: y))
            ridges.addLine(to: CGPoint(x: 6, y: y))
        }
        gc.stroke(ridges.applying(m), with: .color(Color(hex: 0x2C323B)), style: StrokeStyle(lineWidth: 1.2 * u, lineCap: .round))

        gc.fill(rounded(-7.5, -11, 15, 11.5, 1.4).applying(m), with: .color(Color(hex: 0xC2CAD4)))
        gc.fill(rounded(-5.6, -9, 11.2, 3, 0.8).applying(m), with: .color(Color(hex: 0x8D97A4)))
        gc.fill(rounded(-4, -4.4, 2, 1.6, 0.4).applying(m), with: .color(Color(hex: 0x7A8491)))
        gc.fill(rounded(2, -4.4, 2, 1.6, 0.4).applying(m), with: .color(Color(hex: 0x7A8491)))
    }

    /// The Halo from above. `m` maps the face's units (radius 86, LEDs at radius 62, centred on 0,0)
    /// into the view; `u` is view points per box unit.
    private static func drawTopView(_ f: Frame, in gc: inout GraphicsContext, at m: CGAffineTransform, u: CGFloat) {
        let k = 0.744 * u   // view points per face unit
        let shell = Path(ellipseIn: CGRect(x: -86, y: -86, width: 172, height: 172)).applying(m)
        gc.fill(shell, with: .color(shellColor))
        gc.stroke(shell, with: .color(edgeColor), lineWidth: 1.2 * u)
        gc.fill(Path(ellipseIn: CGRect(x: -79, y: -79, width: 158, height: 158)).applying(m), with: .color(glassColor))

        // 24 LEDs of 15° from 12 o'clock clockwise; fill order j starts at 6 o'clock (LED 12).
        func led(_ j: Int) -> Path {
            let a = Double((j + 12) % 24) * 15
            return Path { p in
                p.addArc(center: .zero, radius: 62, startAngle: .degrees(a + 1.5 - 90),
                         endAngle: .degrees(a + 13.5 - 90), clockwise: false)
            }.applying(m)
        }
        let width = 11 * k
        for j in 0..<24 {
            gc.stroke(led(j), with: .color(Theme.text.opacity(0.09)), lineWidth: width)
        }
        var bloom = gc
        bloom.addFilter(.blur(radius: 2.4 * k))
        for j in 0..<24 where f.lit[j] > 0 {
            bloom.stroke(led(j), with: .color(chargeColor(j).opacity(f.lit[j])), lineWidth: width)
        }
        for j in 0..<24 where f.lit[j] > 0 {
            gc.stroke(led(j), with: .color(chargeColor(j).opacity(f.lit[j])), lineWidth: width)
            if f.pulse[j] > 0 {
                gc.stroke(led(j), with: .color(.white.opacity(f.pulse[j])), lineWidth: width)
            }
        }

        // The OLED, with the battery icon while charging.
        let screen = rounded(-19, -10.5, 38, 21, 3).applying(m)
        gc.fill(screen, with: .color(Color(hex: 0x050608)))
        gc.stroke(screen, with: .color(Color(hex: 0x262B33)), lineWidth: u)
        guard f.oled > 0 else { return }
        var icon = gc
        icon.opacity = f.oled
        icon.stroke(rounded(-9.5, -4.5, 17, 9, 1.6).applying(m), with: .color(Theme.text), lineWidth: 1.3 * u)
        icon.fill(rounded(7.8, -2, 2, 4, 0.6).applying(m), with: .color(Theme.text))
        if f.bar > 0 {
            icon.fill(rounded(-7.8, -2.8, 13.6 * f.bar, 5.6, 0.8).applying(m), with: .color(Theme.text))
        }
    }
}

#Preview("UsbRebootIllustration") {
    UsbRebootIllustration()
        .frame(height: 200)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding()
        .background(Theme.bg)
}
