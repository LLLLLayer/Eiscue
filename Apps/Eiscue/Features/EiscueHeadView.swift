import SwiftUI

enum EiscueHeadStyle: String, CaseIterable, Identifiable {
    case ice, ink, pixel
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ice: String(localized: "mascot.style.ice", table: "Mascot")
        case .ink: String(localized: "mascot.style.ink", table: "Mascot")
        case .pixel: String(localized: "mascot.style.pixel", table: "Mascot")
        }
    }
}

enum EiscueHeadState: String, CaseIterable, Identifiable {
    case asleep, awake, looking, concerned
    var id: String { rawValue }
    var title: String {
        switch self {
        case .asleep: String(localized: "mascot.state.asleep", table: "Mascot")
        case .awake: String(localized: "mascot.state.awake", table: "Mascot")
        case .looking: String(localized: "mascot.state.looking", table: "Mascot")
        case .concerned: String(localized: "mascot.state.concerned", table: "Mascot")
        }
    }
}

/// Cube geometry and facial features share the same projected pose.
struct EiscueHeadView: View {
    var style: EiscueHeadStyle = .ice
    let state: EiscueHeadState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var appearedAt = Date.now

    private var animates: Bool { state != .concerned && !reduceMotion && scenePhase == .active }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !animates)) { timeline in
            let elapsed = animates ? timeline.date.timeIntervalSince(appearedAt) : 0
            let period = state == .asleep ? 10.0 : state == .looking ? 4.0 : 7.0
            let turn = animates ? sin(elapsed * 2 * .pi / period) : 0
            let amplitude = state == .asleep ? 22.0 : state == .looking ? 36.0 : 28.0
            let yaw = animates ? -8 + turn * amplitude : -20
            Canvas { context, size in
                let blinkPhase = elapsed.truncatingRemainder(dividingBy: 4.8)
                let openness = state == .asleep ? 0 : 1 - max(0, 1 - abs(blinkPhase - 4.1) / 0.14)
                let gaze = state == .asleep ? 0 : animates ? turn * (state == .looking ? 6 : 3)
                    : state == .looking ? 8 : 0
                let scale = min(size.width / 240, size.height / 220)
                var drawing = context
                drawing.translateBy(x: (size.width - 240 * scale) / 2, y: (size.height - 220 * scale) / 2)
                drawing.scaleBy(x: scale, y: scale)
                draw(in: &drawing, openness: openness, gaze: gaze, yaw: yaw)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Eiscue")
        .accessibilityValue(state.title)
    }

    private func draw(in context: inout GraphicsContext, openness: Double, gaze: Double, yaw: Double) {
        let monochrome = style == .ink
        let dark = colorScheme == .dark
        let outline = monochrome ? (dark ? Color(white: 0.86) : Color(white: 0.18)) : Color(red: 0.13, green: 0.20, blue: 0.28)
        let front = monochrome ? (dark ? Color(white: 0.17) : Color(white: 0.97)) : Color(red: 0.67, green: 0.91, blue: 0.97)
        let top = monochrome ? (dark ? Color(white: 0.23) : .white) : Color(red: 0.88, green: 0.98, blue: 1)
        let side = monochrome ? (dark ? Color(white: 0.12) : Color(white: 0.84)) : Color(red: 0.39, green: 0.73, blue: 0.80)
        let eye = monochrome ? outline : Color(red: 0.25, green: 0.47, blue: 0.53)
        let stroke = StrokeStyle(lineWidth: style == .pixel ? 5 : 4.5, lineCap: .round, lineJoin: style == .pixel ? .miter : .round)
        let angle = yaw * .pi / 180
        let pitch = 18.0 * .pi / 180

        // Project each cube plane, including the face artwork, so a turn changes
        // the visible side and shared edges instead of rotating a flat picture.
        func project(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
            CGPoint(x: 120 + cos(angle) * x + sin(angle) * z,
                    y: 119 + cos(pitch) * y + sin(pitch) * (-sin(angle) * x + cos(angle) * z))
        }
        func surface(_ vertices: [(Double, Double, Double)], _ color: Color) {
            let path = polygon(vertices.map { vertex in
                let point = project(vertex.0, vertex.1, vertex.2)
                return (point.x, point.y)
            })
            context.fill(path, with: .color(color))
            context.stroke(path, with: .color(outline), style: stroke)
        }
        surface([(-70, -64, -50), (70, -64, -50), (70, -64, 50), (-70, -64, 50)], top)
        let visibleSide = yaw < 0 ? 70.0 : -70.0
        surface([(visibleSide, -64, -50), (visibleSide, -64, 50),
                 (visibleSide, 64, 50), (visibleSide, 64, -50)], side)
        surface([(-70, -64, 50), (70, -64, 50), (70, 64, 50), (-70, 64, 50)], front)

        let tuft: [(Double, Double)] = style == .pixel
            ? [(-2, -67), (-2, -79), (10, -79), (10, -103), (22, -103), (22, -91),
               (34, -91), (34, -79), (46, -79), (46, -91), (70, -91), (70, -79),
               (34, -61), (18, -78), (7, -64)]
            : [(-2, -67), (17, -103), (32, -85), (59, -97), (71, -79), (33, -61), (18, -78), (7, -64)]
        surface(tuft.map { ($0.0, $0.1, -5) }, monochrome ? outline : Color(white: 0.27))

        let origin = project(-70, -64, 50)
        let horizontal = project(-69, -64, 50)
        let vertical = project(-70, -63, 50)
        context.concatenate(CGAffineTransform(a: horizontal.x - origin.x, b: horizontal.y - origin.y,
                                             c: vertical.x - origin.x, d: vertical.y - origin.y,
                                             tx: origin.x, ty: origin.y))
        if style != .pixel {
            context.fill(Path(ellipseIn: CGRect(x: 11, y: 13, width: 12, height: 19)), with: .color(.white.opacity(monochrome ? 0.25 : 0.8)))
            context.fill(Path(ellipseIn: CGRect(x: 24, y: 33, width: 6, height: 9)), with: .color(.white.opacity(monochrome ? 0.25 : 0.8)))
        }

        for (index, center) in [CGPoint(x: 42 + gaze, y: 64), CGPoint(x: 100 + gaze, y: 64)].enumerated() {
            if state == .concerned {
                // Filled eyes and broad inner-raised brows stay legible at 32 pt.
                let rect = CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 20)
                context.fill(style == .pixel ? Path(rect) : Path(ellipseIn: rect), with: .color(eye))
                var brow = Path()
                if index == 0 {
                    brow.move(to: CGPoint(x: center.x - 13, y: center.y - 17))
                    if style == .pixel {
                        brow.addLine(to: CGPoint(x: center.x - 2, y: center.y - 17))
                        brow.addLine(to: CGPoint(x: center.x - 2, y: center.y - 22))
                        brow.addLine(to: CGPoint(x: center.x + 11, y: center.y - 22))
                        brow.addLine(to: CGPoint(x: center.x + 11, y: center.y - 26))
                    } else {
                        brow.addQuadCurve(to: CGPoint(x: center.x + 11, y: center.y - 26),
                                          control: CGPoint(x: center.x, y: center.y - 18))
                    }
                } else {
                    brow.move(to: CGPoint(x: center.x - 11, y: center.y - 26))
                    if style == .pixel {
                        brow.addLine(to: CGPoint(x: center.x - 11, y: center.y - 22))
                        brow.addLine(to: CGPoint(x: center.x, y: center.y - 22))
                        brow.addLine(to: CGPoint(x: center.x, y: center.y - 17))
                        brow.addLine(to: CGPoint(x: center.x + 13, y: center.y - 17))
                    } else {
                        brow.addQuadCurve(to: CGPoint(x: center.x + 13, y: center.y - 17),
                                          control: CGPoint(x: center.x, y: center.y - 18))
                    }
                }
                context.stroke(brow, with: .color(eye), style: StrokeStyle(lineWidth: 6, lineCap: .round,
                    lineJoin: style == .pixel ? .miter : .round))
            } else if openness < 0.15 {
                var closed = Path()
                closed.move(to: CGPoint(x: center.x - 11, y: center.y))
                if style == .pixel {
                    closed.addLine(to: CGPoint(x: center.x - 11, y: center.y + 5))
                    closed.addLine(to: CGPoint(x: center.x + 11, y: center.y + 5))
                    closed.addLine(to: CGPoint(x: center.x + 11, y: center.y))
                } else {
                    closed.addQuadCurve(to: CGPoint(x: center.x + 11, y: center.y), control: CGPoint(x: center.x, y: center.y + 9))
                }
                context.stroke(closed, with: .color(eye), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            } else {
                let rect = CGRect(x: center.x - 11, y: center.y - 18 * openness, width: 22, height: 36 * openness)
                let path = style == .pixel ? Path(rect) : Path(ellipseIn: rect)
                context.stroke(path, with: .color(eye), style: StrokeStyle(lineWidth: 4, lineJoin: .round))
            }
        }
        let beak = polygon([(71, 88), (85, 102), (71, 113), (58, 101)])
        context.fill(beak, with: .color(top))
        context.fill(polygon([(71, 88), (71, 113), (58, 101)]), with: .color(side.opacity(0.6)))
        context.stroke(beak, with: .color(eye), style: StrokeStyle(lineWidth: 3.5, lineJoin: .round))
    }

    private func polygon(_ points: [(Double, Double)]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: CGPoint(x: first.0, y: first.1))
            for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
            path.closeSubpath()
        }
    }
}
