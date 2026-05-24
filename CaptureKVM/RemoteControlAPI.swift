import Foundation

struct RemoteSessionInfo {
    let rawSessionID: String
    let sessionID: UInt64
    let sessionKey: Data
    let udpHost: String
    let inputPort: UInt16
    let videoPort: UInt16
    let mtu: Int
}

enum RemoteControlAPIError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case invalidSessionID
    case invalidSessionKey
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Remote agent URL is invalid."
        case .invalidResponse:
            return "Remote agent response was invalid."
        case .invalidSessionID:
            return "Remote agent returned an invalid session ID."
        case .invalidSessionKey:
            return "Remote agent returned an invalid session key."
        case .server(let message):
            return message
        }
    }
}

final class RemoteControlAPI {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func createSession(baseURLString: String, authToken: String) async throws -> RemoteSessionInfo {
        let request = try makeRequest(baseURLString: baseURLString, path: "/api/session", authToken: authToken, method: "POST")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(SessionResponse.self, from: data)

        guard let sessionID = UInt64(decoded.sessionID, radix: 16) else {
            throw RemoteControlAPIError.invalidSessionID
        }
        guard let sessionKey = Data(base64Encoded: decoded.crypto.sessionKey) else {
            throw RemoteControlAPIError.invalidSessionKey
        }
        guard let inputPort = UInt16(exactly: decoded.udp.inputPort),
              let videoPort = UInt16(exactly: decoded.udp.videoPort) else {
            throw RemoteControlAPIError.invalidResponse
        }

        return RemoteSessionInfo(
            rawSessionID: decoded.sessionID,
            sessionID: sessionID,
            sessionKey: sessionKey,
            udpHost: decoded.udp.host,
            inputPort: inputPort,
            videoPort: videoPort,
            mtu: decoded.udp.mtu
        )
    }

    func closeSession(baseURLString: String, authToken: String, sessionID: String) async {
        guard let body = try? JSONEncoder().encode(["session_id": sessionID]),
              var request = try? makeRequest(baseURLString: baseURLString, path: "/api/session/close", authToken: authToken, method: "POST") else {
            return
        }
        request.httpBody = body
        _ = try? await session.data(for: request)
    }

    func keepAlive(baseURLString: String, authToken: String, sessionID: String) async throws {
        let body = try JSONEncoder().encode(["session_id": sessionID])
        var request = try makeRequest(baseURLString: baseURLString, path: "/api/session/keepalive", authToken: authToken, method: "POST")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    private func makeRequest(baseURLString: String, path: String, authToken: String, method: String) throws -> URLRequest {
        guard let baseURL = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw RemoteControlAPIError.invalidBaseURL
        }
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw RemoteControlAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw RemoteControlAPIError.server(errorResponse.error)
            }
            throw RemoteControlAPIError.server("Remote agent returned HTTP \(http.statusCode).")
        }
    }
}

private struct SessionResponse: Decodable {
    struct Crypto: Decodable {
        let sessionKey: String

        private enum CodingKeys: String, CodingKey {
            case sessionKey = "session_key"
        }
    }

    struct UDP: Decodable {
        let host: String
        let inputPort: Int
        let videoPort: Int
        let mtu: Int

        private enum CodingKeys: String, CodingKey {
            case host
            case inputPort = "input_port"
            case videoPort = "video_port"
            case mtu
        }
    }

    let sessionID: String
    let crypto: Crypto
    let udp: UDP

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case crypto
        case udp
    }
}

private struct ErrorResponse: Decodable {
    let error: String
}
