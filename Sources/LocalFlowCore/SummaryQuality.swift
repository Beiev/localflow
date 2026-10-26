import Foundation

/// Deterministic, explainable proxies for "is this summary any good". None of them prove quality,
/// and a document can score well and still read badly. They exist because the owner's complaints
/// were specific and every one of them is countable: intentions filed under numbers, tasks filed
/// as decisions, the same point made twice in different words, a citation that points nowhere,
/// a figure nobody said, every task handed to "Участник 1", and an opening paragraph that would
/// fit any meeting ever held.
public struct SummaryScore: Equatable, Sendable {
    public var characters = 0
    public var sourceCharacters = 0
    public var bullets = 0
    /// Bullets filed under a section their own wording contradicts.
    public var misfiledBullets = 0
    /// Pairs of bullets saying the same thing in different words.
    public var duplicatePairs = 0
    public var citations = 0
    /// Citations landing inside the recording. A citation that does not is unusable.
    public var resolvableCitations = 0
    public var numbers = 0
    /// Figures that also occur in the transcript. The rest were invented.
    public var groundedNumbers = 0
    /// Distinct figures the conversation contained, and how many reached the document. Fidelity
    /// alone is satisfied by a summary with no figures at all, so the opposite error — a capped
    /// extraction quietly dropping the numbers that mattered — needs its own count.
    public var sourceNumbers = 0
    public var coveredNumbers = 0
    public var tasks = 0
    /// Tasks handed to a diarizer label rather than a person.
    public var tasksWithGenericOwner = 0
    /// Whether the opening says something only this meeting could have said.
    public var openingIsSpecific = false
    public var sections: Set<String> = []

    public var compression: Double { sourceCharacters > 0 ? Double(characters) / Double(sourceCharacters) : 0 }
    public var citationValidity: Double { citations > 0 ? Double(resolvableCitations) / Double(citations) : 1 }
    public var numberFidelity: Double { numbers > 0 ? Double(groundedNumbers) / Double(numbers) : 1 }
    public var numberCoverage: Double { sourceNumbers > 0 ? Double(coveredNumbers) / Double(sourceNumbers) : 1 }
    public var sectionPurity: Double { bullets > 0 ? 1 - Double(misfiledBullets) / Double(bullets) : 1 }
    public var redundancy: Double { bullets > 1 ? Double(duplicatePairs) / Double(bullets) : 0 }
    public var ownerClarity: Double { tasks > 0 ? 1 - Double(tasksWithGenericOwner) / Double(tasks) : 1 }

    public var line: String {
        String(format: "chars=%d compression=%.3f bullets=%d purity=%.2f redundancy=%.2f citations=%d/%d numbers=%d/%d coverage=%d/%d tasks=%d generic_owner=%d opening_specific=%@",
               characters, compression, bullets, sectionPurity, redundancy,
               resolvableCitations, citations, groundedNumbers, numbers,
               coveredNumbers, sourceNumbers, tasks, tasksWithGenericOwner, openingIsSpecific ? "yes" : "no")
    }
}

