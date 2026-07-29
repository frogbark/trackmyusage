import Foundation
import TMUDesign
import TMURender

/// Brand assets, emitted from `BrandMark`'s geometry.
///
/// Nothing here is committed as a binary. One definition serves the app icon, the website
/// mark, the favicon and the social preview — which is the only way five renderings of a
/// logo stay identical over time.
///
/// The wallpaper demos are here for the same reason one step further out: the images on the
/// website come out of the renderer that draws the real wallpaper, so the site cannot show a
/// layout the code does not produce.
enum AssetCommands {

    static func run(_ args: [String]) {
        switch args.first {
        case "mark":
            let size = args.count > 1 ? Double(args[1]) ?? 512 : 512
            print(BrandMark.svg(size: size))
        case "mark-plain":
            let size = args.count > 1 ? Double(args[1]) ?? 512 : 512
            print(BrandMark.svg(size: size, tile: false))
        case "wallpaper":
            wallpaper(Array(args.dropFirst()))
        case "social":
            social(Array(args.dropFirst()))
        default:
            usage(exitCode: 2)
        }
    }

    /// `tmu assets wallpaper <case> [width] [height]`
    ///
    /// Dated to `DemoSnapshots.generatedAt` rather than now, so running this twice produces
    /// the same bytes. `check-generated.sh` diffs the committed copies, and a timestamp that
    /// moved every render would make that check fail for no reason anyone could act on.
    private static func wallpaper(_ args: [String]) {
        let names = DemoWallpaper.allCases.map(\.rawValue)
        guard let name = args.first, let demo = DemoWallpaper(rawValue: name) else {
            FileHandle.standardError.write(
                Data("usage: tmu assets wallpaper \(names.joined(separator: "|"))\n".utf8))
            exit(2)
        }
        let width = args.count > 1 ? Double(args[1]) ?? 2560 : 2560
        let height = args.count > 2 ? Double(args[2]) ?? 1440 : 1440
        print(demo.svg(canvas: WallpaperCanvas(width: width, height: height)))
    }

    /// `tmu assets social [case] [width] [height]` — PNG on stdout.
    ///
    /// The social preview is the same render as the wallpaper, rasterised. Link unfurls are
    /// where most people see this project first, and a hand-made card would be the one
    /// picture of the product that the product did not draw.
    ///
    /// 1200×630 because that is what the unfurlers crop to; the layout scales to it, and
    /// `resolve` turns the board into the rail below the board's minimum width rather than
    /// squeezing it.
    private static func social(_ args: [String]) {
        let name = args.first ?? DemoWallpaper.ledger.rawValue
        guard let demo = DemoWallpaper(rawValue: name) else {
            let names = DemoWallpaper.allCases.map(\.rawValue).joined(separator: "|")
            FileHandle.standardError.write(
                Data("usage: tmu assets social [\(names)] [width] [height]\n".utf8))
            exit(2)
        }
        let width = args.count > 1 ? Double(args[1]) ?? 1200 : 1200
        let height = args.count > 2 ? Double(args[2]) ?? 630 : 630
        let canvas = WallpaperCanvas(width: width, height: height)

        do {
            // A nil background means the rasteriser supplies its own rather than leaving
            // transparency — which is what this needs, since an unfurl has nothing to
            // composite over.
            let png = try AppKitRasterizer().compose(
                svg: demo.svg(canvas: canvas), over: nil, canvas: canvas)
            FileHandle.standardOutput.write(png)
        } catch {
            FileHandle.standardError.write(Data("assets social: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func usage(exitCode: Int32) -> Never {
        let names = DemoWallpaper.allCases.map(\.rawValue).joined(separator: "|")
        FileHandle.standardError.write(
            Data(
                """
                usage: tmu assets mark|mark-plain [size]
                       tmu assets wallpaper \(names) [width] [height]
                       tmu assets social [\(names)] [width] [height]

                """.utf8))
        exit(exitCode)
    }
}
