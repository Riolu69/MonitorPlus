import SwiftUI

struct PointTileView: View {
    let point: PointResultData
    let currentTnv: Double?
    var onRetry: () -> Void
    
    private var tileBgColor: Color {
        if point.state == .error { return .orange }
        if point.hasAnyBreach(currentTnv: currentTnv) { return .red }
        if point.state == .ok || point.state == .okCached { return .green }
        return Color(.systemGray4)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Заголовок карточки
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(point.nodeTitle)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white.opacity(0.8))
                    Text(point.title)
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                }
                Spacer()
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            
            Divider().background(.white.opacity(0.3))
            
            // Основные параметры T1 / T2
            HStack(spacing: 12) {
                ParamValueView(label: "T1", value: point.t1, unit: "°C")
                ParamValueView(label: "T2", value: point.t2, unit: "°C")
                ParamValueView(label: "ΔT", value: point.deltaT, unit: "°C")
            }
            
            // Давление и расход P / V
            HStack(spacing: 12) {
                ParamValueView(label: "P1", value: point.p1, unit: "атм")
                ParamValueView(label: "V1", value: point.v1, unit: "м³/ч")
                ParamValueView(label: "Q", value: point.q, unit: "Гкал", format: "%.3f")
            }
            
            // Статус и время обновления
            Text(point.statusMessage)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
        .padding(12)
        .background(tileBgColor)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
    }
}

struct ParamValueView: View {
    let label: String
    let value: Double?
    let unit: String
    var format: String = "%.1f"
    
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            if let val = value {
                Text(String(format: "\(format) %@", val, unit))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Text("—")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}
