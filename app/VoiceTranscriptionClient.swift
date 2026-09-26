//
//  VoiceTranscriptionClient.swift
//  HyperVibe
//
//  Gemini's bounded generateContent and Live transcription paths.
//

import Foundation

enum VoiceTranscriptionError: LocalizedError {
    case missingCredential
    case invalidAudio
    case invalidResponse
    case service(String)
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingCredential: return L("No Gemini API key is saved.")
        case .invalidAudio: return L("No usable speech was recorded.")
        case .invalidResponse: return L("The transcription service returned an invalid response.")
        case .service(let message): return message
        case .timedOut: return L("Transcription timed out. The recording is still available to retry.")
        case .cancelled: return L("Dictation was cancelled.")
        }
    }
}

final class VoiceTranscriptionClient {
    private let session: URLSession
    private let realtimeSession: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 35
        configuration.timeoutIntervalForResource = 45
        // Voice input is interactive. Waiting silently for connectivity is worse than returning a
        // useful failure immediately, and a later press can use the coordinator's fresh prewarm.
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)

        let realtimeConfiguration = URLSessionConfiguration.ephemeral
        realtimeConfiguration.timeoutIntervalForRequest = 15
        realtimeConfiguration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        realtimeConfiguration.waitsForConnectivity = false
        realtimeConfiguration.httpMaximumConnectionsPerHost = 2
        realtimeSession = URLSession(configuration: realtimeConfiguration)
    }

    func transcribeFinal(
        _ audio: VoiceCapturedAudio,
        model: String,
        languageHints: [String],
        dictionary: [Config.DictationTerm]
    ) async throws -> String {
        guard let key = VoiceCredentialStore.read(.gemini) else {
            throw VoiceTranscriptionError.missingCredential
        }
        guard audio.frameCount >= audio.sampleRate / 10, !audio.pcm16.isEmpty else {
            throw VoiceTranscriptionError.invalidAudio
        }

        let name = model.replacingOccurrences(of: "models/", with: "")
        guard name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            throw VoiceTranscriptionError.invalidResponse
        }
        let transcriptionConfig: [String: Any] = [
            "languageCodes": Self.geminiLanguageHints(languageHints),
            "customVocabulary": Array(Self.normalizedKeywords(dictionary).prefix(100))
        ]
        let payload: [String: Any] = [
            "contents": [["parts": [["inlineData": [
                "mimeType": "audio/wav", "data": WAVEncoder.encode(audio).base64EncodedString()
            ]]]]],
            "generationConfig": ["audioTranscriptionConfig": transcriptionConfig]
        ]
        var request = URLRequest(url: URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(name):generateContent")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw VoiceTranscriptionError.invalidResponse
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func openRealtime(
        model: String,
        minimalDelay: Bool,
        languageHints: [String],
        dictionary: [Config.DictationTerm],
        onDelta: @escaping (String) async -> Void,
        onPreview: @escaping (String) async -> Void,
        onDrained: @escaping () async -> Void
    ) async throws -> VoiceRealtimeTranscriptionSession {
        guard let key = VoiceCredentialStore.read(.gemini) else {
            // No receive loop will be created, so close the callback barrier here. The router
            // latches an early drain until the physical press attaches its handlers.
            await onDrained()
            throw VoiceTranscriptionError.missingCredential
        }
        return try await VoiceRealtimeTranscriptionSession.connect(
            apiKey: key,
            urlSession: realtimeSession,
            model: model,
            minimalDelay: minimalDelay,
            languages: Self.geminiLanguageHints(languageHints),
            keywords: Self.normalizedKeywords(dictionary),
            prompt: Self.contextPrompt(dictionary),
            onDelta: onDelta,
            onPreview: onPreview,
            onDrained: onDrained
        )
    }

    static func normalizedLanguageHints(_ raw: [String]) -> [String] {
        unique(raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
    }

    static func geminiLanguageHints(_ raw: [String]) -> [String] {
        normalizedLanguageHints(raw).compactMap { hint in
            switch hint {
            case "zh", "zh-cn", "zh-hans": return "cmn-Hans-CN"
            case "en": return "en-US"
            default: return hint.contains("-") ? hint : nil
            }
        }
    }

    static func normalizedKeywords(_ dictionary: [Config.DictationTerm]) -> [String] {
        unique(dictionary.map(\.term).filter {
            !$0.isEmpty && !$0.contains("<") && !$0.contains(">")
                && !$0.contains("\r") && !$0.contains("\n")
        }).prefix(500).map { $0 }
    }

    static func contextPrompt(_ dictionary: [Config.DictationTerm]) -> String {
        let canonical = normalizedKeywords(dictionary)
        let aliases = dictionary.compactMap { entry -> String? in
            let clean = entry.aliases.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            guard !clean.isEmpty else { return nil }
            return "\(clean.joined(separator: ", ")) → \(entry.term)"
        }
        guard !canonical.isEmpty || !aliases.isEmpty else { return "" }
        var parts: [String] = []
        if !canonical.isEmpty {
            parts.append("可能出现的标准词拼写：" + canonical.joined(separator: ", "))
        }
        if !aliases.isEmpty {
            parts.append("常见发音或误听映射：" + aliases.joined(separator: "; "))
        }
        let prompt = "仅在确实听到时采用以下上下文。" + parts.joined(separator: "。")
        return String(prompt.prefix(4_000))
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }

    static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw VoiceTranscriptionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw VoiceTranscriptionError.service(
                VoiceAPIError.safeMessage(data: data, statusCode: http.statusCode)
            )
        }
    }
}

