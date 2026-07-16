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
    @Published var flashModelID: String
    @Published var miniModelID: String
    @Published var deepSeekModelID: String

    let speech = SpeechRecognizerService()
    private let api = APIClient()
    private var queue: [(String, Date)] = []
    private var processing = false
    private var recentSources: [RecentText] = []
    private var recentTranslations: [RecentText] = []

    var pendingCount: Int { queue.count + (processing ? 1 : 0) }

    init() {
        flashModelID = UserDefaults.standard.string(forKey: "flashModelID") ?? "doubao-seed-1-6-flash-250828"
        miniModelID = UserDefaults.standard.string(forKey: "miniModelID") ?? "doubao-seed-2-0-mini-260428"
        deepSeekModelID = UserDefaults.standard.string(forKey: "deepSeekModelID") ?? "deepseek-v4-flash"
        doubaoKey = KeychainStore.read("DOUBAO_API_KEY")
        deepSeekKey = KeychainStore.read("DEEPSEEK_API_KEY")
        loadHistory()
        loadMaterials()
        loadUsage()
    }

    func start() {
        guard !isListening else { return }
        recentSources.removeAll()
        recentTranslations.removeAll()
        status = "正在启动 Apple 语音识别…"
        Task {
            do {
                try await speech.start(localeIdentifier: language.localeIdentifier) { [weak self] text in
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
        status = processing ? "已停止收音，正在完成队列" : "已停止"
    }

    func clearPending() {
        queue.removeAll()
        status = "未翻译队列已清理"
    }

    func clearHistory() {
        history.removeAll()
        recentSources.removeAll()
        recentTranslations.removeAll()
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
                status = "文件没有可提取文字"; return
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
                let context = assistantContext()
                let messages = [
                    ["role": "system", "content": "You are a concise meeting and interview assistant. Use only the supplied transcript and materials when they are relevant. Always answer in exactly two labelled sections: 中文回答： then English Answer:. Do not invent facts."],
                    ["role": "user", "content": "Context:\n\(context)\n\nQuestion:\n\(prompt)"]
                ]
                let result = try await api.chat(model: assistantModel, modelID: modelID(for: assistantModel), doubaoKey: doubaoKey, deepSeekKey: deepSeekKey, messages: messages, maxTokens: 700)
                assistantAnswer = result.text
                record(result)
                status = "回答完成"
            } catch { status = error.localizedDescription }
        }
    }

    func summarize() {
        guard !history.isEmpty else { status = "当前没有会议记录"; return }
        isAssistantBusy = true
        status = "正在生成中英文会议总结…"
        Task {
            defer { isAssistantBusy = false }
            do {
                let messages = [
                    ["role": "system", "content": "Create a concise, factual meeting summary. Output exactly: 中文总结： and English Summary:. Include decisions, action items, owners and deadlines only when present. Do not invent details."],
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
        prune(&recentSources)
        if recentSources.contains(where: { DuplicateDetector.isNearDuplicate($0.text, text) }) {
            status = "已忽略重复识别句"
            return
        }
        recentSources.append(RecentText(text: text, date: Date()))
        currentSource = text
        queue.append((text, Date()))
        status = "已识别完整句，等待翻译"
        Task { await processQueue() }
    }

    private func processQueue() async {
        guard !processing else { return }
        processing = true
        defer { processing = false; status = isListening ? "正在监听" : "已停止" }
        while !queue.isEmpty {
            let (source, date) = queue.removeFirst()
            currentSource = source
            currentChinese = "正在翻译…"
            status = "正在翻译"
            do {
                let recent = history.suffix(2).map { "\($0.source) => \($0.chinese)" }.joined(separator: "\n")
                let messages = [
                    ["role": "system", "content": "Translate one completed \(language.rawValue) speech sentence into concise, accurate Simplified Chinese. Correct only obvious ASR errors using the recent context, including accents, Malaysian English/Manglish and lecture terms. Preserve names, numbers and academic terminology. Output Chinese only. If the input is meaningless filler, output an empty string."],
                    ["role": "user", "content": "Recent context:\n\(recent)\n\nSentence:\n\(source)"]
                ]
                let result = try await api.chat(model: translationModel, modelID: modelID(for: translationModel), doubaoKey: doubaoKey, deepSeekKey: deepSeekKey, messages: messages, maxTokens: 180)
                guard !result.text.isEmpty else { continue }
                currentChinese = result.text
                record(result)
                prune(&recentTranslations)
                if recentTranslations.contains(where: { DuplicateDetector.isNearDuplicate($0.text, result.text) }) {
                    status = "已忽略重复翻译结果"
                    continue
                }
                recentTranslations.append(RecentText(text: result.text, date: Date()))
                history.append(HistoryEntry(date: date, source: source, chinese: result.text, model: result.model))
                saveHistory()
            } catch {
                currentChinese = "翻译失败：\(error.localizedDescription)"
                status = error.localizedDescription
            }
        }
    }

    private func prune(_ list: inout [RecentText]) {
        let cutoff = Date().addingTimeInterval(-35)
        list.removeAll { $0.date < cutoff }
    }

    func modelID(for model: TranslationModel) -> String {
        switch model {
        case .doubaoFlash: return flashModelID
        case .doubaoMini: return miniModelID
        case .deepSeekFlash: return deepSeekModelID
        }
    }

    private func assistantContext() -> String {
        let transcript = history.suffix(80).map { "Source: \($0.source)\nChinese: \($0.chinese)" }.joined(separator: "\n")
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
