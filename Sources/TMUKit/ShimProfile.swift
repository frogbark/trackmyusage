import Foundation

/// Recovering the profile path an instance was built with.
///
/// `create-instance.sh` compiles the launcher shim with
/// `-DUSER_DATA_DIR="$HOME/Library/Application Support/Claudruple/$NAME"`, and launcher.c
/// concatenates it with the flag at compile time. The resulting string is the *only* record
/// of where an instance keeps its profile: it is fixed in a binary at the moment the
/// instance was created and cannot be changed by editing Swift.
///
/// That makes it the one thing worth reading back. `InstanceLocator.profileURL` derives what
/// the CLI *believes* the path is; this reads what the app will *actually* use. If the two
/// disagree, every reading the CLI reports belongs to a directory nothing writes to — and
/// nothing anywhere raises an error, which is why `LegacyNames` calls this the most
/// dangerous of the frozen names.
public enum ShimProfile {

    /// The flag, exactly as launcher.c spells it.
    static let flag = "--user-data-dir="

    /// The path compiled into a shim binary, or nil if there is not one.
    ///
    /// Takes bytes rather than a path so the scanning is testable without a Mach-O on disk.
    public static func path(inBinary data: Data) -> String? {
        let needle = Array(flag.utf8)
        var found: [String] = []
        var index = data.startIndex

        while let match = search(data, needle, from: index) {
            // The literal runs to the next NUL, as C strings do.
            var end = match + needle.count
            while end < data.endIndex, data[end] != 0 { end += 1 }
            let value = data[(match + needle.count)..<end]
            if !value.isEmpty, let text = String(data: value, encoding: .utf8) {
                found.append(text)
            }
            index = match + needle.count
        }

        // The binary holds the flag twice: once concatenated with the path, and once bare,
        // because the shim compares incoming arguments against it. The linker is under no
        // obligation to order them, so taking the first match yields the empty one about
        // half the time — hence "longest non-empty" rather than "first".
        return found.max(by: { $0.count < $1.count })
    }

    /// The path compiled into an instance's shim.
    public static func path(ofShimAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return path(inBinary: data)
    }

    private static func search(_ haystack: Data, _ needle: [UInt8], from: Data.Index)
        -> Data.Index?
    {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let limit = haystack.endIndex - needle.count
        var i = max(from, haystack.startIndex)
        while i <= limit {
            if haystack[i] == needle[0] {
                var j = 1
                while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }
}
