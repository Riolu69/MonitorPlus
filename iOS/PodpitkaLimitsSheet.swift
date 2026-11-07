import SwiftUI

/// Редактор границ объёмов подпитки (порт OverlayPodpitkaLimits из WPF).
public struct PodpitkaLimitsSheet: View {
    @Bindable var vm: AppViewModel
    let pointId: Int
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var limits = VolumeThresholds()

    public init(vm: AppViewModel, pointId: Int, title: String) {
        self.vm = vm
        self.pointId = pointId
        self.title = title
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    limitRow("Отчётный", min: $limits.reportMin, max: $limits.reportMax)
                    limitRow("Вчера", min: $limits.dayMin, max: $limits.dayMax)
                    limitRow("Сегодня", min: $limits.todayMin, max: $limits.todayMax)
                    limitRow("Прошлый час", min: $limits.hourMin, max: $limits.hourMax)
                } header: {
                    Text("Границы объёма, м³")
                } footer: {
                    Text("Оставьте поле пустым, если граница не контролируется. Выход за границы подсвечивается красным на карточке точки.")
                }

                Section {
                    Text(title)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Сбросить границы", role: .destructive) {
                        limits = VolumeThresholds()
                    }
                } header: {
                    Text("Точка учёта")
                }
            }
            .navigationTitle("Границы подпитки")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                limits = vm.settings.podpitkaLimits[pointId] ?? VolumeThresholds()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        vm.setPodpitkaLimits(limits, for: pointId)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private func limitRow(_ label: String, min: Binding<Double?>, max: Binding<Double?>) -> some View {
        HStack {
            Text(label)
                .frame(width: 100, alignment: .leading)
            TextField("Мин", value: min, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
            Text("—")
                .foregroundStyle(.secondary)
            TextField("Макс", value: max, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
        }
    }
}
