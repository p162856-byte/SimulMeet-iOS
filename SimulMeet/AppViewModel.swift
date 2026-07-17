import Combine
import Foundation
import PDFKit
import UniformTypeIdentifiers

@MainActor
final class AppViewModel: ObservableObject {
    @Published var language: SourceLanguage = .english
    @Published var translationModel: TranslationModel = .doubaoFlash
    @Published var assistantModel: TranslationModel = .deepSeekFlash
    @Published var currentSource = ""
    @Published var currentChinese = ""
    @Published var status = "准备就绪"
    @Published var history: [HistoryEntry] = []
    @Published var materials: [UploadedMaterial] = []
    @Published var question = ""
    @Published var assistantAnswer = ""
    @Published var isListening = false
    @Published var isPaused = false
    @Published var isAssistantBusy = false
    @Published var tokenUsage = TokenUsage()
    @Published var doubaoKey = ""
    @Published var deepSeekKey = ""
    @Published var customTerms = ""
    @Published var automaticFailover = true
    @Published var flashModelID: String
    @Published var miniModelID: String
    @Published var deepSeekModelID: String

    let speech = SpeechRecognizerService()
    private let api = APIClient()
    private var queue: [UUID] = []
    private var processing = false

    var pendingCount: Int {
        history.filter { [.pending, .translating].contains($0.resolvedState) }.count
    }

    init() {
        flashModelID = UserDefaults.standard.string(forKey: "flashModelID") ?? "doubao-seed-1-6-flash-250828"
        miniModelID = UserDefaults.standard.string(forKey: "miniModelID") ?? "doubao-seed-2-0-mini-260428"
        deepSeekModelID = UserDefaults.standard.string(forKey: "deepSeekModelID") ?? "deepseek-v4-flash"
        doubaoKey = KeychainStore.read("DOUBAO_API_KEY")
        deepSeekKey = KeychainStore.read("DEEPSEEK_API_KEY")
        customTerms = UserDefaults.standard.string(forKey: "customTerms") ?? ""
        automaticFailover = UserDefaults.standard.object(forKey: "automaticFailover") as? Bool ?? true
        loadHistory()
        loadMaterials()
        loadUsage()
        restoreUnfinishedTranslations()
    }

