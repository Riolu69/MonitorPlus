import SwiftUI

public struct PodpitkaView: View {
    @Bindable var vm: AppViewModel
    
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    // Панель управления периодом и опросом
                    HStack {
                        Text("Период: \(vm.settings.reportPeriodStartDay)→\(vm.settings.reportPeriodEndDay)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Опросить архивы V1") {
                            Task { await vm.refreshPodpitka() }
                        }
                        .font(.footnote.bold())
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal)
                    
                    // Сетка карточек объектов
                    ForEach(vm.podpitkaGroups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.nodeTitle)
                                .font(.headline)
                                .padding(.horizontal, 4)
                            
                            ForEach(group.points) { pt in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(pt.title).font(.subheadline.bold())
                                        Spacer()
                                        Text(pt.message).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    
                                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                                        VolumeCell(title: "Отчётный V1", val: pt.report, breach: pt.reportBreach)
                                        VolumeCell(title: "Вчера V1", val: pt.day, breach: pt.dayBreach)
                                        VolumeCell(title: "Сегодня V1", val: pt.today, breach: pt.todayBreach)
                                        VolumeCell(title: "Прошлый час V1", val: pt.hour, breach: pt.hourBreach, format: "%.2f")
                                    }
                                }
                                .padding(10)
                                .background(Color(.secondarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Подпитка")
        }
    }
}

struct VolumeCell: View {
    let title: String
    let val: Double?
    let breach: Bool
    var format: String = "%.1f"
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9)).foregroundStyle(.white.opacity(0.8))
            Text(val != nil ? String(format: "\(format) м³", val!) : "—")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(breach ? .yellow : .white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(breach ? Color.red : Color.green)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
