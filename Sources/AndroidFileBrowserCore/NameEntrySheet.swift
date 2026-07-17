import SwiftUI

struct NameEntrySheet: View {
    let title: String
    let defaultValue: String
    let submit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var value: String
    @State private var didSubmit = false
    @FocusState private var isNameFocused: Bool

    init(title: String, defaultValue: String, submit: @escaping (String) -> Void) {
        self.title = title
        self.defaultValue = defaultValue
        self.submit = submit
        self._value = State(initialValue: defaultValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3.weight(.semibold))

            TextField("Name", text: $value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
                .focused($isNameFocused)
                .onSubmit(submitAndDismiss)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Done") {
                    submitAndDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .task {
            isNameFocused = true
        }
    }

    private func submitAndDismiss() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !didSubmit, !trimmed.isEmpty else { return }
        didSubmit = true
        submit(trimmed)
        dismiss()
    }
}
