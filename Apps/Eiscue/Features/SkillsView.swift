import SwiftUI
import UniformTypeIdentifiers

struct SkillsView: View {
    @Environment(AppModel.self) private var model
    @State private var showsImporter = false

    var body: some View {
        List {
            Section {
                Button {
                    guard !model.isBusy else { return }
                    model.selectedSkillID = nil
                } label: {
                    HStack {
                        Label("skills.none", systemImage: "bubble.left")
                        Spacer()
                        if model.selectedSkillID == nil {
                            Image(systemName: "checkmark").foregroundStyle(EiscueStyle.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
            } footer: {
                Text("skills.selectionDetail")
            }

            skillSection("skills.builtInSection", skills: model.skills.filter(\.isBuiltIn))
            skillSection("skills.importedSection", skills: model.skills.filter { !$0.isBuiltIn })

            Section {
                Button {
                    showsImporter = true
                } label: {
                    Label("skills.import", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.glass)
                .disabled(model.isBusy)
                .accessibilityIdentifier("importSkillButton")
            } footer: {
                Text("skills.importDetail")
            }
        }
        .scrollContentBackground(.hidden)
        .background(EiscueStyle.background)
        .navigationTitle("common.skill")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "markdown") ?? .plainText
        ]) { result in
            guard !model.isBusy else {
                model.errorMessage = String(localized: "skills.importWhileRunning")
                return
            }
            switch result {
            case .success(let url): model.importSkill(url)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func skillSection(_ title: String, skills: [AgentSkill]) -> some View {
        if !skills.isEmpty {
            Section(title) {
                ForEach(skills) { skill in
                    NavigationLink {
                        SkillDetailView(skillID: skill.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(skill.name).font(.body.weight(.medium))
                                if model.selectedSkillID == skill.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(EiscueStyle.accent)
                                        .accessibilityLabel("skills.selected")
                                }
                            }
                            Text(skill.contentSummary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text(skill.source)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 3)
                    }
                    .accessibilityIdentifier("skillRow_\(skill.id)")
                    .swipeActions(allowsFullSwipe: false) {
                        if !skill.isBuiltIn {
                            Button("common.delete", role: .destructive) { model.deleteSkill(skill) }
                                .tint(.gray)
                                .disabled(model.isBusy)
                        }
                    }
                }
            }
        }
    }
}

private struct SkillDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let skillID: String

    var body: some View {
        Group {
            if let skill = model.skills.first(where: { $0.id == skillID }) {
                List {
                    Section {
                        Button {
                            guard !model.isBusy else { return }
                            model.selectedSkillID = model.selectedSkillID == skill.id ? nil : skill.id
                        } label: {
                            Label(model.selectedSkillID == skill.id ? String(localized: "skills.deselect") : String(localized: "skills.select"),
                                  systemImage: model.selectedSkillID == skill.id ? "checkmark.circle.fill" : "plus.circle")
                        }
                        .buttonStyle(.glassProminent)
                        .foregroundStyle(EiscueStyle.onAccent)
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("selectSkillButton")
                    }
                    Section("skills.sourceSection") {
                        LabeledContent("skills.source", value: skill.source)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("skills.digest").font(.subheadline).foregroundStyle(.secondary)
                            Text(skill.digest)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    Section("skills.preview") {
                        Text(skill.text)
                            .font(.system(.subheadline, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("skillContentPreview")
                    }
                    if !skill.isBuiltIn {
                        Section {
                            Button("skills.deleteImported", role: .destructive) {
                                guard !model.isBusy else { return }
                                model.deleteSkill(skill)
                                if !model.skills.contains(where: { $0.id == skill.id }) { dismiss() }
                            }
                            .buttonStyle(.glass)
                            .foregroundStyle(.primary)
                            .disabled(model.isBusy)
                        }
                    }
                }
                .navigationTitle(skill.name)
            } else {
                ContentUnavailableView("skills.removed", systemImage: "doc", description: Text("skills.removedDetail"))
            }
        }
        .scrollContentBackground(.hidden)
        .background(EiscueStyle.background)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension AgentSkill {
    var contentSummary: String {
        if isBuiltIn {
            switch id {
            case "ios-navigation": return String(localized: "skills.navigationSummary")
            case "search-smoke-test": return String(localized: "skills.searchSummary")
            case "failure-recovery": return String(localized: "skills.recoverySummary")
            default: break
            }
        }
        let line = text.components(separatedBy: .newlines).first {
            let value = $0.trimmingCharacters(in: .whitespaces)
            return !value.isEmpty && !value.hasPrefix("#") && value != "---"
        }
        return String((line ?? String(localized: "skills.summaryFallback")).prefix(180))
    }
}