    func start() {
        guard !isListening else { return }
        status = "正在启动 Apple 语音识别…"
        Task {
            do {
                try await speech.start(localeIdentifier: language.localeIdentifier, contextualStrings: speechContextTerms()) { [weak self] text in
                    Task { @MainActor in self?.acceptSentence(text) }
                }
                isListening = true
                isPaused = false
                status = "正在监听"
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func pauseOrResume() {
        if isListening {
            speech.stop(deliverPending: true)
            isListening = false
            isPaused = true
            status = "已暂停"
        } else if isPaused {
            start()
        }
    }

    func stop() {
        speech.stop(deliverPending: true)
        isListening = false
        isPaused = false
        status = processing ? "已停止收音，正在完成翻译队列" : "已停止"
    }

    func clearPending() {
        let queued = Set(queue)
        queue.removeAll()
        for index in history.indices where queued.contains(history[index].id) && history[index].resolvedState == .pending {
            history[index].state = .failed
            history[index].errorMessage = "已清理；可打开记录后重新翻译"
        }
        saveHistory()
        status = "未翻译队列已清理，原文仍保留在历史中"
    }

    func retryTranslation(_ id: UUID) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        guard history[index].resolvedState != .translating else { return }
        history[index].chinese = ""
        history[index].model = ""
        history[index].state = .pending
        history[index].errorMessage = nil
        if !queue.contains(id) { queue.append(id) }
        saveHistory()
        status = "已重新加入翻译队列"
        Task { await processQueue() }
    }

    func clearHistory() {
        history.removeAll()
        queue.removeAll()
        currentSource = ""
        currentChinese = ""
        saveHistory()
    }

    func saveSettings() {
        KeychainStore.write(doubaoKey.trimmingCharacters(in: .whitespacesAndNewlines), key: "DOUBAO_API_KEY")
        KeychainStore.write(deepSeekKey.trimmingCharacters(in: .whitespacesAndNewlines), key: "DEEPSEEK_API_KEY")
        UserDefaults.standard.set(flashModelID, forKey: "flashModelID")
        UserDefaults.standard.set(miniModelID, forKey: "miniModelID")
        UserDefaults.standard.set(deepSeekModelID, forKey: "deepSeekModelID")
        UserDefaults.standard.set(customTerms, forKey: "customTerms")
        UserDefaults.standard.set(automaticFailover, forKey: "automaticFailover")
        status = "API 配置已安全保存"
    }

    func importMaterial(from url: URL) {
        guard materials.count < 10 else { status = "最多添加 10 个文件"; return }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let text: String
            if url.pathExtension.lowercased() == "pdf" {
                guard let pdf = PDFDocument(url: url) else { throw CocoaError(.fileReadCorruptFile) }
                text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
            } else {
                text = try String(contentsOf: url, encoding: .utf8)
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                status = "文件没有可提取文字"
                return
            }
            materials.append(UploadedMaterial(name: url.lastPathComponent, text: String(text.prefix(120_000))))
            saveMaterials()
            status = "已添加资料：\(url.lastPathComponent)"
        } catch {
            status = "读取文件失败：\(error.localizedDescription)"
        }
    }

    func removeMaterial(_ item: UploadedMaterial) {
        materials.removeAll { $0.id == item.id }
        saveMaterials()
    }

    func ask(question explicitQuestion: String? = nil) {
        let prompt = (explicitQuestion ?? question).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { status = "请先输入问题"; return }
        question = prompt
        isAssistantBusy = true
        status = "正在生成中英文回答…"
        Task {
            defer { isAssistantBusy = false }
            do {
                let messages = [
                    ["role": "system", "content": "You are a concise meeting and interview assistant. Use supplied transcript and materials when relevant. Always answer in exactly two labelled sections: 中文回答： and English Answer:. Do not invent facts."],
                    ["role": "user", "content": "Context:\n\(assistantContext())\n\nQuestion:\n\(prompt)"]
                ]
                let result = try await api.chat(model: assistantModel, modelID: modelID(for: assistantModel), doubaoKey: doubaoKey, deepSeekKey: deepSeekKey, messages: messages, maxTokens: 700)
                assistantAnswer = result.text
                record(result)
                status = "回答完成"
            } catch { status = error.localizedDescription }
        }
    }

    func summarize() {
        let completed = history.filter { $0.resolvedState == .completed }
        guard !completed.isEmpty else { status = "当前没有已翻译的会议记录"; return }
        isAssistantBusy = true
        status = "正在生成中英文会议总结…"
        Task {
            defer { isAssistantBusy = false }
            do {
                let messages = [
                    ["role": "system", "content": "Create a concise factual meeting summary. Output exactly: 中文总结： and English Summary:. Include decisions, action items, owners and deadlines only when present. Do not invent details."],
                    ["role": "user", "content": assistantContext()]
                ]
                let result = try await api.chat(model: assistantModel, modelID: modelID(for: assistantModel), doubaoKey: doubaoKey, deepSeekKey: deepSeekKey, messages: messages, maxTokens: 900)
                assistantAnswer = result.text
                record(result)
                status = "总结完成"
            } catch { status = error.localizedDescription }
        }
    }

    private func acceptSentence(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 1 else { return }

        // Persist first, translate second. Nothing recognized is silently discarded.
        let entry = HistoryEntry(source: text, state: .pending)
        history.append(entry)
        currentSource = text
        queue.append(entry.id)
        saveHistory()
        status = "完整语句已保存，等待翻译"
        Task { await processQueue() }
    }

    private func processQueue() async {
        guard !processing else { return }
        processing = true
        defer {
            processing = false
            status = isListening ? "正在监听" : "翻译队列已完成"
        }

        while !queue.isEmpty {
            let entryID = queue.removeFirst()
            guard let startIndex = history.firstIndex(where: { $0.id == entryID }) else { continue }
            let source = history[startIndex].source
            history[startIndex].state = .translating
            history[startIndex].errorMessage = nil
            currentSource = source
            currentChinese = "正在翻译…"
            saveHistory()

            do {
                let previous = history
                    .filter { $0.id != entryID && $0.resolvedState == .completed }
                    .suffix(1)
                    .first
                let context = previous.map { "\($0.source) => \($0.chinese)" } ?? ""
                let messages = [
                    ["role": "system", "content": "Translate only the current completed \(language.rawValue) speech sentence into accurate Simplified Chinese. Use context only to fix obvious ASR errors. Preserve names, numbers and terminology. Output Chinese only. Never repeat the previous translation unless the current source has the same meaning. For fragments or filler, still return a brief faithful Chinese rendering; never return empty."],
                    ["role": "user", "content": "Previous context:\n\(context)\n\nCurrent sentence:\n\(source)"]
                ]
                var result = try await translateWithRecovery(messages: messages, maxTokens: 120, entryID: entryID)
                guard !result.text.isEmpty else { throw APIClientError.server("模型返回了空译文") }

                if let previous,
                   !DuplicateDetector.isNearDuplicate(previous.source, source),
                   DuplicateDetector.isNearDuplicate(previous.chinese, result.text) {
                    currentChinese = "正在校正重复译文…"
                    let retryMessages = [
                        ["role": "system", "content": "Translate this speech sentence into concise, accurate Simplified Chinese. Translate this sentence only. Output Chinese only and never return empty."],
                        ["role": "user", "content": source]
                    ]
                    result = try await translateWithRecovery(messages: retryMessages, maxTokens: 120, entryID: entryID)
                    guard !result.text.isEmpty else { throw APIClientError.server("重试后仍为空译文") }
                }

                if let index = history.firstIndex(where: { $0.id == entryID }) {
                    history[index].chinese = result.text
                    history[index].model = result.model
                    history[index].state = .completed
                    history[index].errorMessage = nil
                }
                currentChinese = result.text
                record(result)
                saveHistory()
            } catch {
                if let index = history.firstIndex(where: { $0.id == entryID }) {
                    history[index].state = .failed
                    history[index].errorMessage = error.localizedDescription
                }
                currentChinese = "翻译失败：\(error.localizedDescription)"
                status = error.localizedDescription
                saveHistory()
            }
        }
    }

    private func restoreUnfinishedTranslations() {
        for index in history.indices where history[index].resolvedState == .translating {
            history[index].state = .pending
        }
        queue = history.filter { $0.resolvedState == .pending }.map(\.id)
        if !queue.isEmpty { Task { await processQueue() } }
    }

    private func translateWithRecovery(messages: [[String: String]], maxTokens: Int, entryID: UUID) async throws -> APIResult {
        var candidates = [translationModel]
        if automaticFailover {
            if translationModel != .doubaoFlash, !doubaoKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                candidates.append(.doubaoFlash)
            }
            if translationModel != .deepSeekFlash, !deepSeekKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                candidates.append(.deepSeekFlash)
            }
        }

