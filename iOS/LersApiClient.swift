import Foundation

actor LersCoordinator {
    private var token: String?
    private var baseUrl: String = ""
    private var session: URLSession
    
    // Семафор/ограничение параллельных опросов (в C# SemaphoreSlim(6))
    private let maxConcurrentPolls = 4
    private var runningPolls = 0
    private var pollQueue: [CheckedContinuation<Void, Never>] = []
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        self.session = URLSession(configuration: config)
    }
    
    func configure(host: String, port: Int) {
        self.baseUrl = "http://\(host):\(port)/api/v1"
    }
    
    // MARK: Авторизация
    func login(login: String, pass: String) async throws -> String {
        guard let url = URL(string: "\(baseUrl)/Login") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload: [String: String] = ["login": login, "password": pass, "application": "LersMonitor iOS"]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "AuthError", code: 401, userInfo: [NSLocalizedDescriptionKey: "Ошибка авторизации"])
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tok = json["token"] as? String {
            self.token = tok
            return tok
        } else if let tok = String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\r")) {
            self.token = tok
            return tok
        }
        throw NSError(domain: "TokenError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Не удалось прочесть токен"])
    }
    
    private func authRequest(url: URL, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let t = token {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        return req
    }
    
    // MARK: Загрузка точек учета
    func fetchMeasurePoints() async throws -> [MeasurePointItem] {
        guard let url = URL(string: "\(baseUrl)/Core/MeasurePoints?type=Regular&getCustomers=true") else { return [] }
        let (data, _) = try await session.data(for: authRequest(url: url))
        
        var points: [MeasurePointItem] = []
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        
        let array: [[String: Any]]
        if let arr = json as? [[String: Any]] { array = arr }
        else if let dict = json as? [String: Any], let arr = dict["measurePoints"] as? [[String: Any]] { array = arr }
        else { return [] }
        
        for item in array {
            guard let id = item["id"] as? Int else { continue }
            let title = (item["title"] as? String) ?? "Точка"
            let nodeTitle = (item["nodeTitle"] as? String) ?? "Объект"
            points.append(MeasurePointItem(id: id, title: title, nodeTitle: nodeTitle))
        }
        return points.sorted { ($0.nodeTitle, $0.title) < ($1.nodeTitle, $1.title) }
    }
    
    // MARK: Опрос точки (Post Poll + чтение Consumption/Last + Disconnect)
    func pollPoint(pointId: Int) async throws -> [String: Any]? {
        await acquirePollSlot()
        defer { releasePollSlot() }
        
        // 1. Инициируем опрос прибора
        if let pollUrl = URL(string: "\(baseUrl)/Poll/MeasurePoints/\(pointId)/Currents?once=true") {
            var req = authRequest(url: pollUrl, method: "POST")
            req.httpBody = Data()
            _ = try? await session.data(for: req)
        }
        
        // Ожидание ответа устройства (до 20 сек циклом)
        var lastResult: [String: Any]? = nil
        if let lastUrl = URL(string: "\(baseUrl)/Data/MeasurePoints/\(pointId)/Consumption/Last") {
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                let (data, res) = try await session.data(for: authRequest(url: lastUrl))
                if (res as? HTTPURLResponse)?.statusCode == 200,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    lastResult = json
                    break
                }
            }
        }
        
        // 2. Освобождаем канал (Disconnect)
        if let disconUrl = URL(string: "\(baseUrl)/Poll/MeasurePoints/\(pointId)/Disconnect") {
            var req = authRequest(url: disconUrl, method: "POST")
            req.httpBody = Data()
            _ = try? await session.data(for: req)
        }
        
        return lastResult
    }
    
    private func acquirePollSlot() async {
        if runningPolls < maxConcurrentPolls {
            runningPolls += 1
            return
        }
        await withCheckedContinuation { cont in
            pollQueue.append(cont)
        }
    }
    
    private func releasePollSlot() {
        if !pollQueue.isEmpty {
            let next = pollQueue.removeFirst()
            next.resume()
        } else {
            runningPolls = max(0, runningPolls - 1)
        }
    }
}
