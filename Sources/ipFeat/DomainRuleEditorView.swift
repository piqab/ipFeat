import SwiftUI

struct DomainRuleEditorView: View {
    let availableTags: [String]
    let routeNames: [String: String]
    let onSave: (DomainRouteRule) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DomainRouteRule
    @State private var errorMessage = ""

    init(rule: DomainRouteRule, availableTags: [String], routeNames: [String: String],
         onSave: @escaping (DomainRouteRule) throws -> Void) {
        self.availableTags = availableTags
        self.routeNames = routeNames
        self.onSave = onSave
        _draft = State(initialValue: rule)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Domain route").font(.title2.weight(.semibold))
            TextField("*.example.com", text: $draft.pattern)
                .textFieldStyle(.roundedBorder)
            Text("Use an exact name such as example.com or a subdomain mask such as *.example.com. The mask does not include example.com itself.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Route", selection: $draft.outboundTag) {
                ForEach(availableTags, id: \.self) { tag in
                    Text(routeNames[tag] ?? tag).tag(tag)
                }
            }
            Toggle("Enabled", isOn: $draft.enabled)
            if !errorMessage.isEmpty { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    do {
                        draft.pattern = draft.normalizedPattern
                        try onSave(draft)
                        dismiss()
                    } catch { errorMessage = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}
