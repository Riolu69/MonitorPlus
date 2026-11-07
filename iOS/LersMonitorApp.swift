import SwiftUI

@main
struct LersMonitorApp: App {
    @State private var vm = AppViewModel()
    
    var body: some Scene {
        WindowGroup {
            TabView {
                if !vm.settings.hideDashboard {
                    DashboardView(vm: vm)
                        .tabItem { Label("Дашборд", systemImage: "square.grid.2x2.fill") }
                }
                if !vm.settings.hideGeneral {
                    GeneralMonitorView(vm: vm)
                        .tabItem { Label("Общий", systemImage: "list.bullet.rectangle") }
                }
                if !vm.settings.hidePodpitka {
                    PodpitkaView(vm: vm)
                        .tabItem { Label("Подпитка", systemImage: "drop.fill") }
                }
                SettingsView(vm: vm)
                    .tabItem { Label("Настройки", systemImage: "gearshape.fill") }
            }
        }
    }
}

struct SettingsView: View {
    @Bindable var vm: AppViewModel
    @State private var rawPassword: String = ""
    @State private var isConnecting: Bool = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Подключение к ЛЭРС УЧЁТ") {
                    TextField("Сервер (IP или домен)", text: $vm.settings.host)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    
                    HStack {
                        Text("Порт:")
                        Spacer()
                        TextField("10000", value: $vm.settings.port, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    
                    TextField("Логин", text: $vm.settings.login)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    
                    SecureField("Пароль", text: $rawPassword)
                    
                    Button {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        isConnecting = true
                        
                        if !rawPassword.isEmpty {
                            vm.settings.passwordBase64 = Data(rawPassword.utf8).base64EncodedString()
                        }
                        
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
                }
                
                Section("Статус подключения") {
                    HStack {
                        Circle()
                            .fill(vm.isConnected ? Color.green : (vm.statusText.contains("Ошибка") || vm.statusText.contains("Сбой") ? Color.red : Color.orange))
                            .frame(width: 10, height: 10)
                        Text(vm.statusText)
                            .font(.subheadline)
                            .foregroundStyle(vm.isConnected ? .primary : .secondary)
                    }
                }
                
                Section("Датчик наружного воздуха (Тнв)") {
                    Picker("Источник Тнв", selection: $vm.settings.tnvSourcePointId) {
                        Text("Не выбран").tag(nil as Int?)
                        ForEach(vm.allPoints) { pt in
                            Text(pt.displayName).tag(pt.id as Int?)
                        }
                    }
                    HStack {
                        Text("Поправка датчика:")
                        Spacer()
                        TextField("0.0", value: $vm.settings.tnvCorrection, format: .number)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                        Text("°C")
                    }
                }
                
                Section("Видимость вкладок") {
                    Toggle("Дашборд", isOn: Binding(get: { !vm.settings.hideDashboard }, set: { vm.settings.hideDashboard = !$0 }))
                    Toggle("Общий мониторинг", isOn: Binding(get: { !vm.settings.hideGeneral }, set: { vm.settings.hideGeneral = !$0 }))
                    Toggle("Подпитка", isOn: Binding(get: { !vm.settings.hidePodpitka }, set: { vm.settings.hidePodpitka = !$0 }))
                }
            }
            .navigationTitle("Настройки")
            .onAppear {
                if rawPassword.isEmpty, !vm.settings.passwordBase64.isEmpty {
                    if let data = Data(base64Encoded: vm.settings.passwordBase64),
                       let pass = String(data: data, encoding: .utf8) {
                        rawPassword = pass
                    }
                }
            }
        }
    }
}
