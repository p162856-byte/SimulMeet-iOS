import Foundation

enum TranslationModel: String, CaseIterable, Codable, Identifiable, Equatable {
    case doubaoFlash
    case doubaoMini
    case deepSeekFlash

    var id: String { rawValue }
    var title: String {
        switch self {
        case .doubaoFlash: return "Doubao Seed 1.6 Flash"
        case .doubaoMini: return "Doubao Seed 2.0 Mini"
        case .deepSeekFlash: return "DeepSeek V4 Flash"
        }
    }
    var usesDeepSeek: Bool { self == .deepSeekFlash }
}

enum SourceLanguage: String, CaseIterable, Identifiable {
    case english = "English"
    case mandarin = "中文 Mandarin"
    case malay = "Malay"
    case japanese = "Japanese"
    case korean = "Korean"
    case thai = "Thai"
    case french = "French"
    case spanish = "Spanish"

    var id: String { rawValue }
    var localeIdentifier: String {
        switch self {
        case .english: return "en-US"
        case .mandarin: return "zh-CN"
        case .malay: return "ms-MY"
        case .japanese: return "ja-JP"
        case .korean: return "ko-KR"
        case .thai: return "th-TH"
        case .french: return "fr-FR"
        case .spanish: return "es-ES"
        }
    }
}

enum TranslationState: String, Codable, CaseIterable, Equatable {
    case pending
    case translating
    case completed
    case failed

    var title: String {
        switch self {
        case .pending: return "待翻译"
        case .translating: return "翻译中"
        case .completed: return "已完成"
        case .failed: return "翻译失败"
        }
    }
}

struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let source: String
    var chinese: String
    var model: String
    var state: TranslationState?
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        source: String,
        chinese: String = "",
        model: String = "",
        state: TranslationState = .pending,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.date = date
        self.source = source
        self.chinese = chinese
        self.model = model
        self.state = state
        self.errorMessage = errorMessage
    }

    var resolvedState: TranslationState {
        state ?? (chinese.isEmpty ? .pending : .completed)
    }
}

struct UploadedMaterial: Identifiable, Codable {
    let id: UUID
    let name: String
    let text: String

    init(id: UUID = UUID(), name: String, text: String) {
        self.id = id
        self.name = name
        self.text = text
    }
}

struct TokenUsage: Codable {
    var requests = 0
    var input = 0
    var output = 0
    var total = 0
}

enum DuplicateDetector {
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func isNearDuplicate(_ lhs: String, _ rhs: String) -> Bool {
        let first = normalize(lhs)
        let second = normalize(rhs)
        guard !first.isEmpty, !second.isEmpty else { return false }
        if first == second { return true }
        let shorter = min(first.count, second.count)
        let longer = max(first.count, second.count)
        let ratio = longer == 0 ? 0 : Double(shorter) / Double(longer)
        if shorter >= 8, ratio >= 0.78, first.contains(second) || second.contains(first) { return true }

        let a = Set(first.split(separator: " ").map(String.init))
        let b = Set(second.split(separator: " ").map(String.init))
        if a.count >= 4, b.count >= 4 {
            let overlap = a.intersection(b).count
            if ratio >= 0.70, Double(overlap) / Double(min(a.count, b.count)) >= 0.84 { return true }
        }

        let x = bigrams(first.replacingOccurrences(of: " ", with: ""))
        let y = bigrams(second.replacingOccurrences(of: " ", with: ""))
        guard !x.isEmpty, !y.isEmpty else { return false }
        return ratio >= 0.72 && Double(x.intersection(y).count) / Double(x.union(y).count) >= 0.82
    }

    private static func bigrams(_ value: String) -> Set<String> {
        let chars = Array(value)
        guard chars.count > 1 else { return value.isEmpty ? [] : [value] }
        return Set((0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) })
    }
}
