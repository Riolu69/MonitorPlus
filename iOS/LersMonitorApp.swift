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
                if !vm.settings.hidePodpitka {
                    PodpitkaView(vm: vm)
                        .tabItem { Label("Подпитка", systemImage: "drop") }
                }
                SettingsView(vm: vm)
                    .tabItem { Label("Настройки", systemImage: "gearshape") }
            }
            .tint(.blue)
        }
    }
}

// MARK: - Settings View (Apple-style Form)
struct SettingsView: View {
    @Bindable var vm: AppViewModel
    @State private var rawPassword: String = ""
    @State private var isConnecting: Bool = false
    @State private var showPassword: Bool = false
    @State private var showATSDiagnostics: Bool = false
    @State private var atsInfo: String = ""

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Connection
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
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        isConnecting = true
                        vm.savePassword(rawPassword)
                        Task {
                            await vm.connect()
                            isConnecting = false
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if isConnecting {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text(vm.isConnected ? "Переподключиться" : "Подключиться")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(isConnecting)
                } header: {
                    Text("Подключение к ЛЭРС УЧЁТ")
                } footer: {
                    Text("Адрес сервера ЛЭРС УЧЁТ, порт API (по умолчанию 10000), логин и пароль учётной записи.")
                }

                // MARK: - Connection status
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
                        }
                    }
                }

                // MARK: - Outdoor temperature sensor
                Section {
                    Picker("Источник Тнв", selection: $vm.settings.tnvSourcePointId) {
                        Text("Не выбран").tag(nil as Int?)
                        ForEach(vm.allPoints) { pt in
                            Text(pt.displayName).tag(pt.id as Int?)
                        }
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
                } header: {
                    Text("Датчик наружного воздуха")
                } footer: {
                    Text("Выберите точку учёта, данные которой используются как температура наружного воздуха (Тнв) для расчёта температурного графика.")
                }

                // MARK: - Tab visibility
                Section("Видимость вкладок") {
                    Toggle("Дашборд", isOn: Binding(get: { !vm.settings.hideDashboard }, set: { vm.settings.hideDashboard = !$0 }))
                    Toggle("Точки учёта", isOn: Binding(get: { !vm.settings.hideGeneral }, set: { vm.settings.hideGeneral = !$0 }))
                    Toggle("Подпитка", isOn: Binding(get: { !vm.settings.hidePodpitka }, set: { vm.settings.hidePodpitka = !$0 }))
                }

                // MARK: - Credentials
                Section {
                    Toggle("Запоминать пароль", isOn: $vm.settings.rememberCredentials)
                } header: {
                    Text("Безопасность")
                } footer: {
                    Text(vm.settings.rememberCredentials
                         ? "Пароль хранится в Keychain — защищённом хранилище iOS."
                         : "Пароль не сохраняется. Введите его при каждом подключении.")
                }

                // MARK: - Diagnostics
                Section {
                    Button("Показать настройки сети (ATS)") {
                        atsInfo = AppViewModel.atsDiagnostics()
                        showATSDiagnostics = true
                    }
                } header: {
                    Text("Диагностика")
                } footer: {
                    Text("Проверяет, разрешено ли приложению обращаться к серверу по HTTP (незашифрованному) протоколу.")
                }
            }
            .navigationTitle("Настройки")
            .alert("Настройки ATS", isPresented: $showATSDiagnostics) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(atsInfo)
            }
            .onAppear {
                if rawPassword.isEmpty {
                    rawPassword = vm.loadPassword()
                }
            }
            .onChange(of: vm.settings.rememberCredentials) { _, _ in
                if !vm.settings.rememberCredentials {
                    KeychainHelper.deletePassword()
                    rawPassword = ""
                }
            }
        }
    }

    private var statusIcon: String {
        if vm.isConnected { return "checkmark.circle.fill" }
        if vm.statusText.contains("Ошибка") || vm.statusText.contains("Сбой") { return "exclamationmark.triangle.fill" }
        return "circle.dotted"
    }

    private var statusColor: Color {
        if vm.isConnected { return .green }
        if vm.statusText.contains("Ошибка") || vm.statusText.contains("Сбой") { return .red }
        return .orange
    }
}
