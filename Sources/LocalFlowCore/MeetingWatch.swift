import Foundation

/// Noticing that a call has started, so recording it is one press rather than one press and
/// remembering to make it.
///
/// Two signals together, both cheap and local: somebody other than this application is holding the
/// microphone, and an application people hold calls in is running. Either alone is noise — a
/// browser is always running, and a voice message holds the microphone for four seconds.
///
/// What this never does is start a recording. A conversation recorded because a machine guessed is
/// exactly the thing this application exists not to do; the offer is an offer.
public struct MeetingWatch: Equatable, Sendable {
    /// How long the microphone has to stay held before this is a conversation rather than a voice
    /// message, a "can you hear me" or a system sound check.
    public static let settle: TimeInterval = 25

    /// Applications people hold calls in. Browsers are here because Meet, Whereby and the rest
    /// live in them; on their own they mean nothing, which is why the microphone has to be busy
    /// as well.
    public static let conferencing: Set<String> = [
        "us.zoom.xos", "us.zoom.ZoomClips",
        "com.microsoft.teams", "com.microsoft.teams2", "com.microsoft.SkypeForBusiness",
        "com.cisco.webexmeetingsapp", "com.webex.meetingmanager",
        "com.hnc.Discord", "com.tinyspeck.slackmacgap", "com.skype.skype",
        "ru.keepcoder.Telegram", "org.telegram.desktop", "com.apple.FaceTime",
        "net.whatsapp.WhatsApp", "com.readdle.spark.mac",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.apple.Safari", "org.mozilla.firefox", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.brave.Browser", "com.operasoftware.Opera",
    ]
    public static func isConferencing(_ bundleIdentifiers: [String]) -> Bool {
        bundleIdentifiers.contains { conferencing.contains($0) }
    }

    /// When the current run of microphone activity began, or nil when nothing is holding it.
    public private(set) var since: Date?
    /// The run the owner has already dealt with — by recording it, or by waving it away.
    private var answered: Date?

    public init() {}

    /// Whether an offer should be on screen now.
    ///
    /// `busy` is this application recording or processing: it holds the microphone itself, and an
    /// offer to record what it is already recording is nonsense.
    public mutating func update(inputBusy: Bool, conferencing: Bool, busy: Bool, now: Date = Date()) -> Bool {
        guard inputBusy, conferencing else {
            // The call ended, or whatever held the microphone let go. The next run is a new call
            // and gets a new offer.
            since = nil
            return false
        }
        if since == nil { since = now }
        guard let since, !busy, answered != since else { return false }
        return now.timeIntervalSince(since) >= Self.settle
    }

    /// The owner has recorded this call or waved the offer away; say nothing more about this one.
    public mutating func answer() { answered = since }
}
