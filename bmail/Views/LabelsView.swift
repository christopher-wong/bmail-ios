import SwiftUI

struct LabelsView: View {
    @State private var labels: [MailLabel] = []
    @State private var loading = true
    @State private var newLabelName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        ZStack {
            Wallpaper()

            Form {
                // Add new label section
                Section {
                    HStack(spacing: DS.Space.s) {
                        TextField("New label", text: $newLabelName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit { Task { await add() } }

                        Button {
                            Task { await add() }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(newLabelName.isEmpty ? DS.Color.inkFaint : .accentColor)
                        }
                        .buttonStyle(.plain)
                        .disabled(newLabelName.isEmpty)
                        .accessibilityLabel("Add label")
                    }
                }

                // Existing labels
                Section {
                    if loading {
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.regular)
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    } else if labels.isEmpty {
                        DSEmptyState(
                            systemName: "tag",
                            title: "No labels yet",
                            hint: "Add a label above to organize your mail."
                        )
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    } else {
                        ForEach(labels) { label in
                            HStack(spacing: DS.Space.m) {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: DS.Space.s, height: DS.Space.s)
                                Text(label.name)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(.vertical, DS.Space.xs)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await del(label) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    if !labels.isEmpty {
                        Text("Your labels")
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Labels")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { nameFocused = false }
            }
        }
        .task { await load() }
    }

    // MARK: - Data

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
        let name = newLabelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let _: MailLabel = try await APIClient.shared.post("/api/labels", Body(name: name))
            newLabelName = ""
            nameFocused = false
            DSHaptics.notifySuccess()
            await load()
        } catch {}
    }

    private func del(_ l: MailLabel) async {
        DSHaptics.impactMedium()
        labels.removeAll { $0.id == l.id }
        _ = try? await APIClient.shared.delete("/api/labels/\(l.id)")
    }
}
