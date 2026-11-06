import CoreGraphics
import Foundation
import SwiftUI
import UIKit

// MARK: - Geometry

/// One octilinear polyline of the icon network: colour hex and the polyline's
/// vertices in the 390 × 300 design space of the mockups.
struct NetworkArtLine: Equatable {
    let colorHex: String
    let points: [CGPoint]
}

/// One terminal ring: an outline circle at a line's end, stroked in the
/// line's own colour.
struct NetworkArtTerminal: Equatable {
    let point: CGPoint
    /// Index into `NetworkArtGeometry.lineHexes`.
    let lineIndex: Int
}

/// Pure geometry and animation math of the network motif (spec S11): the
/// schematic network on the app icon, read off the `V5Empty` and `V5Loading`
/// mockups (`viewBox 0 0 390 300`). Every function here is side-effect free
/// so `NetworkArtTests` can cover it without drawing anything.
enum NetworkArtGeometry {
    /// Design space of the mockups (`viewBox 0 0 390 300`).
    static let designWidth: CGFloat = 390
    static let designHeight: CGFloat = 300

    /// The five lines in mockup draw order: red, blue, green, purple, orange.
    ///
    /// Colours come from the app's brand palette where the icon has the
    /// matching metro line (L1 red, L2 purple, L3 green, L4 orange). The blue
    /// keeps the mockups' brighter azure because L5's navy (`005A97`)
    /// disappears against the dark loading and empty-state backgrounds.
    static let lineHexes: [String] = [
        MetroLine.line(forCode: "1")?.colorHex ?? "E3242B",
        "1E6FD9",
        MetroLine.line(forCode: "3")?.colorHex ?? "1EB53A",
        MetroLine.line(forCode: "2")?.colorHex ?? "93248F",
        MetroLine.line(forCode: "4")?.colorHex ?? "F7A30E",
    ]

    /// The five octilinear paths, in the same draw order as `lineHexes`.
    static let lineVertices: [[CGPoint]] = [
        [CGPoint(x: 20, y: 260), CGPoint(x: 290, y: -10)],
        [CGPoint(x: 20, y: 150), CGPoint(x: 60, y: 150), CGPoint(x: 210, y: 0)],
        [CGPoint(x: 70, y: 20), CGPoint(x: 70, y: 100), CGPoint(x: 150, y: 180), CGPoint(x: 270, y: 180)],
        [CGPoint(x: 150, y: 10), CGPoint(x: 150, y: 40), CGPoint(x: 370, y: 260)],
        [CGPoint(x: 300, y: 40), CGPoint(x: 330, y: 70), CGPoint(x: 330, y: 170), CGPoint(x: 360, y: 200), CGPoint(x: 375, y: 200)],
    ]

    /// The lines, pairing each path with its colour.
    static var lines: [NetworkArtLine] {
        zip(lineHexes, lineVertices).map(NetworkArtLine.init(colorHex:points:))
    }

    /// Small white station dots along the lines.
    static let stations: [CGPoint] = [
        CGPoint(x: 70, y: 55),
        CGPoint(x: 205, y: 180),
        CGPoint(x: 60, y: 220),
        CGPoint(x: 250, y: 30),
        CGPoint(x: 260, y: 150),
        CGPoint(x: 330, y: 220),
        CGPoint(x: 330, y: 120),
    ]

    /// White interchange rings with a dark stroke, where two lines cross.
    static let interchangeRings: [CGPoint] = [
        CGPoint(x: 160, y: 50),
        CGPoint(x: 195, y: 85),
        CGPoint(x: 90, y: 120),
        CGPoint(x: 125, y: 155),
    ]

    /// Outline rings at the line ends.
    static let terminals: [NetworkArtTerminal] = [
        NetworkArtTerminal(point: CGPoint(x: 70, y: 20), lineIndex: 2),
        NetworkArtTerminal(point: CGPoint(x: 270, y: 180), lineIndex: 2),
        NetworkArtTerminal(point: CGPoint(x: 20, y: 150), lineIndex: 1),
        NetworkArtTerminal(point: CGPoint(x: 20, y: 260), lineIndex: 0),
        NetworkArtTerminal(point: CGPoint(x: 150, y: 10), lineIndex: 3),
        NetworkArtTerminal(point: CGPoint(x: 370, y: 260), lineIndex: 3),
        NetworkArtTerminal(point: CGPoint(x: 300, y: 40), lineIndex: 4),
        NetworkArtTerminal(point: CGPoint(x: 375, y: 200), lineIndex: 4),
    ]

