import Foundation

/// An OpenAI-compatible multipart transcription endpoint (Groq, OpenRouter).
struct CloudEngine: SpeechEngine {
    let modelId: String
    let endpoint: URL
    let model: String
    let apiKey: String

    static func groq(apiKey: String) -> CloudEngine {
        CloudEngine(modelId: "groq/whisper-large-v3-turbo",
                    endpoint: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!,
                    model: "whisper-large-v3-turbo", apiKey: apiKey)
    }

    static func openRouter(model: String, apiKey: String) -> CloudEngine {
        CloudEngine(modelId: "openrouter/\(model)",
                    endpoint: URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!,
                    model: model, apiKey: apiKey)
    }

    private struct Response: Decodable {
        struct Segment: Decodable {
            let start: Double
            let end: Double
            let text: String
            let avg_logprob: Double?
        }
        let text: String
        let segments: [Segment]?
    }

    func transcribe(_ audio: SpeechAudio) async throws -> SpeechResult {
        guard case .file(let url) = audio else { throw EvalError("cloud engines take files only") }
        let boundary = UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", model)
        field("response_format", "verbose_json")
        field("timestamp_granularities[]", "segment")
        field("temperature", "0")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(url.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: url))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        for attempt in 1...6 {
            let (data, response) = try await URLSession.shared.upload(for: request, from: body)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 || status >= 500 {
                let wait = Double((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after") ?? "") ?? Double(attempt * 10)
                try await Task.sleep(for: .seconds(min(wait, 120)))
                continue
            }
            guard status == 200 else {
                throw EvalError("\(modelId) HTTP \(status): \(String(data: data.prefix(300), encoding: .utf8) ?? "")")
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            var segments = (decoded.segments ?? []).compactMap { s -> SpeechSegment? in
                let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : SpeechSegment(start: s.start, end: s.end, text: text,
                                                          confidence: s.avg_logprob.map(exp) ?? 1)
            }
            let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if segments.isEmpty, !text.isEmpty {
                // No timestamps from this provider: one untimed segment (start = end = 0) keeps the text for WER.
                segments = [SpeechSegment(start: 0, end: 0, text: text, confidence: 1)]
            }
            return SpeechResult(modelId: modelId, segments: segments)
        }
        throw EvalError("\(modelId) rate limited after retries")
    }
}

struct EvalError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
