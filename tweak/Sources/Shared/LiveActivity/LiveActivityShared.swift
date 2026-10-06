// Compiled into both the tweak and extension/LiveActivity: ActivityKit pairs the two sides by the
// attributes' type name and App Intents by the intent's, so this must stay identical in both.
import ActivityKit
import AppIntents
import Foundation

@available(iOS 16.1, *)
struct SGLyricsAttributes: ActivityAttributes {
    // Which of the three the activity shows, SGLiveActivityView's values.
    enum View: Int, Codable, Hashable {
        case lyrics, queue, panel
    }

    // The control menu's tabs.
    enum Tab: Int, Codable, Hashable, CaseIterable {
        case controls, queue, timer
    }

    struct Track: Codable, Hashable {
        var title: String
        var artist: String
        // What a tap on the track asks the player for.
        var uri: String
    }

    struct ContentState: Codable, Hashable {
        var view: View
        var paused: Bool
        // Lyrics: the line being sung and the one after it.
        var line: String
        var nextLine: String
        // Queue, and the control menu's queue tab: the tracks up next.
        var tracks: [Track]
        // The control menu.
        var tab: Tab
        var title: String
        var artist: String
        var shuffle: Bool
        var repeatMode: Int   // 0 off, 1 the playlist or album, 2 the track
        var timerEnd: Date?   // the sleep timer's end, nil when none is set
        var timerEndOfTrack: Bool
        // The cover's colour as RRGGBB, darkened for white text; nil before it is read.
        var tint: String?
        // When the track started and ends at the speed it plays, for a progress bar that runs by itself;
        // nil when the length is not known. Paused, the bar holds at `pausedAt`.
        var trackStart: Date?
        var trackEnd: Date?
        var pausedAt: Double?
        // The line's translation, when the lyrics have one and translations are shown.
        var translation: String?
        // The cover as a JPEG of a few dozen pixels a side, nil before it is read or when it does not fit.
        // Optional, as everything added later is, so an activity left by the build before still decodes.
        var cover: Data?
        // The lyrics' size, SGLiveActivityTextSize's values: 0 small, 1 medium, 2 large.
        var textSize: Int?
        // The sleep timer pauses at the end of the album or playlist playing.
        var timerEndOfAlbum: Bool?
    }
}

// The same activity under a second name. Apple Watch and CarPlay show an activity's own small layout
// only when its widget declares that family, which only an iOS 18 widget can, and a widget built for
// iOS 17 still has to cover the old type. So from iOS 18 the tweak asks for this one, and the iOS 18
// widget is the one that answers it.
@available(iOS 16.1, *)
struct SGLyricsWatchAttributes: ActivityAttributes {
    typealias ContentState = SGLyricsAttributes.ContentState
}

// LiveActivityIntents run in the app's process, where the tweak acts on these notifications.
let SGLiveActivityPlayNotification = Notification.Name("SGLiveActivityPlay")
let SGLiveActivityActionNotification = Notification.Name("SGLiveActivityAction")

@available(iOS 17.0, *)
struct SGPlayQueuedTrackIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Play a track up next"
    static let isDiscoverable = false

    @Parameter(title: "Track")
    var uri: String

    init() {}

    init(_ uri: String) {
        self.uri = uri
    }

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: SGLiveActivityPlayNotification, object: uri)
        return .result()
    }
}

// A control menu action: tab:N, toggle, previous, next, shuffle, repeat, timer:15|30|60|track|album|add|cancel.
@available(iOS 17.0, *)
struct SGLiveActivityActionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Control menu action"
    static let isDiscoverable = false

    @Parameter(title: "Action")
    var action: String

    init() {}

    init(_ action: String) {
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: SGLiveActivityActionNotification, object: action)
        return .result()
    }
}
