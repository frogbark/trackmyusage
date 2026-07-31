import Foundation
import TMUDesign
import TMUKit
import TMUWidgets

/// Brand assets, emitted from `BrandMark`'s geometry.
///
/// Nothing here is committed as a binary. One definition serves the app icon, the website
/// mark, the favicon and the social preview — which is the only way five renderings of a
/// logo stay identical over time.
///
/// The widget demos are here for the same reason one step further out: the images on the
/// website come out of the code that draws the real widget, so the site cannot show a layout
/// the binary does not produce.
enum AssetCommands {

    static func run(_ args: [String]) {
        switch args.first {
        case "mark":
            let size = args.count > 1 ? Double(args[1]) ?? 512 : 512
            print(BrandMark.svg(size: size))
        case "mark-plain":
            let size = args.count > 1 ? Double(args[1]) ?? 512 : 512
            print(BrandMark.svg(size: size, tile: false))
        case "widget":
            widget(Array(args.dropFirst()))
        case "widget-models":
            widgetModels()
        case "social":
            social(Array(args.dropFirst()))
        case "instance-icon":
            instanceIcon(Array(args.dropFirst()))
        default:
            usage(exitCode: 2)
        }
    }

    /// `tmu assets widget <family> <case>` — PNG on stdout.
    ///
    /// Dated to `DemoSnapshots.generatedAt` rather than now, so running this twice produces
    /// the same picture of the same moment.
    private static func widget(_ args: [String]) {
        guard args.count >= 2,
            let family = WidgetFamilyID(rawValue: args[0]),
            let demo = DemoWidget(rawValue: args[1])
        else {
            let families = WidgetFamilyID.allCases.map(\.rawValue).joined(separator: "|")
            let cases = DemoWidget.allCases.map(\.rawValue).joined(separator: "|")
            FileHandle.standardError.write(
                Data("usage: tmu assets widget \(families) \(cases)\n".utf8))
            exit(2)
        }
        guard
            let png = MainActor.assumeIsolated({
                WidgetRenderer.png(demo.viewModel(family: family))
            })
        else {
            FileHandle.standardError.write(Data("assets widget: could not render\n".utf8))
            exit(1)
        }
        FileHandle.standardOutput.write(png)
    }

    /// `tmu assets widget-models` — every family of every case, as JSON.
    ///
    /// This is the file that replaced the wallpaper SVGs as the thing `check-generated.sh`
    /// byte-compares, and it is why that check still detects a layout regression. The PNGs
    /// beside it cannot be compared — CoreGraphics and the installed fonts decide their
    /// encoding, and neither is in this repository — so the guarantee lives here, in text,
    /// generated from the same models those images draw.
    ///
    /// Through CanonicalJSON, whose sorted keys are the only reason two runs agree.
    private static func widgetModels() {
        do {
            let data = try CanonicalJSON.encode(DemoWidget.allViewModels(), pretty: true)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("assets widget-models: \(error)\n".utf8))
            exit(1)
        }
    }

    /// `tmu assets social [case] [width] [height]` — PNG on stdout.
    ///
    /// The same widget the app draws, rasterised. Link unfurls are where most people see this
    /// project first, and a hand-made card would be the one picture of the product that the
    /// product did not draw.
    ///
    /// 1200×630 because that is what the unfurlers crop to. The widget is placed on that
    /// canvas rather than stretched to it: a widget has its own aspect ratio and distorting it
    /// would misrepresent the thing being advertised.
    ///
    /// The large family, because it is the one that fills its own frame. The medium drawn from
    /// the demo data has two accounts in a three-row budget, and scaled up for an unfurl that
    /// trailing gap reads as an unfinished layout rather than as a widget with room to spare.
    private static func social(_ args: [String]) {
        let name = args.first ?? DemoWidget.busy.rawValue
        guard let demo = DemoWidget(rawValue: name) else {
            let names = DemoWidget.allCases.map(\.rawValue).joined(separator: "|")
            FileHandle.standardError.write(
                Data("usage: tmu assets social [\(names)] [width] [height]\n".utf8))
            exit(2)
        }
        let width = args.count > 1 ? Double(args[1]) ?? 1200 : 1200
        let height = args.count > 2 ? Double(args[2]) ?? 630 : 630

        guard
            let png = MainActor.assumeIsolated({
                WidgetRenderer.png(
                    demo.viewModel(family: .large),
                    asCard: CGSize(width: width, height: height))
            })
        else {
            FileHandle.standardError.write(Data("assets social: could not render\n".utf8))
            exit(1)
        }
        FileHandle.standardOutput.write(png)
    }

    /// `tmu assets instance-icon <name> <source.icns> <out.iconset>`
    ///
    /// Writes the PNGs; the caller runs `iconutil` over the directory. Splitting it there
    /// keeps this from shelling out to a tool it would then have to check for.
    private static func instanceIcon(_ args: [String]) {
        guard args.count >= 3 else {
            FileHandle.standardError.write(
                Data("usage: tmu assets instance-icon <name> <source.icns> <out.iconset>\n".utf8))
            exit(2)
        }
        do {
            try InstanceIcon.writeIconset(
                name: args[0],
                source: URL(fileURLWithPath: args[1]),
                into: URL(fileURLWithPath: args[2]))
        } catch {
            FileHandle.standardError.write(Data("assets instance-icon: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func usage(exitCode: Int32) -> Never {
        let families = WidgetFamilyID.allCases.map(\.rawValue).joined(separator: "|")
        let names = DemoWidget.allCases.map(\.rawValue).joined(separator: "|")
        FileHandle.standardError.write(
            Data(
                """
                usage: tmu assets mark|mark-plain [size]
                       tmu assets widget \(families) \(names)
                       tmu assets widget-models
                       tmu assets social [\(names)] [width] [height]
                       tmu assets instance-icon <name> <source.icns> <out.iconset>

                """.utf8))
        exit(exitCode)
    }
}
