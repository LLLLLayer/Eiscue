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
        let eye = monochrome ? outline : Color(red: 0.25, green: 0.49, blue: 0.55)
        let stroke = StrokeStyle(lineWidth: style == .pixel ? 5 : 4.5, lineCap: .round, lineJoin: style == .pixel ? .miter : .round)
        let angle = yaw * .pi / 180
        let pitch = 18.0 * .pi / 180

        // Project each cube plane, including the face artwork, so a turn changes
        // the visible side and shared edges instead of rotating a flat picture.
        func project(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
            CGPoint(x: 120 + cos(angle) * x + sin(angle) * z,
                    y: 119 + cos(pitch) * y + sin(pitch) * (-sin(angle) * x + cos(angle) * z))
        }
        func projected(_ vertices: [(Double, Double, Double)]) -> [CGPoint] {
            vertices.map { project($0.0, $0.1, $0.2) }
        }
        func surface(_ vertices: [(Double, Double, Double)], _ color: Color) {
            let path = roundedPolygon(projected(vertices), radius: 0)
            context.fill(path, with: .color(color))
            context.stroke(path, with: .color(outline), style: stroke)
        }
        let visibleSide = yaw < 0 ? 70.0 : -70.0
        let topVertices = [(-70.0, -64.0, -50.0), (70.0, -64.0, -50.0), (70.0, -64.0, 50.0), (-70.0, -64.0, 50.0)]
        let sideVertices = [(visibleSide, -64.0, -50.0), (visibleSide, -64.0, 50.0),
                            (visibleSide, 64.0, 50.0), (visibleSide, 64.0, -50.0)]
        let frontVertices = [(-70.0, -64.0, 50.0), (70.0, -64.0, 50.0), (70.0, 64.0, 50.0), (-70.0, 64.0, 50.0)]
        let corners = [-70.0, 70.0].flatMap { x in
            [-64.0, 64.0].flatMap { y in [-50.0, 50.0].map { z in project(x, y, z) } }
        }
        let hull = roundedPolygon(convexHull(corners), radius: 12)
        if style == .pixel {
            surface(topVertices, top)
            surface(sideVertices, side)
            surface(frontVertices, front)
        } else {
            let topColors = monochrome ? [top, front] : [Color(red: 0.95, green: 0.99, blue: 1), Color(red: 0.79, green: 0.95, blue: 0.98)]
            let frontColors = monochrome ? [front, side] : [Color(red: 0.77, green: 0.96, blue: 1), Color(red: 0.60, green: 0.87, blue: 0.92)]
            let sideColors = monochrome ? [side, front.opacity(0.8)] : [Color(red: 0.55, green: 0.85, blue: 0.90), Color(red: 0.33, green: 0.70, blue: 0.78)]
            var ice = context
            ice.clip(to: hull)
            ice.fill(roundedPolygon(projected(topVertices), radius: 0), with: .linearGradient(
                Gradient(colors: topColors), startPoint: CGPoint(x: 65, y: 35), endPoint: CGPoint(x: 155, y: 100)))
            ice.fill(roundedPolygon(projected(sideVertices), radius: 0), with: .linearGradient(
                Gradient(colors: sideColors), startPoint: CGPoint(x: 90, y: 60), endPoint: CGPoint(x: 210, y: 195)))
            ice.fill(roundedPolygon(projected(frontVertices), radius: 0), with: .linearGradient(
                Gradient(colors: frontColors), startPoint: CGPoint(x: 55, y: 85), endPoint: CGPoint(x: 175, y: 200)))
            var creases = Path()
            creases.move(to: project(-58, -64, 50))
            creases.addLine(to: project(58, -64, 50))
            creases.move(to: project(visibleSide, -49, 50))
            creases.addLine(to: project(visibleSide, 49, 50))
            context.stroke(creases, with: .color(eye.opacity(0.85)), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
            // One rounded outline avoids dark seams between the ice planes.
            context.stroke(hull, with: .color(outline), style: StrokeStyle(lineWidth: 7.5, lineJoin: .round))
        }

        let tuft: [(Double, Double)] = style == .pixel
            ? [(-2, -67), (-2, -79), (10, -79), (10, -103), (22, -103), (22, -91),
               (34, -91), (34, -79), (46, -79), (46, -91), (70, -91), (70, -79),
               (34, -61), (18, -78), (7, -64)]
            : [(-2, -67), (17, -103), (32, -85), (59, -97), (71, -79), (33, -61), (18, -78), (7, -64)]
        if style == .pixel {
            surface(tuft.map { ($0.0, $0.1, -5) }, monochrome ? outline : Color(white: 0.27))
        } else {
            let tuftPath = roundedPolygon(projected(tuft.map { ($0.0, $0.1, -5) }), radius: 4)
            context.fill(tuftPath, with: .linearGradient(Gradient(colors: monochrome ? [outline, eye] :
                [Color(red: 0.35, green: 0.35, blue: 0.35), Color(red: 0.22, green: 0.24, blue: 0.25)]),
                startPoint: CGPoint(x: 110, y: 25), endPoint: CGPoint(x: 180, y: 80)))
            context.stroke(tuftPath, with: .color(outline), style: StrokeStyle(lineWidth: 7.5, lineJoin: .round))
            context.clip(to: hull)
        }

        let origin = project(-70, -64, 50)
        let horizontal = project(-69, -64, 50)
        let vertical = project(-70, -63, 50)
        context.concatenate(CGAffineTransform(a: horizontal.x - origin.x, b: horizontal.y - origin.y,
                                             c: vertical.x - origin.x, d: vertical.y - origin.y,
                                             tx: origin.x, ty: origin.y))
        if style != .pixel {
            context.stroke(Path(roundedRect: CGRect(x: 3, y: 3, width: 134, height: 122), cornerRadius: 16),
                           with: .color(.white.opacity(monochrome ? 0.12 : 0.4)), lineWidth: 3)
            context.fill(Path(ellipseIn: CGRect(x: 11, y: 13, width: 12, height: 19)), with: .color(.white.opacity(monochrome ? 0.25 : 0.8)))
            context.fill(Path(ellipseIn: CGRect(x: 24, y: 33, width: 6, height: 9)), with: .color(.white.opacity(monochrome ? 0.25 : 0.8)))
        }

        for (index, center) in [CGPoint(x: 42 + gaze, y: style == .pixel ? 64 : 69), CGPoint(x: 100 + gaze, y: style == .pixel ? 64 : 69)].enumerated() {
            if state == .concerned {
                if style == .pixel {
                    context.fill(Path(CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 20)), with: .color(eye))
                } else {
                    context.stroke(Path(ellipseIn: CGRect(x: center.x - 11, y: center.y - 16, width: 22, height: 32)),
                                   with: .color(eye), lineWidth: 4)
                }
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
                closed.move(to: CGPoint(x: center.x - (style == .pixel ? 11 : 12), y: center.y))
                if style == .pixel {
                    closed.addLine(to: CGPoint(x: center.x - 11, y: center.y + 5))
                    closed.addLine(to: CGPoint(x: center.x + 11, y: center.y + 5))
                    closed.addLine(to: CGPoint(x: center.x + 11, y: center.y))
                } else {
                    closed.addQuadCurve(to: CGPoint(x: center.x + 12, y: center.y), control: CGPoint(x: center.x, y: center.y + 10))
                }
                context.stroke(closed, with: .color(eye), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            } else {
                let radiusX = style == .pixel ? 11.0 : 13.0
                let radiusY = style == .pixel ? 18.0 : 20.0
                let rect = CGRect(x: center.x - radiusX, y: center.y - radiusY * openness, width: radiusX * 2, height: radiusY * 2 * openness)
                let path = style == .pixel ? Path(rect) : Path(ellipseIn: rect)
                context.stroke(path, with: .color(eye), style: StrokeStyle(lineWidth: 4, lineJoin: .round))
            }
        }
        let beakPoints: [(Double, Double)] = style == .pixel
            ? [(71, 88), (85, 102), (71, 113), (58, 101)] : [(71, 89), (90, 106), (72, 118), (52, 104)]
        let beak = roundedPolygon(beakPoints.map { CGPoint(x: $0.0, y: $0.1) }, radius: style == .pixel ? 0 : 2.5)
        context.fill(beak, with: .linearGradient(Gradient(colors: [top, front]),
                     startPoint: CGPoint(x: 60, y: 90), endPoint: CGPoint(x: 85, y: 118)))
        context.fill(polygon(style == .pixel ? [(71, 88), (71, 113), (58, 101)] : [(71, 89), (72, 118), (52, 104)]),
                     with: .color(side.opacity(0.6)))
        context.stroke(beak, with: .color(eye), style: StrokeStyle(lineWidth: style == .pixel ? 3.5 : 3.8, lineJoin: .round))
    }

    private func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func turn(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        func half(_ points: [CGPoint]) -> [CGPoint] {
            var result: [CGPoint] = []
            for point in points {
                while result.count >= 2, turn(result[result.count - 2], result[result.count - 1], point) <= 0 {
                    result.removeLast()
                }
                result.append(point)
            }
            return result
        }
        return Array(half(sorted).dropLast()) + Array(half(sorted.reversed()).dropLast())
    }

    private func roundedPolygon(_ points: [CGPoint], radius: CGFloat) -> Path {
        guard points.count > 2 else { return Path() }
        return Path { path in
            for index in points.indices {
                let previous = points[(index + points.count - 1) % points.count]
                let current = points[index]
                let next = points[(index + 1) % points.count]
                let before = hypot(current.x - previous.x, current.y - previous.y)
                let after = hypot(next.x - current.x, next.y - current.y)
                let distance = min(radius, before / 2, after / 2)
                let start = CGPoint(x: current.x + (previous.x - current.x) * distance / max(before, 0.001),
                                    y: current.y + (previous.y - current.y) * distance / max(before, 0.001))
                let end = CGPoint(x: current.x + (next.x - current.x) * distance / max(after, 0.001),
                                  y: current.y + (next.y - current.y) * distance / max(after, 0.001))
                if index == 0 { path.move(to: start) } else { path.addLine(to: start) }
                path.addQuadCurve(to: end, control: current)
            }
            path.closeSubpath()
        }
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
