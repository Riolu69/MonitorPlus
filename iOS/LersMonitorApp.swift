import SwiftUI

@main
struct LersMonitorApp: App {
    @State private var vm = AppViewModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                if !vm.settings.hideDashboard {
                    DashboardView(vm: vm)
                        .tabItem { Label("Дашборд", systemImage: "square.grid.2x2") }
                }
                if !vm.settings.hideGeneral {
                    GeneralMonitorView(vm: vm)
                        .tabItem { Label("Точки", systemImage: "list.bullet") }
                }
                if !vm.settings.hideTrend {
                    TrendView(vm: vm)
                        .tabItem { Label("Тренд", systemImage: "chart.xyaxis.line") }
                }
                if !vm.settings.hidePodpitka {
                    PodpitkaView(vm: vm)
                        .tabItem { Label("Подпитка", systemImage: "drop") }
                }
                if !vm.settings.hideArchive {
                    ArchiveView(vm: vm)
                        .tabItem { Label("Архив", systemImage: "archivebox") }
                }
                SettingsView(vm: vm)
                    .tabItem { Label("Настройки", systemImage: "gearshape") }
            }
            .tint(.blue)
        }
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @Bindable var vm: AppViewModel
    @State private var rawPassword: String = ""
    @State private var isConnecting: Bool = false
    @State private var showPassword: Bool = false
    @State private var showATSDiagnostics: Bool = false
    @State private var atsInfo: String = ""

    init(vm: AppViewModel) {
        self.vm = vm
    }

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                statusSection
                tnvSection
                schedulerSection
                reportPeriodSection
                tabVisibilitySection
                securitySection
                diagnosticsSection
            }
            .navigationTitle("Настройки")
            .alert("Настройки ATS", isPresented: $showATSDiagnostics) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(atsInfo)
            }
            .onAppear {
                if rawPassword.isEmpty { rawPassword = vm.loadPassword() }
            }
            .onChange(of: vm.settings.rememberCredentials) { _, newValue in
                if !newValue {
                    KeychainHelper.deletePassword()
                    rawPassword = ""
                }
            }
            .onChange(of: vm.settings) { _, _ in
                vm.saveSettings()
            }
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section {
            TextField("Сервер (IP или домен)", text: $vm.settings.host)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)

            HStack {
                Text("Порт")
                Spacer()
                TextField("10000", value: $vm.settings.port, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }

            TextField("Логин", text: $vm.settings.login)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            HStack {
                if showPassword {
                    TextField("Пароль", text: $rawPassword)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } else {
                    SecureField("Пароль", text: $rawPassword)
                }
                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Button {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                to: nil, from: nil, for: nil)
                isConnecting = true
                vm.savePassword(rawPassword)
                Task {
                    await vm.connect()
                    isConnecting = false
                }
            } label: {
                HStack {
                    Spacer()
                    if isConnecting { ProgressView().padding(.trailing, 8) }
                    Text(vm.isConnected ? "Переподключиться" : "Подключиться")
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
            .disabled(isConnecting)
        } header: {
            Text("Подключение к ЛЭРС УЧЁТ")
        } footer: {
            Text("Адрес сервера, порт API (по умолчанию 10000), логин и пароль. Соединение выполняется по HTTP, ATS-исключения заданы в Info.plist.")
        }
    }

    private var statusSection: some View {
        Section("Статус подключения") {
            HStack(spacing: 10) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.isConnected ? "Подключено" : "Не подключено")
                        .font(.subheadline.weight(.medium))
                    Text(vm.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Точек загружено: \(vm.allPoints.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Outdoor temperature

    private var tnvSection: some View {
        Section {
            Picker("Источник Тнв", selection: $vm.settings.tnvSourcePointId) {
                Text("Не выбран").tag(nil as Int?)
                ForEach(vm.allPoints) { pt in
                    Text(pt.displayName).tag(pt.id as Int?)
                }
            }
            .onChange(of: vm.settings.tnvSourcePointId) { _, _ in
                Task { await vm.updateGlobalTnv() }
            }

            HStack {
                Text("Поправка датчика")
                Spacer()
                TextField("0.0", value: $vm.settings.tnvCorrection, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                Text("°C")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Текущее Тнв")
                Spacer()
                Text(vm.globalTnv != nil ? String(format: "%.1f °C", vm.globalTnv!) : "—")
                    .font(.subheadline.weight(.medium))
            }
            Text(vm.globalTnvStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Датчик наружного воздуха")
        } footer: {
            Text("Тнв используется для расчёта ожидаемых T1/T2 по температурному графику. Источник опрашивается раз в минуту.")
        }
    }

    // MARK: - Schedulers

    private var schedulerSection: some View {
        Section {
            Picker("Дашборд", selection: $vm.settings.dashboardIntervalMin) {
                ForEach([1, 5, 10, 15, 30, 60], id: \.self) { min in
                    Text("\(min) мин").tag(min)
                }
            }
            Picker("Подпитка", selection: $vm.settings.podpitkaIntervalMin) {
                ForEach([5, 10, 15, 30, 60], id: \.self) { min in
                    Text("\(min) мин").tag(min)
                }
            }
            Picker("Длительность тренда", selection: $vm.settings.trendDurationMin) {
                ForEach([1, 3, 5, 10, 15], id: \.self) { min in
                    Text("\(min) мин").tag(min)
                }
            }
        } header: {
            Text("Интервалы автоопроса")
        } footer: {
            Text("Планировщики запускаются из меню дашборда и подпитки. Интервал можно менять во время работы.")
        }
    }

    private var reportPeriodSection: some View {
        Section {
            Stepper(value: $vm.settings.reportPeriodStartDay, in: 1...31) {
                HStack {
                    Text("Начало отчётного периода")
                    Spacer()
                    Text("\(vm.settings.reportPeriodStartDay) число")
                        .foregroundStyle(.secondary)
                }
            }
            Stepper(value: $vm.settings.reportPeriodEndDay, in: 1...31) {
                HStack {
                    Text("Окончание")
                    Spacer()
                    Text("\(vm.settings.reportPeriodEndDay) число")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Отчётный период подпитки")
        } footer: {
            Text("По умолчанию 25 → 24: объём суммируется по суточному архиву за период с 25 числа прошлого месяца по 24 число текущего.")
        }
    }

    // MARK: - Tabs

    private var tabVisibilitySection: some View {
        Section("Видимость вкладок") {
            Toggle("Дашборд", isOn: Binding(get: { !vm.settings.hideDashboard },
                                            set: { vm.settings.hideDashboard = !$0 }))
            Toggle("Точки учёта", isOn: Binding(get: { !vm.settings.hideGeneral },
                                                set: { vm.settings.hideGeneral = !$0 }))
            Toggle("Тренд", isOn: Binding(get: { !vm.settings.hideTrend },
                                          set: { vm.settings.hideTrend = !$0 }))
            Toggle("Подпитка", isOn: Binding(get: { !vm.settings.hidePodpitka },
                                             set: { vm.settings.hidePodpitka = !$0 }))
            Toggle("Архив", isOn: Binding(get: { !vm.settings.hideArchive },
                                          set: { vm.settings.hideArchive = !$0 }))
        }
    }

    private var securitySection: some View {
        Section {
            Toggle("Запоминать пароль", isOn: $vm.settings.rememberCredentials)
        } header: {
            Text("Безопасность")
        } footer: {
            Text(vm.settings.rememberCredentials
                 ? "Пароль хранится в Keychain — защищённом хранилище iOS."
                 : "Пароль не сохраняется. Введите его при каждом подключении.")
        }
    }

    private var diagnosticsSection: some View {
        Section {
            Button("Показать настройки сети (ATS)") {
                atsInfo = AppViewModel.atsDiagnostics()
                showATSDiagnostics = true
            }
            Button("Проверить соединение") {
                Task { await vm.reconnectIfNeeded() }
            }
            Button("Остановить все автоопросы") {
                vm.stopAllSchedulers()
            }
        } header: {
            Text("Диагностика")
        } footer: {
            Text("Проверяет, разрешено ли приложению обращаться к серверу по HTTP. Все настройки сохраняются автоматически.")
        }
    }

    private var statusIcon: String {
        if vm.isConnected { return "checkmark.circle.fill" }
        if vm.statusText.contains("Ошибка") || vm.statusText.contains("Сбой") {
            return "exclamationmark.triangle.fill"
        }
        return "circle.dotted"
    }

    private var statusColor: Color {
        if vm.isConnected { return .green }
        if vm.statusText.contains("Ошибка") || vm.statusText.contains("Сбой") { return .red }
        return .orange
    }
}