    // MARK: Metrics (design units, scaled with the art)

    static let lineWidth: CGFloat = 13
    static let stationRadius: CGFloat = 4
    static let interchangeRadius: CGFloat = 10
    static let ringStrokeWidth: CGFloat = 4.5
    static let terminalRadius: CGFloat = 8

    // MARK: Scaling

    /// The art keeps its 390 × 300 aspect and fits the proposed size.
    static func scale(in size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 0 }
        return min(size.width / designWidth, size.height / designHeight)
    }

    /// Top-left corner of the fitted art so it is centered in the size.
    static func fittedOrigin(in size: CGSize) -> CGPoint {
        let fitted = scale(in: size)
        return CGPoint(
            x: (size.width - designWidth * fitted) / 2,
            y: (size.height - designHeight * fitted) / 2
        )
    }

    /// The prefix of `points` that covers `fraction` of the polyline's total
    /// length, interpolating inside the segment that `fraction` lands on.
    ///
    /// A cut exactly on a vertex returns the prefix up to and including that
    /// vertex once, never twice. `fraction` ≤ 0 collapses to the first point
    /// (a path with no segments, which strokes to nothing); `fraction` ≥ 1
    /// returns every point.
    static func partial(_ points: [CGPoint], fraction: Double) -> [CGPoint] {
        guard let first = points.first else { return [] }
        guard points.count > 1, fraction > 0 else { return [first] }
        if fraction >= 1 { return points }

        var total: Double = 0
        var lengths: [Double] = []
        for i in 1..<points.count {
            let length = hypot(
                Double(points[i].x - points[i - 1].x),
                Double(points[i].y - points[i - 1].y)
            )
            lengths.append(length)
            total += length
        }
        guard total > 0 else { return [first] }

        let target = total * min(fraction, 1)
        var result: [CGPoint] = [first]
        var walked: Double = 0
        for i in 1..<points.count {
            let length = lengths[i - 1]
            if walked + length >= target - 1e-9 {
                let remaining = target - walked
                if length > 1e-9 && remaining > 1e-9 {
                    let t = remaining / length
                    result.append(CGPoint(
                        x: points[i - 1].x + (points[i].x - points[i - 1].x) * CGFloat(t),
                        y: points[i - 1].y + (points[i].y - points[i - 1].y) * CGFloat(t)
                    ))
                }
                return result
            }
            result.append(points[i])
            walked += length
        }
        // Floating-point padding: the fraction is clamped below 1, so this
        // only guards against rounding at the last vertex.
        return points
    }

    // MARK: Drawing loop (the V5Loading cycle)

    /// One full cycle of the loading animation, in seconds.
    static let drawingPeriod: TimeInterval = 3.2
    /// Stagger between consecutive lines, in seconds.
    static let lineDelayStep: TimeInterval = 0.12
    /// Fraction of the cycle a line takes to draw in.
    static let drawWindow: Double = 0.45
    /// Fraction of the cycle where everything holds before fading out.
    static let holdStart: Double = 0.85
    /// First interchange ring appears this long after the cycle starts, in
    /// seconds.
    static let ringFirstDelay: TimeInterval = 0.5
    /// Stagger between consecutive rings, in seconds.
    static let ringDelayStep: TimeInterval = 0.08
    /// Fraction of the cycle a ring takes to pop in.
    static let popStart: Double = 0.42
    static let popEnd: Double = 0.55

    /// How much of a line is drawn and how visible it is at one loop phase.
    struct DrawTransition: Equatable {
        var trim: Double
        var alpha: Double
    }

    /// How a ring is scaled and how visible it is at one loop phase.
    struct RingTransition: Equatable {
        var scale: Double
        var alpha: Double
    }

    /// `interval` wrapped inside `[0, period)` and divided by the period, so
    /// it always answers "which fraction of the cycle are we in".
    static func loopPhase(of interval: TimeInterval, period: TimeInterval) -> Double {
        guard period > 0 else { return 0 }
        var wrapped = interval.truncatingRemainder(dividingBy: period)
        if wrapped < 0 { wrapped += period }
        return wrapped / period
    }

    /// Symmetric ease-in-out, matching the mockups' `cubic-bezier(.65,0,.35,1)`
    /// closely enough for a decorative loop.
    static func eased(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        if t < 0.5 { return 4 * t * t * t }
        if t > 0.5 { return 1 - pow(-2 * t + 2, 3) / 2 }
        return 0.5
    }

    /// Trim and alpha of line `index` at loop phase `phase`.
    ///
    /// A line hides until its staggered delay, draws in over `drawWindow`,
    /// holds at full, and fades out before the cycle restarts (so the restart
    /// never snaps).
    static func lineTransition(_ phase: Double, index: Int) -> DrawTransition {
        let delay = Double(index) * lineDelayStep / drawingPeriod
        let elapsed = phase - delay
        if elapsed <= 0 { return DrawTransition(trim: 0, alpha: 0) }
        if elapsed <= drawWindow {
            return DrawTransition(trim: eased(elapsed / drawWindow), alpha: 1)
        }
        if elapsed <= holdStart { return DrawTransition(trim: 1, alpha: 1) }
        let faded = min(max((elapsed - holdStart) / (1 - holdStart), 0), 1)
        return DrawTransition(trim: 1, alpha: 1 - faded)
    }

    /// Scale and alpha of interchange ring `index` at loop phase `phase`.
    ///
    /// A ring pops in (from 30 % scale) after its delay, holds, and fades out
    /// with the lines before the cycle restarts.
    static func ringTransition(_ phase: Double, index: Int) -> RingTransition {
        let delay = (ringFirstDelay + Double(index) * ringDelayStep) / drawingPeriod
        let elapsed = phase - delay
        if elapsed <= popStart { return RingTransition(scale: 0.3, alpha: 0) }
        if elapsed <= popEnd {
            let pop = eased((elapsed - popStart) / (popEnd - popStart))
            return RingTransition(scale: 0.3 + 0.7 * pop, alpha: pop)
        }
        if elapsed <= holdStart { return RingTransition(scale: 1, alpha: 1) }
        let faded = min(max((elapsed - holdStart) / (1 - holdStart), 0), 1)
        return RingTransition(scale: 1, alpha: 1 - faded)
    }
}

