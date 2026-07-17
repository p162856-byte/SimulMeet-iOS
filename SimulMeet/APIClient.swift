import Foundation

struct APIResult {
    let text: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
}

enum APIClientError: LocalizedError {
    case missingKey(String)
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let provider): return "请先在设置中填写 \(provider) API Key。"
        case .invalidResponse: return "模型返回格式无法识别。"
        case .server(let message): return message
        }
    }
}

final class APIClient {
    func chat(
        model: TranslationModel,
        modelID: String,
        doubaoKey: String,
        deepSeekKey: String,
        messages: [[String: String]],
        maxTokens: Int
    ) async throws -> APIResult {
        var request = try makeRequest(model: model, modelID: modelID, doubaoKey: doubaoKey, deepSeekKey: deepSeekKey, messages: messages, maxTokens: maxTokens, stream: false)
        request.timeoutInterval = 35
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw APIClientError.invalidResponse }
        let usage = json["usage"] as? [String: Any] ?? [:]
        return APIResult(
            text: content.trimmingCharacters(in: .whitespacesAndNewlines),
            model: (json["model"] as? String) ?? modelID,
            inputTokens: usage["prompt_tokens"] as? Int ?? 0,
            outputTokens: usage["completion_tokens"] as? Int ?? 0,
            totalTokens: usage["total_tokens"] as? Int ?? 0
        )
    }

    func chatStream(
        model: TranslationModel,
        modelID: String,
        doubaoKey: String,
        deepSeekKey: String,
        messages: [[String: String]],
        maxTokens: Int,
        onText: @escaping @MainActor (String) -> Void
    ) async throws -> APIResult {
        var request = try makeRequest(model: model, modelID: modelID, doubaoKey: doubaoKey, deepSeekKey: deepSeekKey, messages: messages, maxTokens: maxTokens, stream: true)
        request.timeoutInterval = 35
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIClientError.server("HTTP \(http.statusCode)") }

        var fullText = ""
        var responseModel = modelID
        var inputTokens = 0
        var outputTokens = 0
        var totalTokens = 0

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let value = json["model"] as? String { responseModel = value }
            if let usage = json["usage"] as? [String: Any] {
                inputTokens = usage["prompt_tokens"] as? Int ?? inputTokens
                outputTokens = usage["completion_tokens"] as? Int ?? outputTokens
                totalTokens = usage["total_tokens"] as? Int ?? totalTokens
            }
            if let choices = json["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any],
               let content = delta["content"] as? String,
               !content.isEmpty {
                fullText += content
                await onText(fullText)
            }
        }

        let cleaned = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw APIClientError.server("模型返回了空译文") }
        return APIResult(text: cleaned, model: responseModel, inputTokens: inputTokens, outputTokens: outputTokens, totalTokens: totalTokens)
    }

    private func makeRequest(
        model: TranslationModel,
        modelID: String,
        doubaoKey: String,
        deepSeekKey: String,
        messages: [[String: String]],
        maxTokens: Int,
        stream: Bool
    ) throws -> URLRequest {
        let key = model.usesDeepSeek ? deepSeekKey : doubaoKey
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIClientError.missingKey(model.usesDeepSeek ? "DeepSeek" : "豆包")
        }
        let root = model.usesDeepSeek ? "https://api.deepseek.com" : "https://ark.cn-beijing.volces.com/api/v3"
        guard let url = URL(string: root + "/chat/completions") else { throw APIClientError.invalidResponse }

        var body: [String: Any] = [
            "model": modelID,
            "messages": messages,
            "temperature": 0.02,
            "max_tokens": maxTokens,
            "stream": stream
        ]
        if stream { body["stream_options"] = ["include_usage": true] }
        if !model.usesDeepSeek { body["thinking"] = ["type": "disabled"] }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = json?["error"] as? [String: Any]
            let message = error?["message"] as? String ?? String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw APIClientError.server(message)
        }
    }
}
