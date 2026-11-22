import AppKit
import SwiftUI

struct MenuBarPopoverView: View {
    private static let iconWidth: CGFloat = 36
    private static let iconSpacing: CGFloat = 8
    private static let visibleIconWidth: CGFloat = 5 * iconWidth + 4 * iconSpacing

    @ObservedObject var store: RoutingStore
    @State private var scrollOffsetsByRow: [String: CGFloat] = [:]
    let openSettings: () -> Void
    let addApplications: (UUID?) -> Void
    let quit: () -> Void
    let close: () -> Void

    init(store: RoutingStore, openSettings: @escaping () -> Void, addApplications: @escaping (UUID?) -> Void,
         quit: @escaping () -> Void,
         close: @escaping () -> Void) {
        self.store = store
        self.openSettings = openSettings
        self.addApplications = addApplications
        self.quit = quit
        self.close = close
    }

    private struct AppRow: Identifiable {
        let id: String
        let groupID: UUID?
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
            return AppRow(id: group.id.uuidString, groupID: group.id, name: group.name,
                          color: group.color.menuColor, applications: members)
        }
        let groupIDs = Set(store.configuration.groups.map(\.id))
        let ungrouped = applications.filter { application in
            guard let groupID = application.groupID else { return true }
            return !groupIDs.contains(groupID)
        }
        if !ungrouped.isEmpty {
            result.append(AppRow(id: "ungrouped", groupID: nil, name: "Без группы", color: .gray,
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

            actionRow("Настройки…", systemImage: "gearshape") {
                close()
                openSettings()
            }
            Divider().padding(.vertical, 5)
            actionRow("Завершить ipFeat", systemImage: "power") {
                close()
                quit()
            }
        }
        .padding(10)
        .frame(width: 340, height: Self.preferredHeight(rowCount: rows.count))
    }

    static func preferredHeight(rowCount: Int) -> CGFloat {
        96 + (rowCount == 0 ? 0 : CGFloat(min(rowCount, 6)) * 48 + 17)
    }

    private func applicationRow(_ row: AppRow) -> some View {
        let contentWidth = CGFloat(row.applications.count) * Self.iconWidth
            + CGFloat(max(0, row.applications.count - 1)) * Self.iconSpacing
        let maximumOffset = max(0, contentWidth - Self.visibleIconWidth)
        let offset = min(scrollOffsetsByRow[row.id] ?? 0, maximumOffset)

        return HStack(spacing: 4) {
            if maximumOffset > 0 {
                Button { scrollOffsetsByRow[row.id] = max(0, offset - Self.visibleIconWidth) } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 22, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(offset < 1)
                .help("Предыдущие программы: \(row.name)")
                .accessibilityLabel("Предыдущие программы: \(row.name)")
            }

            HorizontalWheelScrollView(
                contentWidth: contentWidth,
                offset: Binding(
                    get: { scrollOffsetsByRow[row.id] ?? 0 },
                    set: { scrollOffsetsByRow[row.id] = $0 }
                )
            ) {
                HStack(spacing: Self.iconSpacing) {
                    ForEach(row.applications) { application in
                        ApplicationMenuIconButton(
                            application: application,
                            groups: store.configuration.groups,
                            action: {
                                store.launch(application)
                                close()
                            },
                            onMove: { groupID in
                                guard var current = store.configuration.applications.first(where: { $0.id == application.id }) else { return }
                                current.groupID = groupID
                                store.updateApplication(current)
                                close()
                            },
                            onDelete: {
                                guard let current = store.configuration.applications.first(where: { $0.id == application.id }) else { return }
                                store.removeApplication(current)
                                close()
                            }
                        )
                        .frame(width: Self.iconWidth, height: 36)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)

            if maximumOffset > 0 {
                Button { scrollOffsetsByRow[row.id] = min(maximumOffset, offset + Self.visibleIconWidth) } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 22, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(offset >= maximumOffset - 1)
                .help("Следующие программы: \(row.name)")
                .accessibilityLabel("Следующие программы: \(row.name)")
            }

            Button { addApplications(row.groupID) } label: {
                VStack(spacing: 0) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(height: 23)
                    Text("\(row.applications.count)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                }
                .frame(width: 36, height: 36)
                .background(row.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .frame(width: 36, height: 36)
            .help("Добавить программы: \(row.name)")
            .accessibilityLabel("Добавить программы: \(row.name)")
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background(row.color.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(row.color)
                .frame(width: 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.name), программ: \(row.applications.count)")
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
