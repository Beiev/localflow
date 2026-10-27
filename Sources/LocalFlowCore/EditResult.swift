import Foundation

public enum EditIssue: String, Codable, CaseIterable, Sendable {
    case empty, numbers, correction, negation, negationScope, truncated, expanded, structure
    public var title: String {
        switch self {
        case .empty: "пустой результат"
        case .numbers: "изменились числа или их порядок"
        case .correction: "изменилось исправленное число"
        case .negation: "изменилось число отрицаний"
        case .negationScope: "отрицание перенесено к другому слову"
        case .truncated: "потеряна большая часть текста"
        case .expanded: "добавлено слишком много текста"
        case .structure: "строки расшифровки не совпали с исходником"
        }
    }
}

public struct EditResult: Sendable {
    public var text: String
    public var guarded: Bool
    public var proposals: [String]
    public var issues: [EditIssue]
    public init(text: String, guarded: Bool, proposals: [String], issues: [EditIssue] = []) {
        self.text = text; self.guarded = guarded; self.proposals = proposals; self.issues = issues
    }
    public func delivery(original: String, dictionary: [DictionaryEntry]) -> String {
        TextSafety.deliveryText(original: original, edited: text, requiresReview: guarded, dictionary: dictionary)
    }
    public var reviewMessage: String {
        "Редактор мог изменить смысл" + (issues.isEmpty ? "." : ": " + issues.map(\.title).joined(separator: "; ") + ".")
    }
}
