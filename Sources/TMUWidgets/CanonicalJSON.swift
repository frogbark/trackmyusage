import Foundation

/// The encoder every published and generated JSON goes through.
///
/// `.sortedKeys` is not cosmetic and this is not a style preference. `JSONEncoder` builds its
/// output from a dictionary, so by default the *same value* encodes to different bytes on
/// consecutive calls:
///
///     {"tz":{"identifier":"GMT"},"d":805692800,"x":62}
///     {"x":62,"tz":{"identifier":"GMT"},"d":805692800}
///
/// Two things depend on that not happening. `web/widgets.json` is byte-compared by
/// `check-generated.sh` — it is the text artifact that replaced the wallpaper SVGs and the
/// only reason a layout regression still fails CI — and unsorted keys would make it differ on
/// every run, failing for a reason no commit could fix. And `WidgetPublisher` skips writing
/// when the encoded model is unchanged, which is simply wrong if the encoding is unstable.
///
/// This is the same class of bug as the two the codebase already guards against by freezing
/// `DemoSnapshots.generatedAt` and by carrying `timeZone` in the model: output that looks
/// deterministic, is not, and only says so intermittently.
public enum CanonicalJSON {

    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        return encoder
    }

    public static func encode(_ value: some Encodable, pretty: Bool = false) throws -> Data {
        try encoder(pretty: pretty).encode(value)
    }
}
