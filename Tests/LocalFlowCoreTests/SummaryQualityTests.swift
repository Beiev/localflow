import XCTest
@testable import LocalFlowCore

final class SummaryQualityTests: XCTestCase {
    private let source = """
    [00:10] Паша: Готовность на уровне 30 процентов, осталось 12 пунктов.
    [01:20] Лена: Договорились поднять первый порог до 2,5.
    [02:30] Паша: Я сделаю схему к среде.
    """

    func testIntentionsFiledUnderNumbersAreCountedAsMisfiled() {
        let summary = """
        ## Состояние и цифры
        - Готовность на уровне 30% [00:10]
        - Нужно попробовать поднять порог [01:20]
        - Надо поискать подрядчика [01:20]
        """
        let score = SummaryQuality.score(summary, source: source, duration: 200)
        XCTAssertEqual(score.bullets, 3)
        XCTAssertEqual(score.misfiledBullets, 2)
        XCTAssertEqual(score.sectionPurity, 1.0 / 3, accuracy: 0.001)
    }
    /// "Решили, что нужно…" is still a decision: only the opening of the line decides.
    func testASettledDecisionSurvivesAnIntentionWordInsideIt() {
        let summary = """
        ## Решения
        - Договорились, что нужно поднять порог [01:20]
        - Необходимо искать новых клиентов [01:20]
        """
        let score = SummaryQuality.score(summary, source: source, duration: 200)
        XCTAssertEqual(score.misfiledBullets, 1)
    }
    /// Three attempts at a citation, one usable: a moment past the end of the recording cannot be
    /// opened, and `[134]` is raw seconds the interface cannot resolve either. Both belong in the
    /// denominator, or a document looks perfectly cited by failing silently.
    func testOnlyCitationsThatOpenTheAudioCount() {
        let summary = "## Решения\n- Подняли порог [01:20]\n- И ещё [99:00]\n- И вот [134]"
        let score = SummaryQuality.score(summary, source: source, duration: 200)
        XCTAssertEqual(score.citations, 3)
        XCTAssertEqual(score.resolvableCitations, 1)
        XCTAssertEqual(score.citationValidity, 1.0 / 3, accuracy: 0.001)
    }
    func testAFigureNobodySaidIsNotGrounded() {
        let summary = "## Состояние и цифры\n- Готовность 30% [00:10]\n- Выручка 5000 [00:10]"
        let score = SummaryQuality.score(summary, source: source, duration: 200)
        XCTAssertEqual(score.numbers, 2)
        XCTAssertEqual(score.groundedNumbers, 1)
    }
    /// A citation's own digits are the clock, not a claim, and must not be scored as invented.
    func testCitationDigitsAreNotCountedAsFigures() {
        let score = SummaryQuality.score("## Решения\n- Подняли порог [01:20]", source: source, duration: 200)
        XCTAssertEqual(score.numbers, 0)
        XCTAssertEqual(score.numberFidelity, 1)
    }
    func testParaphrasedRepeatsAreCountedOnce() {
        let summary = """
        ## Решения
        - Решили поднять первый порог до 2,5 [01:20]
        ## Открытые вопросы
        - Первый порог решили поднять до 2,5 [01:20]
        - Кто возьмёт подрядчика [02:30]
        """
        let score = SummaryQuality.score(summary, source: source, duration: 200)
        XCTAssertEqual(score.duplicatePairs, 1)
    }
    func testDifferentPointsAreNotDuplicates() {
        let summary = """
        ## Решения
        - Решили поднять первый порог [01:20]
        - Решили перенести запуск на следующую неделю [02:30]
        """
        XCTAssertEqual(SummaryQuality.score(summary, source: source, duration: 200).duplicatePairs, 0)
    }
    func testTasksHandedToADiarizerLabelAreCounted() {
        let summary = """
        ## Задачи
        - Участник 1: собрать схему [02:30]
        - Паша: найти домен [02:30]
        - Собеседник: позвонить подрядчику [02:30]
        """
        let score = SummaryQuality.score(summary, source: source, duration: 200)
        XCTAssertEqual(score.tasks, 3)
        XCTAssertEqual(score.tasksWithGenericOwner, 2)
        XCTAssertEqual(score.ownerClarity, 1.0 / 3, accuracy: 0.001)
    }
    func testAnOpeningThatWouldFitAnyMeetingIsNotSpecific() {
        let generic = "## О чём\nОбсуждение касается текущей ситуации, а также работы над инфраструктурой и содержанием."
        XCTAssertFalse(SummaryQuality.score(generic, source: source, duration: 200).openingIsSpecific)
    }
    /// A figure or a person, and nothing else will do. Saying that something was settled is not
    /// saying what was settled: "было решено сделать что-то нормальное" is how a generic opening
    /// slipped past the first version of this check.
    func testOnlyAFigureOrAPersonMakesAnOpeningSpecific() {
        func opening(_ text: String) -> Bool {
            SummaryQuality.score("## О чём\n" + text, source: source, duration: 200, speakers: ["Паша", "Лена"]).openingIsSpecific
        }
        XCTAssertTrue(opening("Готовность дошла до 30 процентов, и этого на запуск пока не хватает совсем."))
        XCTAssertTrue(opening("Лена собрала созвон, чтобы свести прогноз с фактом и назначить ответственных."))
        XCTAssertFalse(opening("Договорились поднять порог и перенести запуск, остальное решили потом."))
        XCTAssertFalse(opening("Было решено сделать что-то нормальное, а остальное обсудить позже отдельно."))
        XCTAssertFalse(opening("Встреча была посвящена рабочим вопросам и дальнейшему взаимодействию сторон."))
    }
    func testHeadingsAreRecognizedByWordingNotPosition() {
        let summary = """
        ## Задачи
        - Паша: схема [02:30]
        ## Состояние и цифры
        - Готовность 30% [00:10]
        ## Открытые вопросы
        - Кто подрядчик [02:30]
        """
        XCTAssertEqual(SummaryQuality.score(summary, source: source, duration: 200).sections,
                       ["tasks", "facts", "questions"])
    }
    /// "Открытые вопросы" must not be read as a decisions heading just because it contains a word
    /// that another section also uses.
    func testOpenQuestionsHeadingIsNotADecisionsHeading() {
        XCTAssertEqual(SummaryQuality.Section.match("Открытые вопросы"), .questions)
        XCTAssertEqual(SummaryQuality.Section.match("Решения"), .decisions)
        XCTAssertEqual(SummaryQuality.Section.match("О чём"), .opening)
        XCTAssertNil(SummaryQuality.Section.match("Приложение"))
    }
    func testCompressionIsReportedAgainstTheSource() {
        let score = SummaryQuality.score(String(repeating: "а", count: 100), source: String(repeating: "б", count: 1000), duration: 10)
        XCTAssertEqual(score.compression, 0.1, accuracy: 0.0001)
    }
    func testAnEmptySummaryScoresWithoutDividingByZero() {
        let score = SummaryQuality.score("", source: source, duration: 200)
        XCTAssertEqual(score.bullets, 0)
        XCTAssertEqual(score.sectionPurity, 1)
        XCTAssertEqual(score.citationValidity, 1)
        XCTAssertEqual(score.ownerClarity, 1)
        XCTAssertFalse(score.openingIsSpecific)
    }
}

