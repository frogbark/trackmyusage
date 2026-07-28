import Foundation

/// What a migration run did, so the next one can be cheap.
///
/// The receipt is an optimisation, never the authority. Every step re-checks its own
/// precondition regardless, so a receipt that is lost, truncated or written by a version
/// that knew about fewer steps still converges — the same stance `WallpaperState.load`
/// takes when its file is corrupt.
public struct MigrationReceipt: Codable, Equatable, Sendable {

    /// Bumped when a new step is added, so an install that migrated under an older version
    /// is re-probed rather than assumed finished.
    public static let currentVersion = 1

    public let version: Int
    public let outcomes: [String: StepOutcome]

    public init(version: Int = MigrationReceipt.currentVersion, outcomes: [String: StepOutcome]) {
        self.version = version
        self.outcomes = outcomes
    }

    /// True only when this receipt was written by the current version and nothing failed.
    ///
    /// A failed step leaves the receipt behind but not "complete", so the next launch
    /// retries precisely that step instead of the whole migration.
    public var isComplete: Bool {
        version == Self.currentVersion && !outcomes.values.contains { $0.isFailure }
    }

    public func outcome(for step: MigrationStep) -> StepOutcome? { outcomes[step.rawValue] }
}

public enum StepOutcome: Codable, Equatable, Sendable {
    case done
    /// Nothing to do, or a precondition that is legitimately unmet. Carries the reason so
    /// `tmu doctor` can say why rather than showing a blank.
    case skipped(String)
    case failed(String)

    public var isFailure: Bool { if case .failed = self { return true } else { return false } }

    public var summary: String {
        switch self {
        case .done: return "done"
        case .skipped(let why): return "skipped — \(why)"
        case .failed(let why): return "failed — \(why)"
        }
    }
}
