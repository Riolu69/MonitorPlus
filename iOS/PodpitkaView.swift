import SwiftUI

/// Подпитка: четыре объёма (отчётный период, вчера, сегодня, прошлый час),
/// автоопрос по расписанию, выбор точек и редактор границ.
public struct PodpitkaView: View {
    @Bindable var vm: AppViewModel
    @State private var showSelection = false
    @State private var limitsPoint: PodpitkaPointData?

    public init(vm: AppViewModel) {
        self.vm = vm
    }

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
                        description: Text("Выберите точки подпитки в меню «Ещё» или отметьте их в списке точек учёта")
                    )
                } else {
                    podpitkaContent
                }
            }
            .navigationTitle("Подпитка")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { schedulerMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await vm.refreshPodpitka() }
                    } label: {
                        Label("Опросить", systemImage: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showSelection) {
                PointSelectionSheet(vm: vm, list: .podpitka, title: "Точки подпитки")
            }
            .sheet(item: $limitsPoint) { pt in
                PodpitkaLimitsSheet(vm: vm, pointId: pt.id, title: "\(pt.nodeTitle) — \(pt.title)")
            }
        }
    }

    private var schedulerMenu: some View {
        Menu {
            if vm.isPodpitkaSchedulerRunning {
                Button(role: .destructive) {
                    vm.stopPodpitkaScheduler()
                } label: {
                    Label("Остановить автоопрос", systemImage: "stop.circle")
                }
            } else {
                Button {
                    vm.startPodpitkaScheduler()
                } label: {
                    Label("Запустить автоопрос", systemImage: "play.circle")
                }
            }
            Picker("Интервал", selection: $vm.settings.podpitkaIntervalMin) {
                ForEach([5, 10, 15, 30, 60], id: \.self) { min in
                    Text("\(min) мин").tag(min)
                }
            }
            Divider()
            Button {
                showSelection = true
            } label: {
                Label("Выбрать точки", systemImage: "checklist")
            }
        } label: {
            Image(systemName: vm.isPodpitkaSchedulerRunning ? "clock.badge.checkmark" : "ellipsis.circle")
        }
    }

    private var podpitkaContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                periodBanner
                ForEach(vm.podpitkaGroups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(group.nodeTitle)
                                .font(.headline)
                            Spacer()
                            Text(group.generalStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)

                        ForEach(group.points) { pt in
                            PodpitkaCardView(pt: pt, onLimits: { limitsPoint = pt })
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

    private var periodBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "calendar")
                    .foregroundStyle(.secondary)
                Text("Отчётный период: \(vm.settings.reportPeriodStartDay) → \(vm.settings.reportPeriodEndDay)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if vm.isPodpitkaSchedulerRunning, let next = vm.podpitkaNextRun {
                HStack {
                    Image(systemName: "clock")
                        .foregroundStyle(.green)
                    Text("Автоопрос каждые \(vm.settings.podpitkaIntervalMin) мин")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("след. \(next.formatted(date: .omitted, time: .shortened))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(vm.statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
}

// MARK: - Podpitka card
struct PodpitkaCardView: View {
    let pt: PodpitkaPointData
    var onLimits: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: pt.hasError
                      ? "exclamationmark.triangle.fill"
                      : (pt.hasBreach ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"))
                    .foregroundStyle(pt.hasError || pt.hasBreach ? .red : .green)
                    .font(.callout)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pt.title)
                        .font(.subheadline.weight(.semibold))
                    Text(pt.nodeTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let updatedAt = pt.updatedAt {
                    Text(updatedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button {
                    onLimits()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .accessibilityLabel("Границы объёмов")
            }

            if !pt.message.isEmpty && pt.state != .ok {
                Text(pt.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

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

// MARK: - Volume cell
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
        .background(breach ? Color.red.opacity(0.08) : Color(.tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}
