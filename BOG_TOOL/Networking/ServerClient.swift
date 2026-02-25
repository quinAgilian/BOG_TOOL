import Foundation

/// HTTP client for the BOG production test server.
/// Owns all server communication; views use this instead of URLSession directly.
protocol ServerClientProtocol: AnyObject {
    func uploadProductionTest(body: [String: Any]) async throws
    func performHealthCheck() async -> (reachable: Bool, latencyMs: Double?)
}

final class ServerClient: ObservableObject, ServerClientProtocol {
    private weak var serverSettings: ServerSettings?
    private let maxAttempts = 3
    private let retryDelaySeconds: UInt64 = 2

    init(serverSettings: ServerSettings) {
        self.serverSettings = serverSettings
    }

    private var reportURL: URL? {
        guard let settings = serverSettings else { return nil }
        let base = settings.effectiveBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: base + ServerAPI.productionTest)
    }

    func uploadProductionTest(body: [String: Any]) async throws {
        guard let url = reportURL else {
            throw ServerClientError.missingConfiguration
        }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            throw ServerClientError.encodingFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 30

        for attempt in 1...maxAttempts {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (400..<500).contains(code) {
                    throw ServerClientError.serverError(statusCode: code, retriable: false)
                }
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: retryDelaySeconds * 1_000_000_000)
                } else {
                    throw ServerClientError.serverError(statusCode: code, retriable: true)
                }
            } catch {
                let retriable = Self.isRetriableNetworkError(error)
                if retriable && attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: retryDelaySeconds * 1_000_000_000)
                } else {
                    if retriable {
                        throw ServerClientError.networkError(error, retriable: true)
                    } else {
                        throw ServerClientError.networkError(error, retriable: false)
                    }
                }
            }
        }
    }

    func performHealthCheck() async -> (reachable: Bool, latencyMs: Double?) {
        guard let settings = serverSettings else { return (false, nil) }
        let base = settings.effectiveBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + ServerAPI.summary) else { return (false, nil) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let ok = (response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
            let latencyMs = ok ? Date().timeIntervalSince(start) * 1000.0 : nil
            return (ok, latencyMs)
        } catch {
            return (false, nil)
        }
    }

    static func isRetriableNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
             .dnsLookupFailed, .cannotFindHost, .secureConnectionFailed, .resourceUnavailable,
             .internationalRoamingOff, .dataNotAllowed:
            return true
        default:
            return false
        }
    }
}

enum ServerClientError: LocalizedError {
    case missingConfiguration
    case encodingFailed
    case serverError(statusCode: Int, retriable: Bool)
    case networkError(Error, retriable: Bool)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration: return "Server URL not configured"
        case .encodingFailed: return "Failed to encode request body"
        case .serverError(let code, _): return "Server returned \(code)"
        case .networkError(let e, _): return e.localizedDescription
        }
    }
}
