import SwiftUI

public struct PodpitkaView: View {
    @Bindable var vm: AppViewModel

    public var body: some View {
        NavigationStack {
            Group {
                if !vm.isConnected {
                    ContentUnavailableView(
                        "Нет подключения",
                        systemImage: "wifi.slash",
                        description: Text("Подключитесь к серверу ЛЭРС УЧЁТ в настройках")
                    )
                } else if vm.podpitkaGroups.isEmpty {
                    ContentUnavailableView(
                        "Нет точек подпитки",
                        systemImage: "drop",
                        description: Text("Добавьте точки в список подпитки на вкладке «Точки учёта»")
                    )
                } else {
                    podpitkaContent
                }
            }
            .navigationTitle("Подпитка")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await vm.refreshPodpitka() }
                    } label: {
                        Label("Опросить", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private var podpitkaContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Period info banner
                HStack {
                    Image(systemName: "calendar")
                        .foregroundStyle(.secondary)
                    Text("Отчётный период: \(vm.settings.reportPeriodStartDay) → \(vm.settings.reportPeriodEndDay)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)

                ForEach(vm.podpitkaGroups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(group.nodeTitle)
                            .font(.headline)
                            .padding(.horizontal, 4)

                        ForEach(group.points) { pt in
                            PodpitkaCardView(pt: pt)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable {
            await vm.refreshPodpitka()
        }
    }
}

// MARK: - Podpitka card (Apple-style: system bg, red accent for breach)
struct PodpitkaCardView: View {
    let pt: PodpitkaPointData

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image(systemName: pt.hasBreach ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(pt.hasBreach ? .red : .green)
                    .font(.callout)
                Text(pt.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let updatedAt = pt.updatedAt {
                    Text(updatedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if !pt.message.isEmpty && pt.state != .ok {
                Text(pt.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Volume grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                VolumeCell(title: "Отчётный", value: pt.report, breach: pt.reportBreach)
                VolumeCell(title: "Вчера", value: pt.day, breach: pt.dayBreach)
                VolumeCell(title: "Сегодня", value: pt.today, breach: pt.todayBreach)
                VolumeCell(title: "Прошлый час", value: pt.hour, breach: pt.hourBreach)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topLeading) {
            if pt.hasBreach {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.red.opacity(0.3), lineWidth: 1)
            }
        }
    }
}

// MARK: - Volume cell (system background, not solid color fill)
struct VolumeCell: View {
    let title: String
    let value: Double?
    let breach: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value != nil ? String(format: "%.1f", value!) : "—")
                    .font(.body.weight(breach ? .bold : .regular))
                    .foregroundStyle(breach ? .red : .primary)
                Text("м³")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(breach ? Color.red.opacity(0.08) : Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}
