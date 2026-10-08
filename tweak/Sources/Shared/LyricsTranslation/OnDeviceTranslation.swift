// The two ways to translate a song on the iPhone itself, for LyricsTranslation.h: Apple's Translation
// framework (iOS 26, with the languages downloaded in the Translate app) and Apple Intelligence's language
// model (iOS 26, on the iPhones that have it). Both are Swift only. Nothing leaves the phone.
import Foundation
import FoundationModels
import NaturalLanguage
import Translation

@objc(SGOnDeviceTranslation)
public final class SGOnDeviceTranslation: NSObject {
    // The model asked fresh for each run of this many lines, so a long song stays inside its context.
    private static let chunkLines = 40

    private static func finish(_ done: @escaping ([String]?, String?) -> Void, _ lines: [String]?, _ error: String?) {
        DispatchQueue.main.async { done(lines, error) }
    }

    private static func name(_ language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    // The song's language, from its words.
    private static func sourceLanguage(_ lines: [String]) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(lines.joined(separator: "\n"))
        guard let found = recognizer.dominantLanguage, found != .undetermined else { return nil }
        return Locale.Language(identifier: found.rawValue)
    }

    private static func same(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        a.languageCode == b.languageCode
    }

    // MARK: Translation framework

    @objc public static var translationAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    // One translation per line, "" for a line with no words; or nil and why not.
    @objc public static func translate(_ lines: [String], to languageTag: String, done: @escaping ([String]?, String?) -> Void) {
        guard #available(iOS 26.0, *) else { return finish(done, nil, "Translating on this iPhone needs iOS 26.") }
        let target = Locale.Language(identifier: languageTag)
        guard let source = sourceLanguage(lines) else { return finish(done, nil, "The song's language could not be told from its words.") }
        if same(source, target) { return finish(done, nil, "The song is already in \(name(target)).") }
        Task {
            switch await LanguageAvailability().status(from: source, to: target) {
            case .unsupported:
                return finish(done, nil, "Apple's Translate does not translate \(name(source)) into \(name(target)).")
            case .supported:
                return finish(done, nil, "Download \(name(source)) and \(name(target)) in Settings > Apps > Translate > Languages, then try again.")
            case .installed:
                break
            @unknown default:
                break
            }
            let requests = lines.enumerated().compactMap { index, line in
                line.trimmingCharacters(in: .whitespaces).isEmpty || line == "♪" ? nil
                    : TranslationSession.Request(sourceText: line, clientIdentifier: String(index))
            }
            do {
                let session = TranslationSession(installedSource: source, target: target)
                var out = [String](repeating: "", count: lines.count)
                for response in try await session.translations(from: requests) {
                    if let id = response.clientIdentifier, let index = Int(id) { out[index] = response.targetText }
                }
                finish(done, out, nil)
            } catch {
                finish(done, nil, "Apple's Translate could not translate the song (\(error.localizedDescription)).")
            }
        }
    }

    // MARK: Apple Intelligence

    @available(iOS 26.0, *)
    private static var model: SystemLanguageModel {
        // Lyrics are often explicit: the guardrails for changing text the user already has, not for writing new.
        SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    }

    @objc public static func appleIntelligenceAvailable(_ languageTag: String) -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        let target = Locale.Language(identifier: languageTag)
        return model.availability == .available && model.supportedLanguages.contains { same($0, target) }
    }

    @objc public static func translateWithAppleIntelligence(_ lines: [String], to languageTag: String, done: @escaping ([String]?, String?) -> Void) {
        guard #available(iOS 26.0, *) else { return finish(done, nil, "Apple Intelligence needs iOS 26.") }
        let language = name(Locale.Language(identifier: languageTag))
        Task {
            var out: [String] = []
            do {
                for start in stride(from: 0, to: lines.count, by: chunkLines) {
                    let chunk = Array(lines[start..<min(start + chunkLines, lines.count)])
                    out += try await translateChunk(chunk, into: language)
                }
                finish(done, out, nil)
            } catch {
                finish(done, nil, problem(error))
            }
        }
    }

    // iOS 27 throws LanguageModelError, iOS 26 the session's GenerationError.
    @available(iOS 26.0, *)
    private static func problem(_ error: Error) -> String {
        let declined = "Apple Intelligence declined to translate this song's lyrics."
        let tooLong = "The song is too long for Apple Intelligence."
        let language = "Apple Intelligence does not work in this language."
        if #available(iOS 27.0, *), let error = error as? LanguageModelError {
            switch error {
            case .guardrailViolation, .refusal: return declined
            case .contextSizeExceeded: return tooLong
            case .unsupportedLanguageOrLocale: return language
            default: break
            }
        } else if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal: return declined
            case .exceededContextWindowSize: return tooLong
            case .unsupportedLanguageOrLocale: return language
            default: break
            }
        }
        return "Apple Intelligence could not translate the song (\(error.localizedDescription))."
    }

    // Exactly one string per line, held to the count by the schema rather than read out of free text.
    @available(iOS 26.0, *)
    private static func translateChunk(_ lines: [String], into language: String) async throws -> [String] {
        let session = LanguageModelSession(model: model, instructions: """
            You translate song lyrics into \(language). You get a JSON array of lines and answer with an array of \
            the same length: each line's translation at the same place, natural as sung, keeping the meaning of \
            slang and idioms. A line that is empty, a sound or already in \(language) is given back as it is.
            """)
        let line = DynamicGenerationSchema(type: String.self)
        let schema = try GenerationSchema(root: DynamicGenerationSchema(arrayOf: line, minimumElements: lines.count, maximumElements: lines.count),
                                          dependencies: [])
        let prompt = String(decoding: try JSONSerialization.data(withJSONObject: lines), as: UTF8.self)
        let answer = try await session.respond(to: prompt, schema: schema).content.value([String].self)
        return answer.count == lines.count ? answer : lines.indices.map { $0 < answer.count ? answer[$0] : "" }
    }
}
