import AppKit
import CoreImage
import SwiftUI

struct ClientQRSView: View {
    let connection: ClientConnection
    let mainJSON: String
    let domainRules: [DomainRouteRule]

    @Environment(\.dismiss) private var dismiss
    @State private var frames: [String] = []
    @State private var currentImage: NSImage?
    @State private var currentIndex = 0
    @State private var tick = 0
    @State private var framesPerSecond = 5
    @State private var paused = false
    @State private var errorMessage: String?
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    private static let qrContext = CIContext()

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Передать в sing-box для Android").font(.headline)
                    Text(connection.name).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Закрыть") { dismiss() }
            }
            if let errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "qrcode").font(.largeTitle)
                    Text("Не удалось создать QRS").font(.headline)
                    Text(errorMessage).foregroundStyle(.secondary)
                }
                .frame(height: 470)
            } else if currentImage == nil {
                ProgressView("Подготовка QR…").frame(height: 470)
            } else {
                Image(nsImage: currentImage!)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 460, height: 460)
                    .padding(12)
                    .background(.white)
                    .accessibilityLabel("Кадр QRS \(currentIndex + 1) из \(frames.count)")
                HStack {
                    Text("Кадр \(currentIndex + 1) / \(frames.count)")
                        .font(.caption.monospacedDigit())
                    Spacer()
                    Picker("Скорость", selection: $framesPerSecond) {
                        Text("2 кадра/с").tag(2)
                        Text("5 кадров/с").tag(5)
                        Text("10 кадров/с").tag(10)
                    }
                    .frame(width: 180)
                    Button(paused ? "Продолжить" : "Пауза") { paused.toggle() }
                }
                Text("В sing-box для Android 1.13+ откройте сканер QR и наведите камеру на экран Mac. Держите окно открытым до завершения импорта.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("QR содержит данные доступа к серверу. Показывайте его только своему устройству.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(20)
        .frame(width: 535)
        .onAppear(perform: prepare)
        .onReceive(timer) { _ in
            guard !paused, frames.count > 1 else { return }
            tick += 1
            if tick >= 10 / framesPerSecond {
                tick = 0
                let next = (currentIndex + 1) % frames.count
                do {
                    currentImage = try Self.makeQR(frames[next])
                    currentIndex = next
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func prepare() {
        do {
            let config = try ClientQRS.androidConfiguration(connection: connection, mainJSON: mainJSON,
                                                             domainRules: domainRules)
            let profile = try ClientQRS.profileData(name: connection.name, config: config)
            frames = try ClientQRS.frames(profileData: profile)
            currentImage = try Self.makeQR(frames[0])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func makeQR(_ content: String) throws -> NSImage {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw ClientQRSError.invalidData }
        filter.setValue(Data(content.utf8), forKey: "inputMessage")
        filter.setValue("L", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { throw ClientQRSError.invalidData }
        let scale = max(1, Int(650 / output.extent.width))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        guard let image = qrContext.createCGImage(scaled, from: scaled.extent) else {
            throw ClientQRSError.invalidData
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
