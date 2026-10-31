import Foundation

@MainActor
final class IPMonitor: ObservableObject {
    static let intervalKey = "checkInterval"
    private static let sourcesKey = "ipSources.v1"
    private static let rotationIndexKey = "sourceRotationIndex"

    @Published private(set) var ipv4 = "Определяется…"
    @Published private(set) var status = "Подготовка"
    @Published private(set) var isChecking = false
    @Published var isFlashing = false
    @Published private(set) var sources: [IPSource]
    @Published private(set) var sourceResults: [UUID: String] = [:]

    var onAddressChange: ((_ oldAddress: String, _ newAddress: String) -> Void)?

    private var knownIPv4: String?
    private var timer: Timer?
    private var requestTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.sourcesKey),
           let saved = try? JSONDecoder().decode([IPSource].self, from: data),
           !saved.isEmpty {
            sources = saved
        } else {
            sources = IPSource.defaults
        }
    }

    var interval: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: Self.intervalKey)
        return stored > 0 ? stored : 30
    }

    func start() {
        scheduleTimer()
        checkNow()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        requestTask?.cancel()
        flashTask?.cancel()
    }

    func updateInterval(_ seconds: TimeInterval) {
        UserDefaults.standard.set(seconds, forKey: Self.intervalKey)
        scheduleTimer()
        status = "Интервал обновлён"
    }

    func restore(sources restoredSources: [IPSource], interval: Double) {
        sources = restoredSources.isEmpty ? IPSource.defaults : restoredSources
        saveSources()
        updateInterval(interval > 0 ? interval : 30)
        checkNow()
    }

    @discardableResult
    func addSource(name: String, urlString: String) -> String? {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            return "Введите полный адрес, начинающийся с https:// или http://"
        }
        guard !sources.contains(where: { $0.url.caseInsensitiveCompare(trimmedURL) == .orderedSame }) else {
            return "Такой источник уже добавлен"
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = IPSource(
            id: UUID(),
            name: trimmedName.isEmpty ? (url.host ?? "Свой источник") : trimmedName,
            url: trimmedURL,
            isEnabled: true,
            isBuiltIn: false
        )
        sources.append(source)
        saveSources()
        checkNow()
        return nil
    }

    func removeSource(_ source: IPSource) {
        guard !source.isBuiltIn else { return }
        sources.removeAll { $0.id == source.id }
        sourceResults[source.id] = nil
        saveSources()
        checkNow()
    }

    func setSourceEnabled(_ source: IPSource, enabled: Bool) {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[index].isEnabled = enabled
        saveSources()
        checkNow()
    }

    func checkNow() {
        guard !isChecking else { return }
        requestTask?.cancel()
        requestTask = Task { [weak self] in
            guard let self else { return }
            self.isChecking = true
            self.status = "Проверка…"

            let enabledSources = self.sources.filter(\.isEnabled)
            guard !enabledSources.isEmpty else {
                self.isChecking = false
                self.status = "Нет включённых источников"
                if self.knownIPv4 == nil { self.ipv4 = "Недоступен" }
                return
            }

            let storedIndex = UserDefaults.standard.integer(forKey: Self.rotationIndexKey)
            let startIndex = storedIndex % enabledSources.count
            UserDefaults.standard.set((startIndex + 1) % enabledSources.count, forKey: Self.rotationIndexKey)
            let orderedSources = Array(enabledSources[startIndex...]) + Array(enabledSources[..<startIndex])

            var selectedAddress: String?
            var selectedSourceName: String?
            for source in orderedSources {
                let outcome = await Self.fetchAddress(from: source.url)
                guard !Task.isCancelled else { return }
                switch outcome {
                case .success(let address):
                    self.sourceResults[source.id] = address
                    selectedAddress = address
                    selectedSourceName = source.name
                case .failure:
                    self.sourceResults[source.id] = "Ошибка"
                }
                if selectedAddress != nil { break }
            }

            guard !Task.isCancelled else { return }
            if let selected = selectedAddress {
                self.apply(.success(selected))
                self.status = "\(selectedSourceName ?? "Источник") · \(Self.timeFormatter.string(from: Date()))"
            } else {
                self.apply(.failure)
                self.status = "Все источники недоступны"
            }
            self.isChecking = false
        }
    }

    func flash() {
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<10 {
                guard !Task.isCancelled else { break }
                self.isFlashing.toggle()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            self.isFlashing = false
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkNow() }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func apply(_ outcome: FetchOutcome) {
        switch outcome {
        case .success(let address):
            let previous = knownIPv4
            knownIPv4 = address
            ipv4 = address
            if let previous, previous != address {
                onAddressChange?(previous, address)
            }
        case .failure:
            if knownIPv4 == nil { ipv4 = "Недоступен" }
        }
    }

    private func saveSources() {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        UserDefaults.standard.set(data, forKey: Self.sourcesKey)
    }

    private nonisolated static func fetchAddress(from urlString: String) async -> FetchOutcome {
        guard let url = URL(string: urlString) else { return .failure }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let address = extractIPv4(from: data) else {
                return .failure
            }
            return .success(address)
        } catch {
            return .failure
        }
    }

    private nonisolated static func extractIPv4(from data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = object["ip"] as? String,
           isIPv4(value) {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: .newlines) {
            let candidate: String
            if line.hasPrefix("ip=") {
                candidate = String(line.dropFirst(3))
            } else {
                candidate = line
            }
            if isIPv4(candidate) {
                return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private nonisolated static func isIPv4(_ value: String) -> Bool {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, let number = Int(part) else { return false }
            return (0...255).contains(number)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter
    }()
}

private enum FetchOutcome: Sendable {
    case success(String)
    case failure
}
