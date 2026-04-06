import SwiftUI

/// Subtle performance info in the status bar corner.
/// Always dim — no alarming colors. Click to expand details.
struct PerformanceOverlay: View {
    @ObservedObject var monitor: PerformanceMonitor
    @State private var expanded = false
    @Environment(\.colorScheme) var colorScheme

    private var dimColor: Color {
        .secondary.opacity(0.5)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            // Compact badge — subtle, no color coding
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }) {
                Text("\(formatMB(monitor.memoryMB))  \(formatCPU(monitor.cpuPercent))")
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundColor(dimColor)
            }
            .buttonStyle(.plain)
            .help("Memory & CPU — click for details")

            // Expanded detail panel
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    row(label: "Footprint", value: formatMB(monitor.memoryMB))
                    row(label: "RSS", value: formatMB(monitor.residentMB))
                    row(label: "Peak", value: formatMB(monitor.peakMemoryMB))
                    row(label: "CPU", value: formatCPU(monitor.cpuPercent))

                    Divider()

                    Button(action: { monitor.resetPeak() }) {
                        Label("Reset Peak", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
                .padding(10)
                .frame(width: 160)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(colorScheme == .dark
                              ? Color(nsColor: .controlBackgroundColor)
                              : Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(.secondary)
        }
    }

    private func formatMB(_ mb: Double) -> String {
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }

    private func formatCPU(_ pct: Double) -> String {
        String(format: "%.0f%%", pct)
    }
}