// MARK: - Realtime transcription

actor RealtimeTranscriptState {
    private var ready = false
    private var deltas = ""
    private var streamEnded = false
    private var completed: String?
    private var failure: String?
    private var terminalError: VoiceTranscriptionError?
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var readyWaiterID: UUID?
    private var readyTimeoutTask: Task<Void, Never>?
    private var resultWaiter: CheckedContinuation<String, Error>?
    private var resultWaiterID: UUID?
    private var resultTimeoutTask: Task<Void, Never>?

    func apply(_ data: Data) throws -> (
        delta: String?, preview: String?, didComplete: Bool
    ) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VoiceTranscriptionError.invalidResponse
        }
        if json["setupComplete"] != nil {
            ready = true
            resolveReadyWaiter(.success(()))
            return (nil, nil, false)
        }
        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? L("Realtime transcription failed.")
            failure = message
            let error = VoiceTranscriptionError.service(message)
            terminalError = error
            resolveReadyWaiter(.failure(error))
            resolveResultWaiter(.failure(error))
            throw error
        }
        guard let content = json["serverContent"] as? [String: Any] else {
            return (nil, nil, false)
        }
        if let interim = content["interimInputTranscription"] as? [String: Any],
           let text = interim["text"] as? String {
            return (nil, deltas + text, false)
        }
        if let final = content["inputTranscription"] as? [String: Any],
           let text = final["text"] as? String, !text.isEmpty {
            // Gemini interim hypotheses can revise words. Only finalized segments enter the
            // editor; speculative words stay in the temporary preview.
            let delta = deltas.isEmpty ? text : " " + text
            deltas += delta
            if streamEnded {
                completed = deltas
                resolveResultWaiter(.success(deltas))
            }
            return (delta, deltas, streamEnded)
        }
        return (nil, nil, false)
    }

    func markStreamEnded() { streamEnded = true }

    func markFailure(_ message: String) {
        if failure == nil { failure = message }
        guard completed == nil, terminalError == nil else { return }
        let error = VoiceTranscriptionError.service(message)
        terminalError = error
        resolveReadyWaiter(.failure(error))
        resolveResultWaiter(.failure(error))
    }

    func markCancelled() {
        guard completed == nil, terminalError == nil else { return }
        let error = VoiceTranscriptionError.cancelled
        terminalError = error
        resolveReadyWaiter(.failure(error))
        resolveResultWaiter(.failure(error))
    }

    /// Handshake success and terminal failure share a direct wake-up. A proxy rejection or socket
    /// close before `session.updated` therefore falls back immediately instead of burning the old
    /// fixed four-second readiness timeout.
    func waitUntilReady(timeoutNanoseconds: UInt64) async throws {
        if ready { return }
        if let terminalError { throw terminalError }
        let waiterID = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if ready {
                    continuation.resume()
                } else if let terminalError {
                    continuation.resume(throwing: terminalError)
                } else {
                    precondition(readyWaiter == nil)
                    readyWaiter = continuation
                    readyWaiterID = waiterID
                    readyTimeoutTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                        await self?.timeoutReadyWaiter(id: waiterID)
                    }
                }
            }
        }, onCancel: { [weak self] in
            Task { await self?.cancelReadyWaiter(id: waiterID) }
        })
    }

    /// Direct continuation wake-up removes the old 10 ms result polling interval (about 5 ms
    /// average release-tail latency) while retaining a hard timeout and cancellation semantics.
    func waitForResult(timeoutNanoseconds: UInt64) async throws -> String {
        if let completed { return completed }
        if let terminalError { throw terminalError }
        let waiterID = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<String, Error>) in
                // Actor reentrancy can let the terminal event arrive as the cancellation handler is
                // installed. Re-check before storing so no completion can be lost.
                if let completed {
                    continuation.resume(returning: completed)
                } else if let terminalError {
                    continuation.resume(throwing: terminalError)
                } else {
                    precondition(resultWaiter == nil)
                    resultWaiter = continuation
                    resultWaiterID = waiterID
                    resultTimeoutTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                        await self?.timeoutResultWaiter(id: waiterID)
                    }
                }
            }
        }, onCancel: { [weak self] in
            Task { await self?.cancelResultWaiter(id: waiterID) }
        })
    }

    func result() -> String? { completed }
    func error() -> String? { failure }

    private func resolveReadyWaiter(
        _ result: Result<Void, VoiceTranscriptionError>
    ) {
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        guard let waiter = readyWaiter else { return }
        readyWaiter = nil
        readyWaiterID = nil
        switch result {
        case .success: waiter.resume()
        case .failure(let error): waiter.resume(throwing: error)
        }
    }

    private func resolveResultWaiter(
        _ result: Result<String, VoiceTranscriptionError>
    ) {
        resultTimeoutTask?.cancel()
        resultTimeoutTask = nil
        guard let waiter = resultWaiter else { return }
        resultWaiter = nil
        resultWaiterID = nil
        switch result {
        case .success(let text): waiter.resume(returning: text)
        case .failure(let error): waiter.resume(throwing: error)
        }
    }

    private func timeoutResultWaiter(id: UUID) {
        guard resultWaiterID == id else { return }
        let error = VoiceTranscriptionError.timedOut
        terminalError = error
        resolveReadyWaiter(.failure(error))
        resolveResultWaiter(.failure(error))
    }

    private func cancelResultWaiter(id: UUID) {
        guard resultWaiterID == id else { return }
        let error = VoiceTranscriptionError.cancelled
        terminalError = error
        resolveReadyWaiter(.failure(error))
        resolveResultWaiter(.failure(error))
    }

    private func timeoutReadyWaiter(id: UUID) {
        guard readyWaiterID == id else { return }
        let error = VoiceTranscriptionError.timedOut
        terminalError = error
        resolveReadyWaiter(.failure(error))
        resolveResultWaiter(.failure(error))
    }

    private func cancelReadyWaiter(id: UUID) {
        guard readyWaiterID == id else { return }
        let error = VoiceTranscriptionError.cancelled
        terminalError = error
        resolveReadyWaiter(.failure(error))
        resolveResultWaiter(.failure(error))
    }
}

