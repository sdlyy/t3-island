import CryptoKit
import Foundation

/// Snoozes and settles threads with T3's own `t3_thread_organize` MCP tool on its local server.
///
/// Signing in follows T3's MCP OAuth flow without a browser, the way T3 links its own environments:
/// a one-time code from the `t3` CLI is approved as a `pairing-code` decision and exchanged for a token.
/// T3 only lets a client organize threads whose runtime mode fits its access level, so it asks for full access.
actor T3Actions {
    enum Action: String {
        case snooze, unsnooze, settle, unsettle
    }

    struct Failure: LocalizedError {
        let message: String
        /// T3 rejected a token that hadn't expired, so it was revoked there.
        var signedOut = false
        var errorDescription: String? { message }
    }

    private struct Session: Codable {
        let token: String
        let expiresAt: Date
    }

    private static let clientName = "T3 Island"
    /// Never opened: the approval answers with the redirect URL, and the code is read from it.
    private static let redirect = "http://127.0.0.1/callback"
    private static let fullAccessScopes = ["orchestration:read", "orchestration:operate", "settings:write", "source-control:write"]

    private let home: URL
    private let sessionFile: URL
    private var session: Session?
    /// Shared by calls that arrive while signing in, so they don't each create a session in T3.
    private var signingIn: Task<Session, Error>?
    private var mcpSession: String?

    init(home: URL = T3Reader.defaultHome()) {
        self.home = home
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        sessionFile = support.appendingPathComponent("T3 Island/t3-session.json")
    }

    func organize(_ threadId: String, _ action: Action, until: Date? = nil) async throws {
        var arguments: [String: Any] = ["threadId": threadId, "action": action.rawValue]
        if let until { arguments["snoozedUntil"] = ISO8601DateFormatter().string(from: until) }
        try await call("t3_thread_organize", arguments)
    }

    /// Forgets the token and revokes the island's sessions in T3.
    func signOut() async {
        session = nil
        mcpSession = nil
        try? FileManager.default.removeItem(at: sessionFile)
        guard let data = try? await cli(["auth", "session", "list", "--json"]),
              let sessions = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }
        for item in sessions where item["subject"] as? String == "mcp-client"
            && (item["client"] as? [String: Any])?["label"] as? String == Self.clientName {
            if let id = item["sessionId"] as? String { _ = try? await cli(["auth", "session", "revoke", id]) }
        }
    }

    // MARK: MCP

    private func call(_ tool: String, _ arguments: [String: Any], retried: Bool = false) async throws {
        let session = try await signedIn()
        var status = mcpSession == nil ? try await initialize(session) : 200
        var body = Data()
        if status == 200 {
            (status, body) = try await post(session, [
                "jsonrpc": "2.0", "id": 2, "method": "tools/call",
                "params": ["name": tool, "arguments": arguments],
            ])
        }
        switch status {
        case 200:
            let result = Self.message(in: body)?["result"] as? [String: Any]
            if result?["isError"] as? Bool == true {
                let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
                let failure = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
                throw Failure(message: failure?["message"] as? String ?? (text.isEmpty ? "T3 refused." : text))
            }
        case 401 where session.expiresAt < Date().addingTimeInterval(3600) && !retried:
            forget()
            try await call(tool, arguments, retried: true)
        case 401:
            forget()
            throw Failure(message: "T3 signed the island out.", signedOut: true)
        case 404 where !retried:
            // The MCP session ended, for example when T3 restarted.
            mcpSession = nil
            try await call(tool, arguments, retried: true)
        default:
            throw Failure(message: "T3 answered with HTTP \(status).")
        }
    }

    /// Starts an MCP session and returns T3's HTTP status, so `call` handles a rejected token in one place.
    private func initialize(_ session: Session) async throws -> Int {
        let (status, _, headers) = try await send(session, [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any],
                       "clientInfo": ["name": "t3-island", "version": "1.0"]],
        ], mcpSession: nil)
        guard status == 200 else { return status }
        mcpSession = headers["mcp-session-id"]
        _ = try await send(session, ["jsonrpc": "2.0", "method": "notifications/initialized"], mcpSession: mcpSession)
        return status
    }

    private func post(_ session: Session, _ body: [String: Any]) async throws -> (Int, Data) {
        let (status, data, _) = try await send(session, body, mcpSession: mcpSession)
        return (status, data)
    }

    private func send(_ session: Session, _ body: [String: Any], mcpSession: String?) async throws
        -> (Int, Data, [String: String]) {
        var request = URLRequest(url: try origin().appendingPathComponent("mcp"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        if let mcpSession { request.setValue(mcpSession, forHTTPHeaderField: "Mcp-Session-Id") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        return (http?.statusCode ?? 0, data, headers)
    }

    /// The JSON-RPC message in a plain JSON or server-sent-events response.
    private static func message(in body: Data) -> [String: Any]? {
        let text = String(decoding: body, as: UTF8.self)
        let json = text.split(separator: "\n").last { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)) } ?? text
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    // MARK: Signing in

    private func signedIn() async throws -> Session {
        if let session { return session }
        if let data = try? Data(contentsOf: sessionFile),
           let saved = try? JSONDecoder().decode(Session.self, from: data), saved.expiresAt > Date() {
            session = saved
            return saved
        }
        if let signingIn { return try await signingIn.value }
        let task = Task { try await signIn() }
        signingIn = task
        defer { signingIn = nil }
        let signedIn = try await task.value
        session = signedIn
        return signedIn
    }

    private func signIn() async throws -> Session {
        let origin = try origin()
        let code = try await pairingCode()

        let client = try await json(origin, "oauth/mcp/register", [
            "client_name": Self.clientName, "redirect_uris": [Self.redirect],
        ])
        guard let clientId = client["client_id"] as? String else { throw Failure(message: "T3 didn't register the island.") }

        let verifier = Self.base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
        let state = UUID().uuidString
        let resource = origin.appendingPathComponent("mcp").absoluteString
        let decision = try await json(origin, "oauth/mcp/decision", [
            "authorization": [
                "response_type": "code", "client_id": clientId, "redirect_uri": Self.redirect,
                "code_challenge": Self.base64URL(Self.sha256(Data(verifier.utf8))), "code_challenge_method": "S256",
                "state": state, "resource": resource,
            ],
            "decision": ["_tag": "pairing-code", "access": "full-access", "code": code],
        ])
        let query = (decision["redirectTo"] as? String).flatMap(URLComponents.init(string:))?.queryItems ?? []
        guard query.first(where: { $0.name == "state" })?.value == state,
              let authCode = query.first(where: { $0.name == "code" })?.value
        else { throw Failure(message: "T3 didn't approve the island.") }

        var form = URLComponents()
        form.queryItems = [
            .init(name: "grant_type", value: "authorization_code"), .init(name: "code", value: authCode),
            .init(name: "redirect_uri", value: Self.redirect), .init(name: "client_id", value: clientId),
            .init(name: "code_verifier", value: verifier), .init(name: "resource", value: resource),
        ]
        var request = URLRequest(url: origin.appendingPathComponent("oauth/mcp/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let token = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let accessToken = token?["access_token"] as? String else {
            throw Failure(message: token?["error_description"] as? String ?? "T3 didn't issue a token.")
        }
        let saved = Session(token: accessToken,
                            expiresAt: Date().addingTimeInterval(token?["expires_in"] as? Double ?? 86400))
        try save(saved)
        return saved
    }

    private func forget() {
        session = nil
        mcpSession = nil
        try? FileManager.default.removeItem(at: sessionFile)
    }

    /// Only this user can read the token, like T3's own secrets.
    private func save(_ session: Session) throws {
        let files = FileManager.default
        try files.createDirectory(at: sessionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? files.removeItem(at: sessionFile)
        guard files.createFile(atPath: sessionFile.path, contents: try JSONEncoder().encode(session),
                               attributes: [.posixPermissions: 0o600])
        else { throw Failure(message: "Couldn't save the T3 sign-in.") }
    }

    private func json(_ origin: URL, _ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: origin.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure(message: object["message"] as? String ?? object["error_description"] as? String
                ?? "T3 refused to sign the island in.")
        }
        return object
    }

    /// The running server, from the file T3 writes when it starts.
    private func origin() throws -> URL {
        let file = home.appendingPathComponent("userdata/server-runtime.json")
        guard let data = try? Data(contentsOf: file),
              let runtime = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let origin = (runtime["origin"] as? String).flatMap(URL.init(string:))
        else { throw Failure(message: "T3 Code isn't running.") }
        return origin
    }

    /// A one-time code that approves one sign-in, valid for two minutes.
    private func pairingCode() async throws -> String {
        var arguments = ["auth", "pairing", "create", "--ttl", "2m", "--label", Self.clientName, "--json"]
        for scope in Self.fullAccessScopes { arguments += ["--scope", scope] }
        let data = try await cli(arguments)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let credential = object["credential"] as? String
        else { throw Failure(message: "T3's command-line tool didn't issue a sign-in code.") }
        return credential
    }

    /// Runs T3's `t3` command-line tool, which T3 Code installs in its home folder.
    private func cli(_ arguments: [String]) async throws -> Data {
        let tool = home.appendingPathComponent("bin/t3")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            throw Failure(message: "T3's command-line tool is missing. Open T3 Code once to install it.")
        }
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Read while it runs, so a long output can't fill the pipe and stall it.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: Failure(message: "T3's command-line tool failed."))
                }
            }
        }
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}
