import Foundation
import Observation
import QuillCore

/// Settings live in UserDefaults — they are user-authored configuration, never
/// user content. No text ever reaches this store.
@MainActor
@Observable
public final class SettingsStore {
    public static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let tone = "quill.tone"
        static let aggressiveness = "quill.aggressiveness"
        static let model = "quill.model"
        static let paused = "quill.paused"
        static let excluded = "quill.excludedBundleIDs"
        static let onboarded = "quill.hasCompletedOnboarding"
    }

    public var tone: ToneProfile {
        didSet { defaults.set(tone.rawValue, forKey: Key.tone) }
    }
    public var aggressiveness: Aggressiveness {
        didSet { defaults.set(aggressiveness.rawValue, forKey: Key.aggressiveness) }
    }
    public var model: RewriteModel {
        didSet { defaults.set(model.rawValue, forKey: Key.model) }
    }
    public var isPaused: Bool {
        didSet { defaults.set(isPaused, forKey: Key.paused) }
    }
    public var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.onboarded) }
    }
    public var excludedBundleIDs: Set<String> {
        didSet { defaults.set(Array(excludedBundleIDs), forKey: Key.excluded) }
    }

    private init() {
        tone = defaults.string(forKey: Key.tone)
            .flatMap(ToneProfile.init(rawValue:)) ?? .neutral
        aggressiveness = defaults.string(forKey: Key.aggressiveness)
            .flatMap(Aggressiveness.init(rawValue:)) ?? .balanced
        // A persisted Claude model ID from an earlier build won't parse; the
        // `??` puts those users on Terra rather than leaving `model` unset.
        model = defaults.string(forKey: Key.model)
            .flatMap(RewriteModel.init(rawValue:)) ?? .terra
        isPaused = defaults.bool(forKey: Key.paused)
        hasCompletedOnboarding = defaults.bool(forKey: Key.onboarded)
        excludedBundleIDs = (defaults.array(forKey: Key.excluded) as? [String])
            .map(Set.init) ?? PolicyEngine.defaultExclusions
    }

    public var policy: PolicyEngine {
        PolicyEngine(excludedBundleIDs: excludedBundleIDs, isPaused: isPaused)
    }
}