final class VoiceRealtimeTranscriptionSession {
    private let webSocket: URLSessionWebSocketTask
    private let state: RealtimeTranscriptState
    private var receiveTask: Task<Void, Never>?
    private let closeLock = NSLock()
    private var closed = false
    private var activityStarted = false

    private init(webSocket: URLSessionWebSocketTask, state: RealtimeTranscriptState) {
        self.webSocket = webSocket
        self.state = state
    }

    static func connect(
        apiKey: String,
        urlSession: URLSession,
        model: String,
        minimalDelay: Bool,
        languages: [String],
        keywords: [String],
        prompt: String,
        onDelta: @escaping (String) async -> Void,
        onPreview: @escaping (String) async -> Void,
        onDrained: @escaping () async -> Void
    ) async throws -> VoiceRealtimeTranscriptionSession {
        var components = URLComponents(string:
            "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15

        let socket = urlSession.webSocketTask(with: request)
        let state = RealtimeTranscriptState()
        let live = VoiceRealtimeTranscriptionSession(webSocket: socket, state: state)
        socket.resume()
        live.receiveTask = Task { [weak live] in
            do {
                while !Task.isCancelled, live != nil {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .string(let string): data = Data(string.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: continue
                    }
                    let change = try await state.apply(data)
                    if let delta = change.delta { await onDelta(delta) }
                    // A delta already lets the UI extend its preview. Only publish the cumulative
                    // callback for non-delta events (notably the server's final committed text),
                    // avoiding two MainActor hops and two SwiftUI invalidations per token.
                    else if let preview = change.preview { await onPreview(preview) }
                }
            } catch is CancellationError {
                await state.markCancelled()
            } catch {
                // A WebSocket URL carries the Gemini key in its query per the Live API contract.
                // Never propagate a transport description that might include that URL.
                await state.markFailure(VoiceAPIError.userFacingMessage(for: error))
            }
            if Task.isCancelled || live == nil { await state.markCancelled() }
            // One terminal barrier for success, transport failure and cancellation. Because every
            // delta/preview callback above is awaited, reaching here proves the callback stream is
            // fully drained before either normal reconciliation or a concurrent REST fallback.
            await onDrained()
        }

        let name = model.replacingOccurrences(of: "models/", with: "")
        guard name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            throw VoiceTranscriptionError.invalidResponse
        }
        var transcription: [String: Any] = ["languageCodes": languages]
        if !keywords.isEmpty { transcription["customVocabulary"] = Array(keywords.prefix(100)) }
        // Final cleanup is a separate stage; keep recognition literal in both modes.
        transcription["mode"] = "VERBATIM"
        let update: [String: Any] = ["setup": [
            "model": "models/\(name)",
            "generationConfig": ["responseModalities": ["TEXT"]],
            "realtimeInputConfig": ["automaticActivityDetection": ["disabled": true]],
            "inputAudioTranscription": transcription
        ]]
        do {
            try await socket.send(.string(try jsonString(update)))
            try await state.waitUntilReady(timeoutNanoseconds: 4_000_000_000)
            return live
        } catch {
            await live.cancel()
            if let message = await state.error() {
                throw VoiceTranscriptionError.service(message)
            }
            throw error
        }
    }

