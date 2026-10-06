// ActivityKit is Swift only, so LiveActivity.x reaches it through this class.
import ActivityKit
import Foundation
import os

@available(iOS 17.0, *)
@objc(SGLiveActivityBridge)
public final class SGLiveActivityBridge: NSObject {
    private static let log = Logger(subsystem: "spotifyglass", category: "live activity")
    // Under ActivityKit's 4096, with room for its own wrapping.
    private static let maxStateBytes = 3800
    // Each state is stale this long after it is sent: three times LiveActivity.x's kRefresh, which sends
    // even an unchanged card again, so only a card Spotify can no longer feed goes stale.
    private static let staleAfter: TimeInterval = 60

    private typealias State = SGLyricsAttributes.ContentState

    // Either type's activities: one left from before an update to iOS 18 carries on under its own.
    private static func live<A>(_ activities: [Activity<A>]) -> [String] {
        activities.filter { $0.activityState == .active || $0.activityState == .stale }.map(\.id)
    }

    private static var showing: [String] {
        live(Activity<SGLyricsAttributes>.activities) + live(Activity<SGLyricsWatchAttributes>.activities)
    }

    @objc public static var isShowing: Bool { !showing.isEmpty }

    // Updates and ends go out one at a time in the order asked for, since ActivityKit applies
    // concurrent ones in whatever order they finish. An update still waiting gives way to a newer one.
    private enum Change: Sendable {
        case update(String, ActivityContent<State>)
        case end([String])
    }

    private struct Pending: Sendable {
        var changes: [Change] = []
        var sending = false
        // When the change being sent went out. One ActivityKit never answers would otherwise hold every
        // later change behind it and freeze the card; past kStuckAfter a new sender takes over.
        var sentAt: Date?
    }

    private static let kStuckAfter: TimeInterval = 5

    private static let pending = OSAllocatedUnfairLock(initialState: Pending())

    private static func queue(_ change: Change) {
        let start = pending.withLock { pending in
            if case .update(let id, _) = change, case .update(let waiting, _)? = pending.changes.last, waiting == id {
                pending.changes.removeLast()
            }
            pending.changes.append(change)
            if pending.sending, let at = pending.sentAt, Date().timeIntervalSince(at) < kStuckAfter { return false }
            if pending.sending { log.notice("[spotifyglass] live activity: an update has not landed in \(kStuckAfter, privacy: .public) s, sending on past it") }
            pending.sending = true
            pending.sentAt = nil
            return true
        }
        if start { Task { await send() } }
    }

    private static func send() async {
        while let change = pending.withLock({ pending -> Change? in
            if pending.changes.isEmpty {
                pending.sending = false
                pending.sentAt = nil
                return nil
            }
            pending.sentAt = Date()
            return pending.changes.removeFirst()
        }) {
            switch change {
            case .update(let id, let content):
                await Activity<SGLyricsAttributes>.activities.first { $0.id == id }?.update(content)
                await Activity<SGLyricsWatchAttributes>.activities.first { $0.id == id }?.update(content)
            case .end(let ids):
                for activity in Activity<SGLyricsAttributes>.activities where ids.contains(activity.id) {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
                for activity in Activity<SGLyricsWatchAttributes>.activities where ids.contains(activity.id) {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
    }

    // A new activity can only be requested while the app is in the foreground; an update works from the background.
    // One call per new state. View and tab are SGLiveActivityView's and SGLiveActivityTab's values;
    // titles, artists and URIs pair up by index, the tracks up next; timerEnd is nil without a timer.
    @objc public static func show(view: Int, paused: Bool, line: String, nextLine: String,
                                  titles: [String], artists: [String], uris: [String],
                                  tab: Int, title: String, artist: String, shuffle: Bool, repeatMode: Int,
                                  timerEnd: Date?, timerEndOfTrack: Bool,
                                  tint: String?, trackStart: Date?, trackEnd: Date?, pausedAt: NSNumber?, translation: String?,
                                  cover: Data?, textSize: Int) {
        let tracks = titles.indices.map {
            SGLyricsAttributes.Track(title: titles[$0], artist: artists[$0], uri: uris[$0])
        }
        var state = SGLyricsAttributes.ContentState(
            view: SGLyricsAttributes.View(rawValue: view) ?? .lyrics, paused: paused,
            line: line, nextLine: nextLine, tracks: tracks,
            tab: SGLyricsAttributes.Tab(rawValue: tab) ?? .controls, title: title, artist: artist,
            shuffle: shuffle, repeatMode: repeatMode, timerEnd: timerEnd, timerEndOfTrack: timerEndOfTrack,
            tint: tint, trackStart: trackStart, trackEnd: trackEnd, pausedAt: pausedAt?.doubleValue,
            translation: translation, cover: cover, textSize: textSize)
        // ActivityKit drops a state over 4 KB without a word and the card freezes, so with long lines and
        // a busy cover the cover gives way.
        if cover != nil, let size = try? JSONEncoder().encode(state).count, size > maxStateBytes {
            state.cover = nil
            log.notice("[spotifyglass] live activity: \(size, privacy: .public) bytes, sent without the cover")
        }
        let content = ActivityContent(state: state, staleDate: Date(timeIntervalSinceNow: staleAfter))
        if let id = showing.first {
            queue(.update(id, content))
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log.notice("[spotifyglass] live activity: activities are off for this app")
            return
        }
        do {
            let id: String
            if #available(iOS 18.0, *) {
                id = try Activity.request(attributes: SGLyricsWatchAttributes(), content: content, pushType: nil).id
            } else {
                id = try Activity.request(attributes: SGLyricsAttributes(), content: content, pushType: nil).id
            }
            log.notice("[spotifyglass] live activity: started \(id, privacy: .public)")
        } catch {
            log.error("[spotifyglass] live activity: request failed: \(String(describing: error), privacy: .public)")
        }
    }

    // Named now, so an activity requested after this call is not ended with them.
    @objc public static func end() {
        queue(.end(Activity<SGLyricsAttributes>.activities.map(\.id) + Activity<SGLyricsWatchAttributes>.activities.map(\.id)))
    }

    // At termination: ends them all, past the queue, and holds the calling thread until they are ended,
    // two seconds at most, since the process is gone once the notification returns and an end still in
    // flight goes with it. The cap also keeps an ActivityKit that waits on the main thread from hanging it.
    @objc public static func endBeforeExit() {
        if showing.isEmpty { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for activity in Activity<SGLyricsAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            for activity in Activity<SGLyricsWatchAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            done.signal()
        }
        if done.wait(timeout: .now() + 2) == .timedOut {
            log.notice("[spotifyglass] live activity: not ended in time at exit")
        }
    }
}