/// Fidelity and coverage are different errors: inventing a figure, and losing one.
final class SummaryNumberCoverageTests: XCTestCase {
    private let source = """
    [00:10] Паша: Готовность тридцать процентов, осталось 12 пунктов.
    [01:20] Лена: Порог поднимаем до 2,5, бюджет 1500.
    """
    func testCoverageCountsTheConversationsFiguresThatReachedTheDocument() {
        let score = SummaryQuality.score("## Состояние и цифры\n- Осталось 12 пунктов, порог 2,5 [00:10]",
                                         source: source, duration: 120)
        // Три цифры в речи: 12, 2,5 и 1500. «Тридцать» словом цифрой не считается, отметки
        // времени и метки говорящих в счёт не идут.
        XCTAssertEqual(score.sourceNumbers, 3)
        XCTAssertEqual(score.coveredNumbers, 2)
        XCTAssertEqual(score.numberCoverage, 2.0 / 3, accuracy: 0.001)
        XCTAssertEqual(score.numberFidelity, 1, "ничего не выдумано")
    }
    /// A summary with no figures at all satisfies fidelity and fails coverage, which is the point.
    func testADocumentWithNoFiguresHasPerfectFidelityAndNoCoverage() {
        let score = SummaryQuality.score("## Решения\n- Порог решили поднять [00:10]", source: source, duration: 120)
        XCTAssertEqual(score.numberFidelity, 1)
        XCTAssertEqual(score.coveredNumbers, 0)
        XCTAssertEqual(score.numberCoverage, 0)
    }
    func testASourceWithoutFiguresCannotFailCoverage() {
        XCTAssertEqual(SummaryQuality.score("## Решения\n- Договорились [00:10]",
                                            source: "[00:10] Паша: договорились", duration: 60).numberCoverage, 1)
    }
}

