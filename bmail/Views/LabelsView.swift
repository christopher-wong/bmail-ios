import SwiftUI

struct LabelsView: View {
    @State private var labels: [MailLabel] = []
    @State private var loading = true
    @State private var newMailLabel = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SectionHeader(title: "LABELS")

                HStack(spacing: 8) {
                    TextField("new label name", text: $newMailLabel)
                        .font(.mono(.subheadline))
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Theme.hairline, lineWidth: 1)
                        )
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit { Task { await add() } }
                    Button("ADD ▸") { Task { await add() } }
                        .monoButton(prominent: true, disabled: newMailLabel.isEmpty)
                        .disabled(newMailLabel.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Hairline()

                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if labels.isEmpty {
                    EmptyStateView(title: "no labels yet")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(labels) { l in
                                HStack {
                                    Text(l.name).font(.mono(13))
                                    Spacer()
                                    Button("DELETE") { Task { await del(l) } }
                                        .monoButton()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                Hairline()
                            }
                        }
                    }
                }
            }
            .background(Theme.inverseInk)
            .task { await load() }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { nameFocused = false }
                        .font(.mono(.footnote, weight: .medium))
                }
            }
        }
    }

    private func load() async {
        loading = true
        do {
            let rows: [MailLabel] = try await APIClient.shared.get("/api/labels")
            labels = rows
        } catch {}
        loading = false
    }

    private func add() async {
        struct Body: Encodable { let name: String }
        let name = newMailLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let _: MailLabel = try await APIClient.shared.post("/api/labels", Body(name: name))
            newMailLabel = ""
            await load()
        } catch {}
    }

    private func del(_ l: MailLabel) async {
        labels.removeAll { $0.id == l.id }
        _ = try? await APIClient.shared.delete("/api/labels/\(l.id)")
    }
}
