import SwiftUI

/// Two explicit user boundaries: preview is read-only; confirmation performs
/// TASK-0040's single two-file transaction.
struct FlowRegistrationSheet: View {
    @ObservedObject var model: ProductionsDashboardViewModel
    let payload: FlowItem
    let finished: () -> Void
    @State private var metadata: FlowRegistrationMetadata
    @State private var preview: FlowRegistrationPreview?
    @State private var registrationError: String?

    init(model: ProductionsDashboardViewModel, payload: FlowItem, finished: @escaping () -> Void) {
        self.model = model
        self.payload = payload
        self.finished = finished
        _metadata = State(initialValue: FlowRegistrationMetadata(label: payload.label, type: "", summary: "", nextDisposition: ""))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Register in Flow").font(.title3)
            Text("The Inbox payload will not be moved, renamed, or edited.").foregroundStyle(.secondary)
            Text(payload.location).font(.caption).textSelection(.enabled)
            if let preview {
                Text("FLOW row preview").font(.headline)
                Text(preview.row).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("Confirming will atomically issue \\(preview.flowID) in the Identifier Ledger, then add this exact Flow row.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Back") { self.preview = nil }
                    Spacer()
                    Button("Cancel", role: .cancel) { finished() }
                    Button("Confirm Register") { commit(preview) }.keyboardShortcut(.defaultAction)
                }
            } else {
                Form {
                    TextField("Label", text: $metadata.label)
                    TextField("Type", text: $metadata.type)
                    TextField("Summary", text: $metadata.summary)
                    TextField("Next disposition", text: $metadata.nextDisposition)
                    TextField("Priority", text: $metadata.priority)
                    TextField("Steward", text: $metadata.steward)
                    TextField("Department", text: $metadata.department)
                    TextField("Product", text: $metadata.product)
                    TextField("Source", text: $metadata.source)
                    TextField("Related work", text: $metadata.relatedWork)
                }
                HStack {
                    Button("Cancel", role: .cancel) { finished() }
                    Spacer()
                    Button("Preview Flow Row") { makePreview() }.keyboardShortcut(.defaultAction)
                }
            }
            if let registrationError { Text(registrationError).font(.caption).foregroundStyle(.red) }
        }
        .padding()
        .frame(minWidth: 580)
    }

    private func makePreview() {
        do { preview = try model.registrationPreview(payload: payload, metadata: metadata); registrationError = nil }
        catch { registrationError = error.localizedDescription }
    }

    private func commit(_ preview: FlowRegistrationPreview) {
        do { try model.register(payload: payload, metadata: metadata, preview: preview); finished() }
        catch { registrationError = error.localizedDescription }
    }
}