public enum SummaryQuality {
    /// A transcript with its timestamps and speaker labels removed: the words themselves.
    static func speech(of transcript: String) -> String {
        transcript.components(separatedBy: .newlines).map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return trimmed }
            let rest = trimmed[trimmed.index(after: close)...]
            guard let colon = rest.firstIndex(of: ":") else { return String(rest) }
            return String(rest[rest.index(after: colon)...])
        }.joined(separator: "\n")
    }

    /// The five sections the condensed document is asked for, recognized by what the heading says
    /// rather than by position: a merged document does not always keep the order.
    public enum Section: String, CaseIterable, Sendable {
        case opening, facts, decisions, tasks, questions, topics
        var keywords: [String] {
            switch self {
            case .opening: ["о чём", "о чем", "суть", "главное", "итог"]
            case .facts: ["состояние", "цифры", "показател", "факты"]
            case .decisions: ["решени", "договорил"]
            case .tasks: ["задач", "действи", "кто что"]
            case .questions: ["вопрос", "открыт"]
            case .topics: ["по темам", "разбор по"]
            }
        }
        static func match(_ heading: String) -> Section? {
            let value = heading.lowercased()
            // Longest keyword first, so "открытые вопросы" is not read as a decision heading.
            return allCases.first { $0.keywords.contains { value.contains($0) } }
        }
    }

    /// Wording that states an intention. A line opening with one of these is something somebody
    /// wants done — a task at best — and is not a measurement and not a settled decision.
    static let intentionMarkers = [
        "нужно", "надо", "необходимо", "следует", "стоит", "давай", "давайте",
        "планиру", "хотим", "хочет", "попробовать", "попробуем", "предлагаю", "предлагает", "требуется",
    ]
    /// A decision is a choice that was made. These say so.
    static let settledMarkers = ["договорил", "решили", "решено", "выбрал", "отказал", "утвердил", "остановились", "согласовал"]
    /// The counts the deterministic opening carries. They are the document counting itself.
    static let assembledCounts = #"(?:Решения|Задачи|Открытые вопросы):\s*\d+"#
    /// Diarizer labels. A task handed to one of these has no owner.
    static let genericOwner = #"(?:Участник\s*\d+|Собеседник|Спикер\s*\d+|Говорящий\s*\d+)"#
    /// Below this, two bullets are different points; at or above it they are the same point twice.
    public static let duplicateSimilarity = 0.7

    public static func score(_ summary: String, source: String, duration: Double, speakers: [String] = []) -> SummaryScore {
        var score = SummaryScore()
        score.characters = summary.count
        score.sourceCharacters = source.count

        let references = RichText.timeReferences(in: summary)
        // A bracketed bare number is a citation the model failed to format; counting it in the
        // denominator keeps a document from looking perfectly cited by failing silently.
        score.citations = references.count + RichText.malformedTimeReferences(in: summary)
        score.resolvableCitations = duration > 0 ? references.filter { $0.seconds <= duration + 1 }.count : 0

        // Figures from what was said, not from the scaffolding around it. A transcript line opens
        // with `[04:41] Участник 1:`, whose clock and whose label both carry digits, and counting
        // them made every "Участник 1" in a summary look like a figure the conversation contained.
        let sourceNumbers = Set(TextSafety.numberTokens(speech(of: source)))
        score.sourceNumbers = sourceNumbers.count
        // Figures inside a citation are the clock, not a claim.
        var claims = summary
        for reference in references.reversed() { claims.replaceSubrange(reference.range, with: " ") }
        // So are the counts the opening is assembled with. "Решения: 2. Задачи: 0." says something
        // about the document, not about the conversation, and counting those as figures nobody
        // said made an assembled opening look like a document that invents numbers.
        claims = claims.replacingOccurrences(of: assembledCounts, with: " ", options: .regularExpression)
        let summaryNumbers = TextSafety.numberTokens(claims)
        score.numbers = summaryNumbers.count
        score.groundedNumbers = summaryNumbers.filter { sourceNumbers.contains($0) }.count
        score.coveredNumbers = sourceNumbers.intersection(summaryNumbers).count

        var section: Section?
        var bulletsBySection: [Section: [String]] = [:]
        var opening: [String] = []
        for block in RichText.blocks(summary) {
            switch block {
            case .heading(let level, let text):
                // Inside the topic section its own headings name topics, not sections: "Решение
                // по подрядчику" is a topic, and reading it as the decisions section would hand
                // every later statement to the wrong counter. A legacy summary writes its section
                // headings in bold, which parse as level three, so only the topic section is
                // allowed to swallow a subheading this way.
                if section == .topics, level > 2 { break }
                section = Section.match(text)
                if let section { score.sections.insert(section.rawValue) }
            case .bullet(_, _, let text):
                guard let section else { continue }
                bulletsBySection[section, default: []].append(RichText.inline(text))
            case .paragraph(let text):
                if section == .opening || section == nil { opening.append(RichText.inline(text)) }
                // A topic is a passage of several statements in one paragraph, and every count
                // below is about statements, so it is read back into the sentences it was
                // assembled from rather than counted as one long bullet.
                else if section == .topics { bulletsBySection[.topics, default: []] += sentences(RichText.inline(text)) }
                else if let section { bulletsBySection[section, default: []].append(RichText.inline(text)) }
            case .table(_, let rows):
                guard let section else { continue }
                bulletsBySection[section, default: []].append(contentsOf: rows.map { $0.joined(separator: " ") })
            case .quote, .divider: continue
            }
        }

        for (section, bullets) in bulletsBySection {
            score.bullets += bullets.count
            score.misfiledBullets += bullets.filter { misfiled($0, in: section) }.count
            if section == .tasks {
                score.tasks += bullets.count
                score.tasksWithGenericOwner += bullets.filter {
                    $0.range(of: genericOwner, options: .regularExpression) != nil
                }.count
            }
        }
        score.duplicatePairs = duplicatePairs(Array(bulletsBySection.values.joined()))
        score.openingIsSpecific = isSpecific(opening.joined(separator: " "), speakers: speakers)
        return score
    }

    /// The two confusions the owner saw: intentions under "Состояние и цифры", and "необходимо
    /// переносить запуск" under "Решения".
    static func misfiled(_ bullet: String, in section: Section) -> Bool {
        let value = bullet.lowercased()
        let starts = { (markers: [String]) in
            // Only the opening of the line decides; "решили, что нужно…" is still a decision.
            let head = String(value.prefix(40))
            return markers.contains { head.contains($0) }
        }
        // "стоит" opens a plan and a price alike — "стоит перенести запуск" against "тариф стоит
        // двадцать долларов" — and a measurement with nothing to do in it is not a misfiled plan.
        // This is the same test the filing stage applies, so the two agree by construction: the
        // count below is a residual, not an independent opinion.
        guard StructuredSummary.hasAction(bullet) else { return false }
        switch section {
        case .facts:
            // A measurement carries a figure. An intention carries a verb of wanting.
            return starts(intentionMarkers) && !starts(settledMarkers)
        // A topic passage holds the same statements the two sections above would have held, so it
        // is held to the same rule: a sentence that only wants something done belonged in the task
        // table, and the routing stage was supposed to have put it there.
        case .decisions, .topics:
            return starts(intentionMarkers) && !starts(settledMarkers)
        case .opening, .tasks, .questions:
            return false
        }
    }

    static func duplicatePairs(_ bullets: [String]) -> Int {
        let sets = bullets.map { tokens($0) }.filter { $0.count >= 3 }
        var pairs = 0
        for (index, first) in sets.enumerated() {
            for second in sets.dropFirst(index + 1) where similarity(first, second) >= duplicateSimilarity {
                pairs += 1
            }
        }
        return pairs
    }
    private static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        return union > 0 ? Double(a.intersection(b).count) / Double(union) : 0
    }
    /// Words that carry the point, without the grammar around it.
    /// Function words, and the words of obligation that open half of what gets said in a working
    /// call. Keeping the latter cost a real repeat: two bullets saying the same thing scored 0,667
    /// against a 0,7 threshold purely because one opened with "выглядит так, что нам надо" and the
    /// other with "нужно". Neither of those says what the point is.
    private static let stopWords: Set<String> = [
        "и", "в", "на", "с", "по", "для", "что", "как", "это", "не", "но", "а", "же", "типа",
        "то", "так", "уже", "ещё", "еще", "или", "из", "за", "от", "до", "при", "об", "про", "который", "которая",
        "надо", "нужно", "нам", "мне", "вам", "нас", "его", "всё", "все", "есть", "быть", "может",
        "выглядит", "кажется", "давай", "давайте", "просто", "вообще", "конечно", "короче",
    ]
    /// Splits a passage into the statements it was assembled from. A full stop that closes
    /// nothing — an initial, an abbreviation — does not end a sentence.
    static func sentences(_ text: String) -> [String] {
        var found: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            guard character == "." || character == "!" || character == "?" else { continue }
            let statement = current.trimmingCharacters(in: .whitespaces)
            if statement.count >= 3 {
                found.append(statement)
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { found.append(tail) }
        return found.isEmpty ? [text] : found
    }

    static func tokens(_ text: String) -> Set<String> {
        let stripped = text.replacingOccurrences(of: RichText.timePattern, with: " ", options: .regularExpression)
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
        return Set(stripped.split(separator: " ").map(String.init).filter { $0.count > 2 && !stopWords.contains($0) }
            // A crude stem: Russian endings differ between a paraphrase and its twin.
            .map { String($0.prefix(6)) })
    }

    /// An opening that could head any meeting ever held is not an opening. One of a figure, a name
    /// of somebody present, or a verb saying something was settled makes it this meeting's.
    static func isSpecific(_ opening: String, speakers: [String]) -> Bool {
        guard opening.count >= 40 else { return false }
        // A figure or a person. "Было решено сделать что-то нормальное" passed the first version
        // of this check on the strength of "решено" alone, which is how a generic opening slipped
        // through: saying that something was settled is not saying what.
        if !TextSafety.numberTokens(opening).isEmpty { return true }
        let value = opening.lowercased()
        return speakers.contains { speaker in
            let known = speaker.lowercased()
            return known.count > 2 && known != RecordingSession.ownerIdentity.lowercased() && value.contains(known)
        }
    }
}