// MARK: - View

/// The app icon's schematic network as a SwiftUI view (spec S11).
///
/// Three styles:
/// - `.header`: header art behind the Parades screens, fading to transparent
///   towards the bottom; the overall opacity is the caller's choice.
/// - `.illustration`: full-colour static art, for the Avisos empty state.
/// - `.drawing`: the loading animation — lines draw in staggered, the
///   interchange rings pop in after, looping; static when Reduce Motion is
///   on.
struct NetworkArt: View {
    enum Style {
        case header
        case illustration
        case drawing
    }

    private let style: Style
    /// Overall opacity multiplier; only the `.header` style reads it.
    private let opacity: Double
    /// VoiceOver text when the caller wants the art announced; without one
    /// the art is decorative and hidden from accessibility.
    private let accessibilityLabel: Text?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ style: Style, opacity: Double = 1, accessibilityLabel: Text? = nil) {
        self.style = style
        self.opacity = opacity
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        Group {
            if style == .header {
                base.mask {
                    LinearGradient(
                        stops: [
                            .init(color: .white, location: 0),
                            .init(color: .white.opacity(0.6), location: 0.45),
                            .init(color: .clear, location: 0.8),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            } else {
                base
            }
        }
        .opacity(style == .header ? opacity : 1)
        .modifier(DecorativeAccessibility(label: accessibilityLabel))
    }

    /// The drawing itself: animated while the loading loop runs, fully drawn
    /// in the static styles and under Reduce Motion.
    @ViewBuilder
    private var base: some View {
        if style == .drawing && !reduceMotion {
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    let phase = NetworkArtGeometry.loopPhase(
                        of: timeline.date.timeIntervalSinceReferenceDate,
                        period: NetworkArtGeometry.drawingPeriod
                    )
                    render(into: &context, size: size, phase: phase)
                }
            }
        } else {
            Canvas { context, size in
                render(into: &context, size: size, phase: nil)
            }
        }
    }

    /// The mockups stroke the rings with the background colour so the rings
    /// read as punched through the canvas; `systemBackground` keeps that on
    /// both light and dark appearances.
    private static let ringStroke = Color(uiColor: .systemBackground)

    private func render(into context: inout GraphicsContext, size: CGSize, phase: Double?) {
        let artScale = NetworkArtGeometry.scale(in: size)
        guard artScale > 0 else { return }
        let origin = NetworkArtGeometry.fittedOrigin(in: size)
        func at(_ point: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + point.x * artScale, y: origin.y + point.y * artScale)
        }

        // The lines, in draw order.
        for (index, line) in NetworkArtGeometry.lines.enumerated() {
            let transition = phase.map { NetworkArtGeometry.lineTransition($0, index: index) }
                ?? NetworkArtGeometry.DrawTransition(trim: 1, alpha: 1)
            guard transition.alpha > 0, transition.trim > 0 else { continue }
            let vertices = transition.trim >= 1
                ? line.points
                : NetworkArtGeometry.partial(line.points, fraction: transition.trim)
            guard let first = vertices.first else { continue }
            var path = Path()
            path.move(to: at(first))
            for vertex in vertices.dropFirst() {
                path.addLine(to: at(vertex))
            }
            context.opacity = transition.alpha
            context.stroke(
                path,
                with: .color(Color(hex: line.colorHex)),
                style: StrokeStyle(
                    lineWidth: NetworkArtGeometry.lineWidth * artScale,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
        context.opacity = 1

        let isAnimating = phase != nil

        // Station dots and terminal rings belong to the static styles only:
        // the V5Loading mockup draws lines and interchange rings only.
        if !isAnimating {
            for station in NetworkArtGeometry.stations {
                let center = at(station)
                let radius = NetworkArtGeometry.stationRadius * artScale
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )),
                    with: .color(.white)
                )
            }
            for terminal in NetworkArtGeometry.terminals {
                let center = at(terminal.point)
                let radius = NetworkArtGeometry.terminalRadius * artScale
                var ring = Path()
                ring.addEllipse(in: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ))
                context.fill(ring, with: .color(.white))
                context.stroke(
                    ring,
                    with: .color(Color(hex: NetworkArtGeometry.lineHexes[terminal.lineIndex])),
                    style: StrokeStyle(
                        lineWidth: NetworkArtGeometry.ringStrokeWidth * artScale,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }

        // Interchange rings, popping in during the loading loop.
        for (index, ringPoint) in NetworkArtGeometry.interchangeRings.enumerated() {
            let transition = phase.map { NetworkArtGeometry.ringTransition($0, index: index) }
                ?? NetworkArtGeometry.RingTransition(scale: 1, alpha: 1)
            guard transition.alpha > 0, transition.scale > 0 else { continue }
            let center = at(ringPoint)
            let radius = NetworkArtGeometry.interchangeRadius * artScale * transition.scale
            var ring = Path()
            ring.addEllipse(in: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            context.opacity = transition.alpha
            context.fill(ring, with: .color(.white))
            context.stroke(
                ring,
                with: .color(Self.ringStroke),
                style: StrokeStyle(
                    lineWidth: NetworkArtGeometry.ringStrokeWidth * artScale,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
        context.opacity = 1
    }
}

/// `.accessibilityHidden(true)` unless the caller labels the art.
private struct DecorativeAccessibility: ViewModifier {
    let label: Text?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let label {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        } else {
            content
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Header placement helper

extension View {
    /// Header art for the Parades screens (spec S11): the network motif drawn
    /// behind the top of the view, fading out before the content starts. The
    /// mockups (`V5Parades`, `V5Metro`) use 0.45 opacity over the metro
    /// screens and 0.55 over Tot. The parent wires it in after the Parades
    /// screens land (task T6); placement stays trivial until then.
    func networkHeaderBackground(
        opacity: Double = 0.5,
        height: CGFloat = NetworkArtGeometry.designHeight
    ) -> some View {
        background(alignment: .top) {
            NetworkArt(.header, opacity: opacity)
                .frame(height: height)
                .frame(maxWidth: .infinity)
        }
    }
}
