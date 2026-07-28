import Foundation
import TMUDesign

/// Brand assets, emitted from `BrandMark`'s geometry.
///
/// Nothing here is committed as a binary. One definition serves the app icon, the website
/// mark, the favicon and the social preview — which is the only way five renderings of a
/// logo stay identical over time.
enum AssetCommands {

    static func run(_ args: [String]) {
        switch args.first {
        case "mark":
            let size = args.count > 1 ? Double(args[1]) ?? 512 : 512
            print(BrandMark.svg(size: size))
        case "mark-plain":
            let size = args.count > 1 ? Double(args[1]) ?? 512 : 512
            print(BrandMark.svg(size: size, tile: false))
        default:
            FileHandle.standardError.write(
                Data("usage: tmu assets mark|mark-plain [size]\n".utf8))
            exit(2)
        }
    }
}
