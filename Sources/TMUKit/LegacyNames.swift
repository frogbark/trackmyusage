/// Names from the Claudruple era that outlived the rename.
///
/// Every string here looks like one somebody forgot to update. None of them is. Each is
/// baked into something already on disk — a LaunchServices registration, a code signature,
/// a compiled-in path, a keychain item — so changing it does not rename anything. It makes
/// the existing thing unreachable, silently, with no error at any layer.
///
/// The rename that introduced this file broke two of these by accident, and the tests below
/// each constant are what caught it. The substitution protected the frozen strings wherever
/// they appeared as contiguous text; it could not see them where the code built them by
/// concatenation. That is the whole reason this file exists rather than a comment: a literal
/// assembled from parts is invisible to search-and-replace, and visible here.
///
/// If you are renaming things and one of these is in your way, route it through here.
public enum LegacyNames {

    /// The infix `create-instance.sh` puts in every clone's bundle id, between Claude's own
    /// prefix and the instance slug: `com.anthropic.claudefordesktop.claudruple.two`.
    ///
    /// The clone is *signed* with this id and registered with LaunchServices under it.
    /// Change it and `isClaudeInstance` stops recognising every instance that already
    /// exists — they do not break, they simply cease to be found.
    public static let instanceBundleInfix = "claudruple"

    /// Where clones are installed. Registered with LaunchServices, and named absolutely in
    /// the broker's LaunchAgent plist, which is not rewritten by a rebuild.
    public static let instancesDirectory = "/Applications/Claudruple"

    /// The directory under `~/Library/Application Support` that holds instance profiles.
    ///
    /// This one is the most dangerous of the four. `create-instance.sh` compiles it into
    /// each clone's launcher shim as `-DUSER_DATA_DIR`, so the value is fixed in a binary
    /// at the moment the instance was created and cannot be changed by editing Swift.
    /// Point Swift somewhere else and the CLI inspects a directory the app does not use,
    /// reporting a converged instance that is nothing of the sort; point the *shim*
    /// somewhere else and the account is signed out with every extension gone.
    public static let instanceProfileDirectory = "Claudruple"

    // The fourth frozen name — the pre-rename keychain service — deliberately does *not*
    // live here. It belongs to `TMUProviders.KeychainCredentials.legacyService`, in a target
    // that depends on nothing so it builds where Claude Desktop does not exist. Reaching
    // into TMUKit for a string constant would trade that away for tidiness.
}