final class SummarySourceSpeechTests: XCTestCase {
    /// The scaffolding of a transcript line carries digits of its own: the clock, and a diarizer
    /// label like "Участник 1". Counting those made a summary that says "Участник 1: сделать
    /// схему" look as though its figures came from the conversation.
    func testSpeechDropsTimestampsAndSpeakerLabels() {
        let transcript = "[04:41] Участник 1: записали 370 строк\n[07:23] Я: да"
        XCTAssertEqual(SummaryQuality.speech(of: transcript), " записали 370 строк\n да")
    }
    func testLabelDigitsAreNotTreatedAsFiguresOfTheConversation() {
        let transcript = "[04:41] Участник 1: ничего числового тут нет"
        let score = SummaryQuality.score("## Задачи\n- Участник 1: собрать структуру сайта [04:41]",
                                         source: transcript, duration: 300)
        XCTAssertEqual(score.sourceNumbers, 0)
        XCTAssertEqual(score.groundedNumbers, 0, "«1» из метки говорящего — не цифра разговора")
        XCTAssertEqual(score.numbers, 1)
        XCTAssertEqual(score.numberFidelity, 0)
    }
    func testAPlainTranscriptWithoutLabelsIsLeftAlone() {
        XCTAssertEqual(SummaryQuality.speech(of: "просто текст без отметок"), "просто текст без отметок")
    }
}

/// The metric reading a document built from topics rather than from flat sections.
final class SummaryQualityTopicTests: XCTestCase {
    private let source = """
    [00:10] Паша: Удержание тридцать процентов, из четырёх заявок три закрыли.
    [01:10] Лена: Поднимаем первый порог до двух тысяч.
    [12:30] Паша: Домен переносим на новый тариф, платим до пятницы.
    """
    private let document = """
    ## О чём

    Участники: Паша, Лена. Решения: 2. Задачи: 0. Открытые вопросы: 0.

    ## По темам

    ### Удержание и заявки

    Поднимаем первый порог до двух тысяч [01:10]. Удержание тридцать процентов [00:10]. Из четырёх заявок три закрыли [00:10].

    ### Хостинг и домен

    Домен переносим на новый тариф [12:30]. Платим до пятницы [12:30].
    """

    func testEachStatementInAPassageIsCountedSeparately() {
        let score = SummaryQuality.score(document, source: source, duration: 800, speakers: ["Паша", "Лена"])
        XCTAssertTrue(score.sections.contains("topics"))
        XCTAssertEqual(score.bullets, 5, "пять утверждений, а не два абзаца")
        XCTAssertEqual(score.citations, score.resolvableCitations)
        XCTAssertEqual(score.numberFidelity, 1, "цифры из разговора, а не выдуманные")
    }
    /// A topic's own heading names a topic. Read as a section heading it would hand every later
    /// statement to the wrong counter — "Решение по подрядчику" is a topic, not the decisions.
    func testATopicHeadingDoesNotSwitchSections() {
        let risky = document.replacingOccurrences(of: "### Хостинг и домен", with: "### Решение по домену")
        let score = SummaryQuality.score(risky, source: source, duration: 800, speakers: ["Паша", "Лена"])
        XCTAssertEqual(score.sections, ["opening", "topics"])
        XCTAssertEqual(score.bullets, 5)
    }
    /// A passage is not the opening: the opening check has to stay about the opening.
    func testPassagesDoNotLeakIntoTheOpening() {
        let score = SummaryQuality.score(document, source: source, duration: 800, speakers: ["Паша", "Лена"])
        XCTAssertTrue(score.openingIsSpecific)
        let anonymous = document.replacingOccurrences(of: "Участники: Паша, Лена. Решения: 2. Задачи: 0. Открытые вопросы: 0.",
                                                      with: "Обсудили текущую ситуацию и договорились о дальнейших шагах.")
        XCTAssertFalse(SummaryQuality.score(anonymous, source: source, duration: 800).openingIsSpecific,
                       "абзацы тем не делают пустое вступление конкретным")
    }
    /// A legacy summary writes its section headings in bold, which parse as level three. The rule
    /// that lets a topic keep its subheadings must not stop those from switching sections.
    func testBoldHeadingsOfAnArchivedSummaryStillSwitchSections() {
        let legacy = """
        **О чём**

        Короткий разговор о порогах и удержании с Пашей.

        **Решения**

        - Поднимаем первый порог до двух тысяч [01:10]

        **Задачи**

        - Участник 1: Перенести домен [12:30]
        """
        let score = SummaryQuality.score(legacy, source: source, duration: 800, speakers: ["Паша", "Лена"])
        XCTAssertEqual(score.sections, ["opening", "decisions", "tasks"])
        XCTAssertEqual(score.tasks, 1)
        XCTAssertEqual(score.tasksWithGenericOwner, 1)
    }
}
