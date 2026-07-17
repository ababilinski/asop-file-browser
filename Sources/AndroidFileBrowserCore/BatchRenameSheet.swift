import SwiftUI

struct BatchRenameSheet: View {
    @ObservedObject var model: AppModel
    let request: BatchRenameRequest
    @Environment(\.dismiss) private var dismiss
    @State private var options = BatchRenameOptions()

    private var previews: [BatchRenamePreview] {
        model.batchRenamePreviews(for: request, options: options)
    }

    private var hasCollision: Bool {
        previews.contains { $0.collision }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Batch Rename")
                .font(.title3.weight(.semibold))

            Picker("Mode", selection: $options.mode) {
                ForEach(BatchRenameMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            modeControls

            Table(previews) {
                TableColumn("Current") { preview in
                    Text(preview.originalName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                TableColumn("New") { preview in
                    HStack {
                        Text(preview.proposedName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if preview.collision {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .frame(minHeight: 220)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Rename") {
                    Task {
                        await model.applyBatchRename(request: request, options: options)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(hasCollision)
            }
        }
        .padding(20)
        .frame(width: 680, height: 480)
    }

    @ViewBuilder
    private var modeControls: some View {
        switch options.mode {
        case .findReplace:
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Find")
                        .foregroundStyle(.secondary)
                    TextField("Text", text: $options.findText)
                }
                GridRow {
                    Text("Replace")
                        .foregroundStyle(.secondary)
                    TextField("Text", text: $options.replaceText)
                }
            }
        case .numberedBaseName:
            HStack {
                TextField("Base Name", text: $options.baseName)
                Stepper(value: $options.startNumber, in: 0...999_999) {
                    Text("Start \(options.startNumber)")
                        .monospacedDigit()
                }
                .frame(width: 150)
            }
        case .prefixSuffix:
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Prefix")
                        .foregroundStyle(.secondary)
                    TextField("Prefix", text: $options.prefix)
                }
                GridRow {
                    Text("Suffix")
                        .foregroundStyle(.secondary)
                    TextField("Suffix", text: $options.suffix)
                }
            }
        case .changeExtension:
            HStack {
                Text("Extension")
                    .foregroundStyle(.secondary)
                TextField("jpg", text: $options.newExtension)
                    .frame(width: 180)
            }
        }
    }
}
