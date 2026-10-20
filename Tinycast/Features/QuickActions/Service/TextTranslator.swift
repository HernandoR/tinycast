import Foundation
import NaturalLanguage
import Translation

/// `TranslationError` is macOS 26.4 against a 26.0 floor, so failures stay plain `Error` here.
enum TextTranslator {
    enum Failure: LocalizedError, Equatable {
        case undetectableSource
        case unsupported
        case notInstalled(language: String)
        case failed

        var errorDescription: String? {
            switch self {
            case .undetectableSource:
                return String(localized: "The language of the selected text could not be identified.")
            case .unsupported:
                return String(localized: "Apple's translator does not support this language pair.")
            case .notInstalled(let language):
                return String(localized: "\(language) needs to be downloaded before it can be used.")
            case .failed:
                return String(localized: "The text could not be translated.")
            }
        }
    }

    /// `TranslationSession(installedSource:)` needs a language; availability reports only a status.
    static func sourceLanguage(of text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage, dominant != .undetermined else {
            return nil
        }
        return Locale.Language(identifier: dominant.rawValue)
    }

    /// What a pair can do here, because `.supported` and `.unsupported` mean different prompts.
    enum PairAvailability {
        case installed(source: Locale.Language, target: Locale.Language)
        case missing
        case unsupported
    }

    /// Installed pairs only: a missing language is downloaded in System Settings, never from here.
    static func translate(_ text: String, to target: Locale.Language) async throws -> String {
        guard let source = sourceLanguage(of: text) else { throw Failure.undetectableSource }
        guard !source.isEquivalent(to: target) else { return text }
        switch await pairAvailability(from: source, to: target) {
        case .installed(let installedSource, let installedTarget):
            do {
                let session = TranslationSession(
                    installedSource: installedSource, target: installedTarget)
                return try await session.translate(text).targetText
            } catch {
                throw Failure.failed
            }
        case .missing:
            let missing = await missingLanguage(from: source, to: target)
            throw Failure.notInstalled(language: displayName(of: missing))
        case .unsupported:
            throw Failure.unsupported
        }
    }

    /// A download is a locale, so the case a bare code resolves to can miss the one installed.
    static func pairAvailability(
        from source: Locale.Language, to target: Locale.Language
    ) async -> PairAvailability {
        let availability = LanguageAvailability()
        let supported = await availability.supportedLanguages
        var supportedPair = false
        for sourceVariant in variants(of: source, among: supported) {
            for targetVariant in variants(of: target, among: supported) {
                let status = await availability.status(from: sourceVariant, to: targetVariant)
                if status == .installed {
                    return .installed(source: sourceVariant, target: targetVariant)
                }
                if status == .supported { supportedPair = true }
            }
        }
        return supportedPair ? .missing : .unsupported
    }

    /// The prompt names one language, so it has to name the side that is actually missing.
    static func missingLanguage(
        from source: Locale.Language, to target: Locale.Language
    ) async -> Locale.Language {
        if await isInstalled(target) { return source }
        return target
    }

    /// An installed language pairs with something, so a working partner is proof it is downloaded.
    static func isInstalled(_ language: Locale.Language) async -> Bool {
        let availability = LanguageAvailability()
        let supported = await availability.supportedLanguages
        let candidates = variants(of: language, among: supported)
        for partner in supported where partner.languageCode != language.languageCode {
            for candidate in candidates {
                if await availability.status(from: partner, to: candidate) == .installed {
                    return true
                }
            }
        }
        return false
    }

    /// Region may move, since one English is another's asset, but a different script is a language.
    static func variants(
        of language: Locale.Language, among supported: [Locale.Language]
    ) -> [Locale.Language] {
        [language]
            + supported.filter {
                $0.languageCode == language.languageCode && $0.script == language.script
                    && !$0.isEquivalent(to: language)
            }
    }

    /// Minimal, not maximal: the maximal form would spell `es` "Spanish (Latin, Spain)" in a menu.
    static func displayName(of language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier)
            ?? language.minimalIdentifier
    }

    /// The framework's own list, so the picker cannot offer a pair that only fails at press time.
    static func supportedLanguages() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
            .sorted { displayName(of: $0) < displayName(of: $1) }
    }
}
