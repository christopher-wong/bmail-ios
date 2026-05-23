import SwiftUI

struct RecoveryLoginView: View {
    @Environment(AppModel.self) private var app
    @State private var handle: String = ""
    @State private var phrase: String = ""
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("handle")
                    .monoLabel()
                    .frame(width: 100, alignment: .leading)
                TextField("your handle", text: $handle)
                    .font(.mono(13))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.vertical, 12)
            }
            .padding(.horizontal, 16)
            Hairline()

            VStack(alignment: .leading, spacing: 6) {
                Text("recovery phrase")
                    .monoLabel()
                TextEditor(text: $phrase)
                    .font(.mono(13))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 96)
                    .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Button {
                Task {
                    busy = true
                    await app.loginWithRecovery(handle: handle.trimmingCharacters(in: .whitespacesAndNewlines), phrase: phrase)
                    busy = false
                }
            } label: {
                HStack {
                    Spacer()
                    if busy {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(Theme.inverseInk)
                    } else {
                        Text("SIGN IN WITH PHRASE ▸")
                            .font(.mono(12, .medium))
                            .tracking(1.2)
                    }
                    Spacer()
                }
                .padding(.vertical, 18)
                .background(Theme.inverseBg)
                .foregroundStyle(Theme.inverseInk)
            }
            .buttonStyle(.plain)
            .disabled(busy || handle.isEmpty || phrase.split(whereSeparator: { $0.isWhitespace }).count != 12)

            Text("argon2id over your 12-word phrase. takes a few seconds.")
                .font(.mono(10))
                .foregroundStyle(Theme.mute)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
        }
    }
}
