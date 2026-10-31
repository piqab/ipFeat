import SwiftUI

struct WidgetView: View {
    @ObservedObject var monitor: IPMonitor

    var body: some View {
        Text(monitor.ipv4)
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .lineLimit(1)
            .foregroundStyle(monitor.isFlashing ? Color.orange : Color.primary)
            .shadow(color: Color(nsColor: .windowBackgroundColor).opacity(0.95), radius: 2)
            .frame(width: 146, height: 28)
            .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.18), value: monitor.isFlashing)
    }

}