    func append(_ pcm16: Data) async throws {
        guard !pcm16.isEmpty, !isClosed else { return }
        if !activityStarted {
            try await webSocket.send(.string(#"{"realtimeInput":{"activityStart":{}}}"#))
            activityStarted = true
        }
        // Base64's alphabet is JSON-string safe. Building this fixed envelope directly avoids a
        // dictionary and JSONSerialization pass for every 20 ms audio packet (50 times/second).
        let message = Self.audioAppendMessage(pcm16)
        try await webSocket.send(.string(message))
        if let message = await state.error() {
            throw VoiceTranscriptionError.service(message)
        }
    }

    static func audioAppendMessage(_ pcm16: Data) -> String {
        #"{"realtimeInput":{"audio":{"data":""#
            + pcm16.base64EncodedString() + #"","mimeType":"audio/pcm;rate=24000"}}}"#
    }

    func finish() async throws -> String {
        guard !isClosed else { throw VoiceTranscriptionError.cancelled }
        guard activityStarted else { throw VoiceTranscriptionError.invalidAudio }
        try await webSocket.send(.string(#"{"realtimeInput":{"activityEnd":{}}}"#))
        await state.markStreamEnded()
        do {
            let text = try await state.waitForResult(timeoutNanoseconds: 15_000_000_000)
            close(code: .normalClosure)
            return text
        } catch {
            close(code: .goingAway)
            throw error
        }
    }

    func cancel() async {
        close(code: .goingAway)
    }

    func ping() async throws {
        guard !isClosed else { throw VoiceTranscriptionError.cancelled }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            webSocket.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func close(code: URLSessionWebSocketTask.CloseCode) {
        closeLock.lock()
        guard !closed else { closeLock.unlock(); return }
        closed = true
        closeLock.unlock()
        receiveTask?.cancel()
        webSocket.cancel(with: code, reason: nil)
    }

    private var isClosed: Bool {
        closeLock.lock(); defer { closeLock.unlock() }
        return closed
    }

    private static func jsonString(_ value: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw VoiceTranscriptionError.invalidResponse
        }
        return string
    }
}

// MARK: - Encoders

enum WAVEncoder {
    static func encode(_ audio: VoiceCapturedAudio) -> Data {
        let bytesPerSample: UInt16 = 2
        let channels: UInt16 = 1
        let dataSize = UInt32(clamping: audio.pcm16.count)
        let byteRate = UInt32(audio.sampleRate) * UInt32(channels) * UInt32(bytesPerSample)
        let blockAlign = channels * bytesPerSample

        var data = Data(capacity: 44 + audio.pcm16.count)
        data.appendASCII("RIFF")
        data.appendLE(UInt32(36) + dataSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1)) // linear PCM
        data.appendLE(channels)
        data.appendLE(UInt32(audio.sampleRate))
        data.appendLE(byteRate)
        data.appendLE(blockAlign)
        data.appendLE(UInt16(16))
        data.appendASCII("data")
        data.appendLE(dataSize)
        data.append(audio.pcm16)
        return data
    }
}

private struct MultipartBody {
    let boundary: String
    private var data = Data()

    init(boundary: String) { self.boundary = boundary }

    mutating func addField(name: String, value: String) {
        data.appendASCII("--\(boundary)\r\n")
        data.appendASCII("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        data.append(Data(value.utf8))
        data.appendASCII("\r\n")
    }

    mutating func addFile(name: String, filename: String, contentType: String, data file: Data) {
        data.appendASCII("--\(boundary)\r\n")
        data.appendASCII(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
        )
        data.appendASCII("Content-Type: \(contentType)\r\n\r\n")
        data.append(file)
        data.appendASCII("\r\n")
    }

    mutating func finish() -> Data {
        data.appendASCII("--\(boundary)--\r\n")
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) { append(Data(string.utf8)) }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
