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
        case .missingKey(let provider): return "请先在设置中填写\(provider) API Key。"
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
        let key = model.usesDeepSeek ? deepSeekKey : doubaoKey
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIClientError.missingKey(model.usesDeepSeek ? "DeepSeek" : "豆包")
        }
        let root = model.usesDeepSeek ? "https://api.deepseek.com" : "https://ark.cn-beijing.volces.com/api/v3"
        guard let url = URL(string: root + "/chat/completions") else { throw APIClientError.invalidResponse }

        var body: [String: Any] = [
            "model": modelID,
            "messages": messages,
            "temperature": 0.03,
            "max_tokens": maxTokens,
            "stream": false
        ]
        if !model.usesDeepSeek { body["thinking"] = ["type": "disabled"] }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = json?["error"] as? [String: Any]
            let message = error?["message"] as? String ?? String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw APIClientError.server(message)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
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
}
