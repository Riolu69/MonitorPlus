import SwiftUI

public struct PollLogSheetView: View {
    let pointId: Int
    let pointTitle: String
    let coordinator: LersCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [PollLogEntry] = []
    
    public var body: some View {
        NavigationStack {
            List(entries) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(stateColor(entry.state))
                        .frame(width: 8, height: 8)
                        .padding(.top, 5)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text("[\(entry.phase)]")
                                .font(.caption2.bold())
                                .foregroundStyle(.blue)
                        }
                        Text(entry.message)
                            .font(.system(.footnote, design: .monospaced))
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Ход опроса: \(pointTitle)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Очистить") {
                        Task {
                            await coordinator.clearLogs(pointId: pointId)
                            entries = []
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .task {
                while !Task.isCancelled {
                    self.entries = await coordinator.getLogs(pointId: pointId)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }
    
    private func stateColor(_ st: PollState) -> Color {
        switch st {
        case .ok, .okCached: return .green
        case .error: return .red
        case .polling: return .orange
        default: return .gray
        }
    }
}
