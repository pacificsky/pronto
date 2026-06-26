import Foundation

/// Errors surfaced to the UI.
enum LMError: LocalizedError {
    case auth
    case notSuccessful(status: Int, body: String)
    case network(String)
    case noMachines
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .auth:
            return "Invalid La Marzocco email or password."
        case .notSuccessful(let status, let body):
            return "Request failed (HTTP \(status)). \(body)"
        case .network(let msg):
            return "Network error: \(msg)"
        case .noMachines:
            return "No machines found on this account."
        case .decoding(let msg):
            return "Unexpected response: \(msg)"
        }
    }
}

/// A machine ("thing") on the account.
struct Machine: Codable, Identifiable, Hashable {
    let serialNumber: String
    var name: String = ""
    var modelName: String = ""

    var id: String { serialNumber }
    var displayName: String { name.isEmpty ? serialNumber : name }
}

/// Current power state of the machine, derived from the dashboard widget.
enum PowerState: Equatable {
    case on            // mode == BrewingMode
    case off           // mode == StandBy
    case other(String) // any other reported mode (e.g. brewing in progress)
    case unknown

    var isOn: Bool { if case .on = self { return true }; return false }
}

/// Talks to the La Marzocco customer-app cloud API. Mirrors the request flow in
/// `pylamarzocco`'s LaMarzoccoCloudClient: register installation → sign in →
/// authenticated REST calls signed per-request.
final class LMCloudClient {
    static let baseURL = "https://lion.lamarzocco.io/api/customer-app"

    private let key: InstallationKey
    private let username: String
    private let password: String
    private let session: URLSession

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date = .distantPast
    private(set) var registered: Bool

    init(key: InstallationKey, username: String, password: String, registered: Bool) {
        self.key = key
        self.username = username
        self.password = password
        self.registered = registered
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    // MARK: - Auth

    /// Register this installation's public key with the server (one-time).
    func register() async throws {
        var req = URLRequest(url: URL(string: "\(Self.baseURL)/auth/init")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key.installationId, forHTTPHeaderField: "X-App-Installation-Id")
        req.setValue(LMProof.requestProof(baseString: key.baseString, secret: key.secret),
                     forHTTPHeaderField: "X-Request-Proof")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["pk": key.publicKeyB64])
        _ = try await send(req)
        registered = true
    }

    private func signIn() async throws {
        try await fetchToken(path: "/auth/signin",
                             body: ["username": username, "password": password])
    }

    private func fetchToken(path: String, body: [String: String]) async throws {
        var req = URLRequest(url: URL(string: "\(Self.baseURL)\(path)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in LMProof.requestHeaders(for: key) { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["accessToken"] as? String else {
            throw LMError.decoding("missing accessToken")
        }
        accessToken = access
        refreshToken = obj["refreshToken"] as? String
        // Server tokens last ~1h; refresh a little early.
        tokenExpiry = Date().addingTimeInterval(50 * 60)
    }

    private func ensureToken() async throws {
        if !registered { try await register() }
        if accessToken == nil || Date() >= tokenExpiry {
            try await signIn()
        }
    }

    /// Validate credentials and return the machines on the account.
    func connect() async throws -> [Machine] {
        try await ensureToken()
        let machines = try await listThings()
        guard !machines.isEmpty else { throw LMError.noMachines }
        return machines
    }

    // MARK: - Endpoints

    func listThings() async throws -> [Machine] {
        let data = try await authed(path: "/things", method: "GET")
        do {
            return try JSONDecoder().decode([Machine].self, from: data)
        } catch {
            throw LMError.decoding("things: \(error.localizedDescription)")
        }
    }

    func powerState(serial: String) async throws -> PowerState {
        let data = try await authed(path: "/things/\(serial)/dashboard", method: "GET")
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let widgets = obj["widgets"] as? [[String: Any]] else {
            throw LMError.decoding("dashboard shape")
        }
        for widget in widgets where (widget["code"] as? String) == "CMMachineStatus" {
            let output = widget["output"] as? [String: Any]
            switch output?["mode"] as? String {
            case "BrewingMode": return .on
            case "StandBy": return .off
            case let other?: return .other(other)
            default: return .unknown
            }
        }
        return .unknown
    }

    /// Turn the machine on (BrewingMode) or off (StandBy).
    func setPower(serial: String, on: Bool) async throws {
        let body = ["mode": on ? "BrewingMode" : "StandBy"]
        _ = try await authed(path: "/things/\(serial)/command/CoffeeMachineChangeMode",
                             method: "POST", body: body)
    }

    // MARK: - Plumbing

    private func authed(path: String, method: String, body: [String: String]? = nil) async throws -> Data {
        try await ensureToken()
        do {
            return try await send(authedRequest(path: path, method: method, body: body))
        } catch LMError.auth {
            // Token may have expired early — sign in fresh and retry once.
            try await signIn()
            return try await send(authedRequest(path: path, method: method, body: body))
        }
    }

    private func authedRequest(path: String, method: String, body: [String: String]?) throws -> URLRequest {
        var req = URLRequest(url: URL(string: "\(Self.baseURL)\(path)")!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken { req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        for (k, v) in LMProof.requestHeaders(for: key) { req.setValue(v, forHTTPHeaderField: k) }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return req
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LMError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LMError.network("no HTTP response")
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 401:
            throw LMError.auth
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LMError.notSuccessful(status: http.statusCode, body: String(body.prefix(300)))
        }
    }
}