        var lastError: Error = APIClientError.invalidResponse
        for (candidateIndex, candidate) in candidates.enumerated() {
            let attempts = candidateIndex == 0 ? 2 : 1
            for attempt in 0..<attempts {
                do {
                    return try await api.chatStream(
                        model: candidate,
                        modelID: modelID(for: candidate),
                        doubaoKey: doubaoKey,
                        deepSeekKey: deepSeekKey,
                        messages: messages,
                        maxTokens: maxTokens,
                        onText: { [weak self] partial in
                            guard let self else { return }
                            self.currentChinese = partial
                            if let index = self.history.firstIndex(where: { $0.id == entryID }) {
                                self.history[index].chinese = partial
                            }
                        }
                    )
                } catch {
                    lastError = error
                    if attempt + 1 < attempts {
                        try? await Task.sleep(nanoseconds: 180_000_000)
                    }
                }
            }
        }
        throw lastError
    }

    private func speechContextTerms() -> [String] {
        var values = customTerms
            .components(separatedBy: CharacterSet(charactersIn: ",;，；\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        values.append(contentsOf: materials.map { URL(fileURLWithPath: $0.name).deletingPathExtension().lastPathComponent })

        let pattern = #"\b(?:[A-Z][A-Za-z0-9-]{2,}|[A-Z]{2,})\b"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            for material in materials {
                let sample = String(material.text.prefix(20_000))
                let range = NSRange(sample.startIndex..<sample.endIndex, in: sample)
                for match in regex.matches(in: sample, range: range).prefix(40) {
                    if let swiftRange = Range(match.range, in: sample) {
                        values.append(String(sample[swiftRange]))
                    }
                }
            }
        }

        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }.prefix(100).map { $0 }
    }

    func modelID(for model: TranslationModel) -> String {
        switch model {
        case .doubaoFlash: return flashModelID
        case .doubaoMini: return miniModelID
        case .deepSeekFlash: return deepSeekModelID
        }
    }

    private func assistantContext() -> String {
        let transcript = history.suffix(80).map { item in
            let translation = item.resolvedState == .completed ? item.chinese : "[\(item.resolvedState.title)]"
            return "Source: \(item.source)\nChinese: \(translation)"
        }.joined(separator: "\n")
        let files = materials.map { "[\($0.name)]\n\($0.text)" }.joined(separator: "\n\n")
        return String(("Meeting transcript:\n" + transcript + "\n\nMaterials:\n" + files).prefix(90_000))
    }

    private func record(_ result: APIResult) {
        tokenUsage.requests += 1
        tokenUsage.input += result.inputTokens
        tokenUsage.output += result.outputTokens
        tokenUsage.total += result.totalTokens
        if let data = try? JSONEncoder().encode(tokenUsage) { UserDefaults.standard.set(data, forKey: "tokenUsage") }
    }

    private var supportDirectory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = root.appendingPathComponent("SimulMeet", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: supportDirectory.appendingPathComponent("history.json"), options: .atomic)
    }

    private func loadHistory() {
        let url = supportDirectory.appendingPathComponent("history.json")
        guard let data = try? Data(contentsOf: url), let values = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        history = values
    }

    private func saveMaterials() {
        guard let data = try? JSONEncoder().encode(materials) else { return }
        try? data.write(to: supportDirectory.appendingPathComponent("materials.json"), options: .atomic)
    }

    private func loadMaterials() {
        let url = supportDirectory.appendingPathComponent("materials.json")
        guard let data = try? Data(contentsOf: url), let values = try? JSONDecoder().decode([UploadedMaterial].self, from: data) else { return }
        materials = values
    }

    private func loadUsage() {
        guard let data = UserDefaults.standard.data(forKey: "tokenUsage"), let value = try? JSONDecoder().decode(TokenUsage.self, from: data) else { return }
        tokenUsage = value
    }
}
