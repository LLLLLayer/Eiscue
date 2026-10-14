import SwiftUI
import UIKit

struct RunToolDetailView: View {
    @Environment(AppModel.self) private var model
    let activityID: String
    let initialRecord: RunRecord

    private var record: RunRecord {
        if let active = model.activeRun, active.id == initialRecord.id { return active }
        return model.runs.first { $0.id == initialRecord.id } ?? initialRecord
    }

    private var details: RunToolDetails? {
        guard let activities = record.activities, let activity = activities.first(where: { $0.id == activityID }) else { return nil }
        return RunToolDetails(activity: activity, activities: activities)
    }

    var body: some View {
        List {
            if let details {
                Section {
                    Label(DeviceToolPresentation.activityTitle(for: details.activity),
                          systemImage: details.activity.isRunning ? "circle.dotted.circle" : details.activity.isError ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.headline)
                    LabeledContent("runs.startTime") {
                        Text(details.activity.startedAt, format: .dateTime.hour().minute().second())
                    }
                    if let end = details.activity.endedAt {
                        LabeledContent("runs.duration", value: RunReport.duration(from: details.activity.startedAt, to: end))
                    }
                }

                if details.isAction {
                    Section {
                        if let source = details.sourceActivity, let frame = details.sourceFrame {
                            RunToolImageSection(activity: source, frame: frame, marker: details.imageMarker)
                        } else {
                            Text(runDetailText("runDetails.missingSource"))
                                .font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier("runToolMissingSourceImage")
                        }
                        if let marker = details.marker {
                            Text(coordinates(marker)).font(.caption.monospacedDigit()).textSelection(.enabled)
                                .accessibilityIdentifier("runToolCoordinates")
                        }
                    } header: {
                        Text(runDetailText("runDetails.before"))
                    } footer: {
                        if details.imageMarker != nil { Text(runDetailText("runDetails.markerNote")) }
                    }
                }

                if details.hasOutputImage {
                    Section {
                        RunToolImageSection(activity: details.activity, frame: nil, marker: nil)
                    } header: {
                        Text(runDetailText(details.isAction ? "runDetails.after" : "runDetails.observed"))
                    }
                }

                Section {
                    detailText(details.activity.arguments, empty: "runDetails.noInput")
                        .accessibilityIdentifier("runToolInput")
                } header: {
                    Text(runDetailText("runDetails.input"))
                }

                Section {
                    detailText(details.activity.output, empty: details.activity.isRunning ? "runDetails.waiting" : "runDetails.noOutput")
                        .accessibilityIdentifier("runToolOutput")
                } header: {
                    Text(runDetailText("runDetails.output"))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(EiscueStyle.background)
        .navigationTitle(runDetailText("runDetails.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detailText(_ text: String, empty: String.LocalizationValue) -> some View {
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == "{}"
        return Text(verbatim: isEmpty ? runDetailText(empty) : text)
            .font(.system(.subheadline, design: .monospaced))
            .foregroundStyle(isEmpty ? .secondary : .primary)
            .textSelection(.enabled)
    }

    private func coordinates(_ marker: RunToolDetails.Marker) -> String {
        func point(_ value: RunToolDetails.Point) -> String {
            "(\(value.x.formatted(.number.precision(.fractionLength(0...2)))), \(value.y.formatted(.number.precision(.fractionLength(0...2)))))"
        }
        return switch marker {
        case .tap(let value): String(localized: "runDetails.tap \(point(value))", table: "RunDetails")
        case .swipe(let from, let to): String(localized: "runDetails.swipe \(point(from)) \(point(to))", table: "RunDetails")
        }
    }
}

private struct RunToolImageSection: View {
    @Environment(AppModel.self) private var model
    let activity: ToolActivity
    let frame: RunToolDetails.Frame?
    let marker: RunToolDetails.Marker?

    var body: some View {
        let previews = model.toolImagePreviews.previews(for: activity.id)
        Group {
            if !previews.isEmpty {
                ForEach(previews) { preview in
                    RunToolImagePreview(preview: preview, frame: frame, marker: marker)
                }
            } else if model.toolImagePreviews.state(for: activity.id) == .idle {
                Button(runDetailText("runDetails.loadImage"), systemImage: "arrow.clockwise") {
                    Task { await model.loadToolImagePreviews(for: activity) }
                }.buttonStyle(.glass)
            } else if model.toolImagePreviews.state(for: activity.id) == .unavailable {
                Text(runDetailText("runDetails.imageUnavailable"))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("runToolImageUnavailable")
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(runDetailText("runDetails.loadingImage")).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: activity.output) { await model.loadToolImagePreviews(for: activity) }
    }
}

private struct RunToolImagePreview: View {
    let preview: ToolImagePreview
    let frame: RunToolDetails.Frame?
    let marker: RunToolDetails.Marker?
    @State private var annotatedImage: UIImage?

    var body: some View {
        ToolImageThumbnail(preview: ToolImagePreview(id: "run-detail:\(preview.id)", image: annotatedImage ?? preview.image), width: nil, height: 320)
            .accessibilityIdentifier("runToolImageThumbnail")
            .task(id: preview.id) {
                guard let frame, let marker else { return }
                annotatedImage = RunToolImageAnnotation.image(preview.image, frame: frame, marker: marker)
            }
    }
}

/// Draw only a local preview copy; annotated pixels never enter the tool result or runtime.
@MainActor
enum RunToolImageAnnotation {
    static func image(_ image: UIImage, frame: RunToolDetails.Frame, marker: RunToolDetails.Marker) -> UIImage? {
        guard marker.fits(frame), image.size.width > 0, image.size.height > 0,
              abs(image.size.width / image.size.height - CGFloat(frame.width) / CGFloat(frame.height)) < 0.01 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { context in
            image.draw(in: CGRect(origin: .zero, size: image.size))
            let canvas = context.cgContext
            let lineWidth = max(2, image.size.width / 160)
            let radius = max(8, image.size.width / 45)
            func point(_ value: RunToolDetails.Point) -> CGPoint {
                CGPoint(x: CGFloat(value.x / Double(frame.width)) * image.size.width,
                        y: CGFloat(value.y / Double(frame.height)) * image.size.height)
            }
            func circle(_ value: CGPoint, filled: Bool) {
                let rect = CGRect(x: value.x - radius, y: value.y - radius, width: radius * 2, height: radius * 2)
                canvas.setStrokeColor(UIColor.white.cgColor); canvas.setLineWidth(lineWidth * 2)
                canvas.strokeEllipse(in: rect)
                canvas.setStrokeColor(UIColor.systemRed.cgColor); canvas.setLineWidth(lineWidth)
                canvas.strokeEllipse(in: rect)
                if filled {
                    canvas.setFillColor(UIColor.systemRed.cgColor)
                    canvas.fillEllipse(in: CGRect(x: value.x - lineWidth, y: value.y - lineWidth, width: lineWidth * 2, height: lineWidth * 2))
                }
            }
            switch marker {
            case .tap(let value): circle(point(value), filled: true)
            case .swipe(let from, let to):
                let start = point(from), end = point(to)
                let angle = atan2(end.y - start.y, end.x - start.x)
                let arrowLength = radius * 1.5
                let path = CGMutablePath()
                path.move(to: start); path.addLine(to: end)
                path.move(to: CGPoint(x: end.x - arrowLength * cos(angle - .pi / 6), y: end.y - arrowLength * sin(angle - .pi / 6)))
                path.addLine(to: end)
                path.addLine(to: CGPoint(x: end.x - arrowLength * cos(angle + .pi / 6), y: end.y - arrowLength * sin(angle + .pi / 6)))
                canvas.setLineCap(.round); canvas.setLineJoin(.round)
                canvas.setStrokeColor(UIColor.white.cgColor); canvas.setLineWidth(lineWidth * 2)
                canvas.addPath(path); canvas.strokePath()
                canvas.setStrokeColor(UIColor.systemRed.cgColor); canvas.setLineWidth(lineWidth)
                canvas.addPath(path); canvas.strokePath()
                circle(start, filled: false)
            }
        }
    }
}

private func runDetailText(_ key: String.LocalizationValue) -> String { String(localized: key, table: "RunDetails") }
