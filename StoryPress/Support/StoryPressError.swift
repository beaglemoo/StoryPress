import Foundation

enum StoryPressError: Error, LocalizedError, Equatable, Sendable {
    case invalidInput(String)
    case providerNotConfigured(String)
    case modelNotSelected
    case missingOpenRouterKey
    case httpStatus(Int, String)
    case networkTimeout(String)
    case network(String)
    case malformedStory(String)
    case invalidWorkflow(String)
    case storage(String)
    case unsafeAssetPath
    case missingAsset(String)
    case exportLayout(String)
    case keychain(Int32)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidInput(let message): message
        case .providerNotConfigured(let message): message
        case .modelNotSelected: "Choose a model in Settings or refresh the provider model list."
        case .missingOpenRouterKey: "Add an OpenRouter API key in Settings to use OpenRouter."
        case .httpStatus(let status, let message):
            message.isEmpty ? "The provider returned HTTP \(status)." : "The provider returned HTTP \(status): \(message)"
        case .networkTimeout(let operation): "\(operation) timed out. Check the provider status before trying again."
        case .network(let message): message
        case .malformedStory(let message): "The story response could not be used: \(message)"
        case .invalidWorkflow(let message): "The ComfyUI workflow is invalid: \(message)"
        case .storage(let message): "StoryPress could not save the library: \(message)"
        case .unsafeAssetPath: "The selected image path is outside this book's library folder."
        case .missingAsset(let name): "The book is missing its illustration asset: \(name)"
        case .exportLayout(let message): "The PDF could not be exported: \(message)"
        case .keychain(let status): "macOS Keychain returned status \(status)."
        case .cancelled: "Generation was cancelled."
        }
    }
}

struct HTTPPayload: Sendable {
    var statusCode: Int
    var data: Data
    var contentType: String?
}

protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPPayload
}

struct URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
    var session: URLSession = .shared

    func send(_ request: URLRequest) async throws -> HTTPPayload {
        do {
            let activeSession = request.value(forHTTPHeaderField: "Authorization") == nil ? session : Self.authenticatedSession
            let (data, response) = try await activeSession.data(for: request)
            let http = response as? HTTPURLResponse
            return HTTPPayload(
                statusCode: http?.statusCode ?? 0,
                data: data,
                contentType: http?.value(forHTTPHeaderField: "Content-Type")
            )
        } catch let error as URLError where error.code == .timedOut {
            throw StoryPressError.networkTimeout(request.url?.host ?? "Provider request")
        } catch is CancellationError {
            throw StoryPressError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw StoryPressError.cancelled
        } catch {
            throw StoryPressError.network(error.localizedDescription)
        }
    }

    private static let authenticatedSession = URLSession(
        configuration: .ephemeral,
        delegate: SameOriginRedirectDelegate(),
        delegateQueue: nil
    )
}

private final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url,
              let destination = request.url,
              original.scheme?.lowercased() == destination.scheme?.lowercased(),
              original.host?.lowercased() == destination.host?.lowercased(),
              original.port == destination.port else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

enum HTTPRequestSupport {
    static func check(_ payload: HTTPPayload, redacting secrets: [String] = []) throws {
        guard (200..<300).contains(payload.statusCode) else {
            let message = responseMessage(payload.data, redacting: secrets)
            throw StoryPressError.httpStatus(payload.statusCode, message)
        }
    }

    static func responseMessage(_ data: Data, redacting secrets: [String] = []) -> String {
        guard !data.isEmpty else { return "" }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return sanitize(message, redacting: secrets)
            }
            if let message = object["message"] as? String { return sanitize(message, redacting: secrets) }
        }
        guard let text = String(data: data.prefix(512), encoding: .utf8) else { return "" }
        return sanitize(text, redacting: secrets)
    }

    private static func sanitize(_ value: String, redacting secrets: [String]) -> String {
        let clean = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        var result = String(String.UnicodeScalarView(clean)).trimmingCharacters(in: .whitespacesAndNewlines)
        for secret in secrets where secret.count >= 4 {
            result = result.replacingOccurrences(of: secret, with: "[redacted]")
        }
        result = result.replacingOccurrences(
            of: "(?i)(bearer\\s+)[A-Za-z0-9._~+/-]+=*",
            with: "$1[redacted]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "(?i)\\b(sk-or-v1-|sk-)[A-Za-z0-9_-]{8,}\\b",
            with: "[redacted]",
            options: .regularExpression
        )
        return String(result.prefix(240))
    }
}
