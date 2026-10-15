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
    case asleep, awake, looking
    var id: String { rawValue }
    var title: String {
        switch self {
        case .asleep: String(localized: "mascot.state.asleep", table: "Mascot")
        case .awake: String(localized: "mascot.state.awake", table: "Mascot")
        case .looking: String(localized: "mascot.state.looking", table: "Mascot")
        }
    }
}

/// Small vector artwork; disconnected faces do not keep an animation clock running.
struct EiscueHeadView: View {
    var style: EiscueHeadStyle = .ice
    let state: EiscueHeadState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var appearedAt = Date.now

    private var animates: Bool { state != .asleep && !reduceMotion && scenePhase == .active }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !animates)) { timeline in
            Canvas { context, size in
                let elapsed = animates ? timeline.date.timeIntervalSince(appearedAt) : 0
                let blinkPhase = elapsed.truncatingRemainder(dividingBy: 4.8)
                let openness = state == .asleep ? 0 : 1 - max(0, 1 - abs(blinkPhase - 4.1) / 0.14)
                let gaze = animates ? sin(elapsed * (state == .looking ? 1.5 : 0.65)) * (state == .looking ? 6 : 3) : 0
                let scale = min(size.width / 240, size.height / 220)
                var drawing = context
                drawing.translateBy(x: (size.width - 240 * scale) / 2, y: (size.height - 220 * scale) / 2)
                drawing.scaleBy(x: scale, y: scale)
                draw(in: &drawing, openness: openness, gaze: gaze)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Eiscue")
        .accessibilityValue(state.title)
    }

    private func draw(in context: inout GraphicsContext, openness: Double, gaze: Double) {
        let monochrome = style == .ink
        let dark = colorScheme == .dark
        let outline = monochrome ? (dark ? Color(white: 0.86) : Color(white: 0.18)) : Color(red: 0.13, green: 0.20, blue: 0.28)
        let front = monochrome ? (dark ? Color(white: 0.17) : Color(white: 0.97)) : Color(red: 0.67, green: 0.91, blue: 0.97)
        let top = monochrome ? (dark ? Color(white: 0.23) : .white) : Color(red: 0.88, green: 0.98, blue: 1)
        let side = monochrome ? (dark ? Color(white: 0.12) : Color(white: 0.84)) : Color(red: 0.39, green: 0.73, blue: 0.80)
        let eye = monochrome ? outline : Color(red: 0.25, green: 0.47, blue: 0.53)
        let stroke = StrokeStyle(lineWidth: style == .pixel ? 5 : 4.5, lineCap: .round, lineJoin: style == .pixel ? .miter : .round)

        func paint(_ path: Path, _ color: Color) {
            context.fill(path, with: .color(color))
            context.stroke(path, with: .color(outline), style: stroke)
        }
        if style == .pixel {
            paint(polygon([(36, 70), (72, 40), (190, 40), (214, 64), (178, 88)]), top)
            paint(polygon([(178, 88), (214, 64), (214, 166), (202, 166), (202, 178), (178, 202)]), side)
            paint(polygon([(36, 70), (178, 88), (178, 202), (48, 186), (48, 178), (36, 178)]), front)
            paint(polygon([(126, 52), (126, 40), (138, 40), (138, 16), (150, 16), (150, 28),
                           (162, 28), (162, 40), (174, 40), (174, 28), (198, 28), (198, 40), (174, 64), (150, 48), (138, 60)]), outline)
        } else {
            var topFace = Path()
            topFace.move(to: CGPoint(x: 40, y: 70))
            topFace.addQuadCurve(to: CGPoint(x: 95, y: 39), control: CGPoint(x: 65, y: 41))
            topFace.addQuadCurve(to: CGPoint(x: 118, y: 39), control: CGPoint(x: 106, y: 36))
            topFace.addLine(to: CGPoint(x: 200, y: 55))
            topFace.addQuadCurve(to: CGPoint(x: 215, y: 65), control: CGPoint(x: 213, y: 57))
            topFace.addLine(to: CGPoint(x: 180, y: 87)); topFace.closeSubpath()
            paint(topFace, top)
            var rightFace = Path()
            rightFace.move(to: CGPoint(x: 180, y: 87)); rightFace.addLine(to: CGPoint(x: 215, y: 65))
            rightFace.addQuadCurve(to: CGPoint(x: 211, y: 166), control: CGPoint(x: 221, y: 108))
            rightFace.addQuadCurve(to: CGPoint(x: 177, y: 196), control: CGPoint(x: 209, y: 182))
            rightFace.closeSubpath(); paint(rightFace, side)
            var frontFace = Path()
            frontFace.move(to: CGPoint(x: 40, y: 70)); frontFace.addLine(to: CGPoint(x: 180, y: 87))
            frontFace.addQuadCurve(to: CGPoint(x: 177, y: 188), control: CGPoint(x: 181, y: 139))
            frontFace.addQuadCurve(to: CGPoint(x: 163, y: 201), control: CGPoint(x: 176, y: 202))
            frontFace.addLine(to: CGPoint(x: 47, y: 186))
            frontFace.addQuadCurve(to: CGPoint(x: 32, y: 172), control: CGPoint(x: 33, y: 184))
            frontFace.addQuadCurve(to: CGPoint(x: 40, y: 70), control: CGPoint(x: 26, y: 101))
            frontFace.closeSubpath(); paint(frontFace, front)
            paint(polygon([(126, 53), (146, 17), (162, 35), (190, 23), (203, 41), (163, 61), (149, 44), (136, 58)]),
                  monochrome ? outline : Color(white: 0.27))
            context.fill(Path(ellipseIn: CGRect(x: 45, y: 83, width: 12, height: 19)), with: .color(.white.opacity(monochrome ? 0.25 : 0.8)))
            context.fill(Path(ellipseIn: CGRect(x: 58, y: 103, width: 6, height: 9)), with: .color(.white.opacity(monochrome ? 0.25 : 0.8)))
        }

        for center in [CGPoint(x: 77 + gaze, y: 133), CGPoint(x: 139 + gaze, y: 141)] {
            if openness < 0.15 {
                var closed = Path()
                closed.move(to: CGPoint(x: center.x - 12, y: center.y))
                if style == .pixel {
                    closed.addLine(to: CGPoint(x: center.x - 12, y: center.y + 5))
                    closed.addLine(to: CGPoint(x: center.x + 12, y: center.y + 5))
                    closed.addLine(to: CGPoint(x: center.x + 12, y: center.y))
                } else {
                    closed.addQuadCurve(to: CGPoint(x: center.x + 12, y: center.y), control: CGPoint(x: center.x, y: center.y + 10))
                }
                context.stroke(closed, with: .color(eye), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            } else {
                let rect = CGRect(x: center.x - 12, y: center.y - 19 * openness, width: 24, height: 38 * openness)
                let path = style == .pixel ? Path(rect) : Path(ellipseIn: rect)
                context.stroke(path, with: .color(eye), style: StrokeStyle(lineWidth: 4, lineJoin: .round))
            }
        }
        let beak = polygon([(108, 157), (122, 172), (107, 183), (94, 170)])
        context.fill(beak, with: .color(top))
        context.fill(polygon([(108, 157), (107, 183), (94, 170)]), with: .color(side.opacity(0.6)))
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
