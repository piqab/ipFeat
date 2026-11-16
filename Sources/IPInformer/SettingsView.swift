import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var monitor: IPMonitor
    @ObservedObject var routingStore: RoutingStore
    @State private var selectedInterval: Double
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    @State private var sourceName = ""
    @State private var sourceURL = ""
    @State private var sourceError: String?
    @State private var showVPSGuide = false
    @State private var selectedTab: Int

    private let intervals: [(String, Double)] = [
        ("5 секунд", 5), ("10 секунд", 10), ("15 секунд", 15),
        ("30 секунд", 30), ("1 минута", 60), ("2 минуты", 120),
        ("5 минут", 300), ("10 минут", 600)
    ]

    init(monitor: IPMonitor, routingStore: RoutingStore, initialTab: Int = 0) {
        self.monitor = monitor
        self.routingStore = routingStore
        _selectedInterval = State(initialValue: monitor.interval)
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ipSettings
                .tabItem { Label("IP", systemImage: "network") }
                .tag(0)
            RoutingSettingsView(store: routingStore, section: .programs)
                .tabItem { Label("Программы", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(1)
            RoutingSettingsView(store: routingStore, section: .profiles)
                .tabItem { Label("Профили", systemImage: "slider.horizontal.3") }
                .tag(2)
            SingBoxSettingsView(store: routingStore, monitor: monitor)
                .tabItem { Label("sing-box", systemImage: "network.badge.shield.half.filled") }
                .tag(3)
            ProcessAISettingsView()
                .tabItem { Label("AI", systemImage: "questionmark.bubble") }
                .tag(4)
        }
        .frame(width: 820, height: 620)
        .onReceive(monitor.$sources) { _ in selectedInterval = monitor.interval }
        .onReceive(NotificationCenter.default.publisher(for: .ipInformerConfigurationRestored)) { _ in
            selectedInterval = monitor.interval
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private var ipSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Источники внешнего IPv4")
                    .font(.headline)
                Spacer()
                if monitor.isChecking { ProgressView().controlSize(.small) }
            }

            List {
                ForEach(monitor.sources) { source in
                    sourceRow(source)
                }
            }
            .frame(height: 190)
            .border(Color.secondary.opacity(0.2))

            HStack {
                TextField("Название", text: $sourceName)
                    .frame(width: 130)
                TextField("https://ip.example.com", text: $sourceURL)
                Button("Добавить") { addSource() }
                    .disabled(sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let sourceError {
                Text(sourceError).font(.caption).foregroundStyle(.red)
            }

            Divider()

            HStack {
                Picker("Проверять IP", selection: $selectedInterval) {
                    ForEach(intervals, id: \.1) { Text($0.0).tag($0.1) }
                }
                .frame(width: 260)
                .onChange(of: selectedInterval) { monitor.updateInterval($0) }

                Toggle("Автозапуск", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { updateLaunchAtLogin($0) }
            }

            if let launchError {
                Text(launchError).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Как настроить источник на VPS…") { showVPSGuide = true }
                Spacer()
                Text(monitor.status).font(.caption).foregroundStyle(.secondary)
                Button("Проверить сейчас") { monitor.checkNow() }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showVPSGuide) {
            VPSGuideView()
        }
    }

    private func sourceRow(_ source: IPSource) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { source.isEnabled },
                set: { monitor.setSourceEnabled(source, enabled: $0) }
            ))
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                Text(source.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
            Text(monitor.sourceResults[source.id] ?? "—")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(monitor.sourceResults[source.id] == "Ошибка" ? .red : .secondary)

            if !source.isBuiltIn {
                Button {
                    monitor.removeSource(source)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Удалить источник")
            }
        }
        .padding(.vertical, 3)
    }

    private func addSource() {
        sourceError = monitor.addSource(name: sourceName, urlString: sourceURL)
        if sourceError == nil {
            sourceName = ""
            sourceURL = ""
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = "Не удалось изменить автозапуск: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct VPSGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Свой источник IPv4 на VPS")
                .font(.title2.bold())
            Text("Создайте DNS-запись A для ip.example.com, направленную на IPv4 вашего VPS. Чтобы ответ всегда был IPv4, не добавляйте AAAA-запись для этого имени.")

            ScrollView {
                Text(Self.instructions)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            Text("После выпуска сертификата добавьте https://ip.example.com в список источников. Сервис должен возвращать IPv4 обычным текстом или JSON вида {\"ip\":\"203.0.113.10\"}.")
                .font(.callout)

            HStack {
                Spacer()
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 650, height: 500)
    }

    private static let instructions = """
    # Ubuntu / Debian
    sudo apt update
    sudo apt install nginx certbot python3-certbot-nginx

    # /etc/nginx/sites-available/ip-endpoint
    server {
        listen 80;
        server_name ip.example.com;

        access_log off;
        default_type text/plain;
        location / {
            return 200 "$remote_addr\\n";
        }
    }

    sudo ln -s /etc/nginx/sites-available/ip-endpoint \\
      /etc/nginx/sites-enabled/ip-endpoint
    sudo nginx -t
    sudo systemctl reload nginx
    sudo certbot --nginx -d ip.example.com

    # Проверка
    curl https://ip.example.com
    """
}
