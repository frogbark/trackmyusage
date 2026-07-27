import XCTest
@testable import ClaudrupleKit

/// The manifest is the artifact people commit and share, so parsing it is held to the
/// same standard as the security boundary: ambiguity gets rejected, not guessed at.
final class ManifestTests: XCTestCase {

    // MARK: - Basics

    func testParsesInstancesAndExtensions() throws {
        let m = try Manifest.parse("""
            version: 1
            instances:
              - name: Work
                extensions:
                  - ant.dir.gh.stripe.stripe
                  - ant.dir.ant.anthropic.filesystem
            """)

        XCTAssertEqual(m.instances.count, 1)
        XCTAssertEqual(m.instances[0].name, "Work")
        XCTAssertEqual(
            m.instances[0].extensions,
            ["ant.dir.ant.anthropic.filesystem", "ant.dir.gh.stripe.stripe"],
            "extensions are normalised to sorted order so plans are stable")
    }

    func testPolicyDefaultsToAdditive() throws {
        let m = try Manifest.parse("""
            version: 1
            instances:
              - name: Work
                extensions: [a]
            """)
        XCTAssertEqual(m.instances[0].policy, .additive)
    }

    func testPolicyCanBeDeclaredExplicitly() throws {
        let m = try Manifest.parse("""
            version: 1
            instances:
              - name: Work
                extensions: [a]
                policy: exact
            """)
        // Declaring exact only expresses intent; --prune still gates the removal.
        XCTAssertEqual(m.instances[0].policy, .exact)
    }

    func testKeepListIsParsed() throws {
        let m = try Manifest.parse("""
            version: 1
            instances:
              - name: Personal
                extensions: [a]
                keep: [ant.dir.gh.blender.blender-mcp]
            """)
        XCTAssertEqual(m.instances[0].keep, ["ant.dir.gh.blender.blender-mcp"])
    }

    func testMissingExtensionsKeyIsAnEmptyList() throws {
        let m = try Manifest.parse("""
            version: 1
            instances:
              - name: Bare
            """)
        XCTAssertEqual(m.instances[0].extensions, [])
        XCTAssertEqual(m.instances[0].keep, [])
    }

    // MARK: - Inheritance

    func testInheritsUnionsParentExtensions() throws {
        let m = try Manifest.parse("""
            version: 1
            instances:
              - name: Work
                extensions: [a, b]
              - name: Personal
                inherits: Work
                extensions: [c]
            """)

        let personal = try XCTUnwrap(m.instances.first { $0.name == "Personal" })
        XCTAssertEqual(personal.extensions, ["a", "b", "c"])
    }

    func testInheritsUnionsKeepLists() throws {
        let m = try Manifest.parse("""
            version: 1
            instances:
              - name: Work
                keep: [x]
              - name: Personal
                inherits: Work
                keep: [blender]
            """)
        let personal = try XCTUnwrap(m.instances.first { $0.name == "Personal" })
        XCTAssertEqual(personal.keep, ["blender", "x"])
    }

    func testInheritedDuplicatesAreCollapsed() throws {
        let m = try Manifest.parse("""
            version: 1
            instances:
              - name: Work
                extensions: [a, b]
              - name: Personal
                inherits: Work
                extensions: [b, c]
            """)
        let personal = try XCTUnwrap(m.instances.first { $0.name == "Personal" })
        XCTAssertEqual(personal.extensions, ["a", "b", "c"])
    }

    func testChildDoesNotInheritParentPolicy() throws {
        // Policy is a per-instance safety decision. Inheriting `exact` silently would let
        // a parent make a child destructive without the child's author noticing.
        let m = try Manifest.parse("""
            version: 1
            instances:
              - name: Work
                policy: exact
              - name: Personal
                inherits: Work
            """)
        let personal = try XCTUnwrap(m.instances.first { $0.name == "Personal" })
        XCTAssertEqual(personal.policy, .additive)
    }

    func testMultiLevelInheritanceResolves() throws {
        let m = try Manifest.parse("""
            version: 1
            instances:
              - name: Base
                extensions: [a]
              - name: Middle
                inherits: Base
                extensions: [b]
              - name: Leaf
                inherits: Middle
                extensions: [c]
            """)
        let leaf = try XCTUnwrap(m.instances.first { $0.name == "Leaf" })
        XCTAssertEqual(leaf.extensions, ["a", "b", "c"])
    }

    func testForwardReferenceInInheritsResolves() throws {
        // Declaration order should not matter; a manifest is a set, not a sequence.
        let m = try Manifest.parse("""
            version: 1
            instances:
              - name: Personal
                inherits: Work
                extensions: [c]
              - name: Work
                extensions: [a]
            """)
        let personal = try XCTUnwrap(m.instances.first { $0.name == "Personal" })
        XCTAssertEqual(personal.extensions, ["a", "c"])
    }

    // MARK: - Rejected input

    func testUnsupportedVersionIsRejected() {
        XCTAssertThrowsError(try Manifest.parse("version: 99\ninstances: []")) { error in
            XCTAssertEqual(error as? ManifestError, .unsupportedVersion(99))
        }
    }

    func testUnknownParentIsRejected() {
        let yaml = """
            version: 1
            instances:
              - name: Personal
                inherits: Nonexistent
            """
        XCTAssertThrowsError(try Manifest.parse(yaml)) { error in
            XCTAssertEqual(
                error as? ManifestError,
                .unknownParent(instance: "Personal", parent: "Nonexistent"))
        }
    }

    func testCircularInheritanceIsRejected() {
        // Left unchecked this is a hang, not a wrong answer — the worst failure mode.
        let yaml = """
            version: 1
            instances:
              - name: A
                inherits: B
              - name: B
                inherits: A
            """
        XCTAssertThrowsError(try Manifest.parse(yaml)) { error in
            guard case .circularInheritance = error as? ManifestError else {
                return XCTFail("expected circularInheritance, got \(error)")
            }
        }
    }

    func testDuplicateInstanceNamesAreRejected() {
        let yaml = """
            version: 1
            instances:
              - name: Work
                extensions: [a]
              - name: Work
                extensions: [b]
            """
        XCTAssertThrowsError(try Manifest.parse(yaml)) { error in
            XCTAssertEqual(error as? ManifestError, .duplicateInstance("Work"))
        }
    }

    func testUnknownPolicyValueIsRejected() {
        let yaml = """
            version: 1
            instances:
              - name: Work
                policy: destroy-everything
            """
        XCTAssertThrowsError(try Manifest.parse(yaml)) { error in
            XCTAssertEqual(
                error as? ManifestError,
                .invalidPolicy(instance: "Work", value: "destroy-everything"))
        }
    }
}
