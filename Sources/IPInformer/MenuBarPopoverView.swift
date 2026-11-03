import AppKit
import SwiftUI

struct MenuBarPopoverView: View {
    @ObservedObject var store: RoutingStore
    @State private var widgetsVisible: Bool
    let checkNow: () -> Void
    let toggleWidgets: () -> Void
    let openSettings: () -> Void
    let quit: () -> Void
    let close: () -> Void

    init(store: RoutingStore, widgetsVisible: Bool,
         checkNow: @escaping () -> Void, toggleWidgets: @escaping () -> Void,
         openSettings: @escaping () -> Void, quit: @escaping () -> Void,
         close: @escaping () -> Void) {
        self.store = store
        _widgetsVisible = State(initialValue: widgetsVisible)
        self.checkNow = checkNow
        self.toggleWidgets = toggleWidgets
        self.openSettings = openSettings
        self.quit = quit
        self.close = close
    }

    private struct AppRow: Identifiable {
        let id: String
        let name: String
        let color: Color
        let applications: [RoutedApplication]
    }

    private var rows: [AppRow] {
        let applications = store.configuration.applications.filter {
            $0.bundleIdentifier != RoutingStore.selfBundleIdentifier
        }
        var result = store.configuration.groups.compactMap { group -> AppRow? in
            let members = applications.filter { $0.groupID == group.id }
            guard !members.isEmpty else { return nil }
            return AppRow(id: group.id.uuidString, name: group.name,
                          color: group.color.menuColor, applications: members)
        }
        let groupIDs = Set(store.configuration.groups.map(\.id))
        let ungrouped = applications.filter { application in
            guard let groupID = application.groupID else { return true }
            return !groupIDs.contains(groupID)
        }
        if !ungrouped.isEmpty {
            result.append(AppRow(id: "ungrouped", name: "Без группы", color: .gray,
                                 applications: ungrouped))
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            if !rows.isEmpty {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 6) {
                        ForEach(rows) { row in applicationRow(row) }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: CGFloat(min(rows.count, 6)) * 48)
                Divider().padding(.vertical, 8)
            }

            actionRow("Проверить сейчас", systemImage: "arrow.clockwise") {
                checkNow()
                close()
            }
            actionRow(widgetsVisible ? "Скрыть виджеты" : "Показать виджеты",
                      systemImage: widgetsVisible ? "eye.slash" : "eye") {
                toggleWidgets()
                widgetsVisible.toggle()
            }
            actionRow("Настройки…", systemImage: "gearshape") {
                close()
                openSettings()
            }
            Divider().padding(.vertical, 5)
            actionRow("Завершить IP Informer", systemImage: "power") {
                close()
                quit()
            }
        }
        .padding(10)
        .frame(width: 340, height: Self.preferredHeight(rowCount: rows.count))
    }

    static func preferredHeight(rowCount: Int) -> CGFloat {
        164 + (rowCount == 0 ? 0 : CGFloat(min(rowCount, 6)) * 48 + 17)
    }

    private func applicationRow(_ row: AppRow) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(row.applications) { application in
                    Button {
                        store.launch(application)
                        close()
                    } label: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: application.bundlePath))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 30, height: 30)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .opacity(application.enabled ? 1 : 0.4)
                    .disabled(!application.enabled)
                    .help(application.name)
                    .accessibilityLabel(application.name)
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 42)
        .background(row.color.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(row.color)
                .frame(width: 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.name)
    }

    private func actionRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, minHeight: 29, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private extension RoutingGroupColor {
    var menuColor: Color {
        switch self {
        case .blue: return .blue
        case .green: return .green
        case .orange: return .orange
        case .purple: return .purple
        case .red: return .red
        case .teal: return .teal
        }
    }
}
