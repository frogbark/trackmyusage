import XCTest

@testable import ClaudrupleKit

final class ManifestWriterTests: XCTestCase {

    func testRenderedManifestParsesBackToTheSameSpecs() throws {
        // Round-trip is the property that matters: `capture` writes a file that `plan`
        // must read identically. Asserting exact YAML text would just pin the formatting.
        let specs = [
            InstanceSpec(
                name: "Work",
                extensions: ["ant.dir.gh.stripe.stripe", "ant.dir.ant.anthropic.filesystem"],
                keep: ["ant.dir.gh.blender.blender-mcp"],
                policy: .exact),
            InstanceSpec(name: "Personal", extensions: ["a"], keep: [], policy: .additive),
        ]

        let reparsed = try Manifest.parse(Manifest.render(specs)).instances

        XCTAssertEqual(reparsed.count, 2)
        XCTAssertEqual(reparsed[0].name, "Work")
        XCTAssertEqual(
            reparsed[0].extensions,
            ["ant.dir.ant.anthropic.filesystem", "ant.dir.gh.stripe.stripe"])
        XCTAssertEqual(reparsed[0].keep, ["ant.dir.gh.blender.blender-mcp"])
        XCTAssertEqual(reparsed[0].policy, .exact)
        XCTAssertEqual(reparsed[1].name, "Personal")
        XCTAssertEqual(reparsed[1].policy, .additive)
    }

    func testEmptyInstanceRoundTrips() throws {
        let reparsed = try Manifest.parse(
            Manifest.render([InstanceSpec(name: "Bare", extensions: [])])
        ).instances

        XCTAssertEqual(reparsed[0].name, "Bare")
        XCTAssertEqual(reparsed[0].extensions, [])
    }

    func testRenderedManifestCarriesTheSchemaVersion() throws {
        let yaml = Manifest.render([InstanceSpec(name: "Work", extensions: [])])
        XCTAssertTrue(yaml.contains("version: \(Manifest.supportedVersion)"))
    }

    func testNamesNeedingQuotesRoundTrip() throws {
        // Display names are user-chosen and routinely contain spaces; a name like "Yes"
        // would otherwise be read back as a boolean.
        for name in ["Claude Two", "Yes", "No", "12345", "with: colon"] {
            let reparsed = try Manifest.parse(
                Manifest.render([InstanceSpec(name: name, extensions: [])])
            ).instances
            XCTAssertEqual(reparsed.first?.name, name, "round-trip failed for \(name)")
        }
    }
}
