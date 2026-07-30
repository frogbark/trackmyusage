import Foundation
import XCTest

@testable import TMUKit

/// Reading the profile path back out of a launcher binary.
///
/// This is the only record of where an instance keeps its data — compiled in at creation and
/// unchangeable afterwards — so reading it wrongly is worse than not reading it. A confident
/// wrong answer here would have `tmu doctor` report a mismatch that does not exist, or miss
/// one that does.
final class ShimProfileTests: XCTestCase {

    /// Prevents: taking the bare flag and reporting an empty path.
    ///
    /// launcher.c holds the flag twice — once concatenated with the path, once alone for the
    /// `strncmp` against incoming arguments — and the linker is under no obligation to order
    /// them. Taking the first match yields the empty one about half the time, which is the
    /// bug the shell version of this documents having hit.
    func testTheBareFlagIsNotMistakenForThePath() throws {
        // Bare flag first, deliberately: the order that breaks a first-match implementation.
        let binary = blob([
            "--user-data-dir=",
            "some other string",
            "--user-data-dir=/Users/x/Library/Application Support/Claudruple/Work",
        ])
        XCTAssertEqual(
            ShimProfile.path(inBinary: binary),
            "/Users/x/Library/Application Support/Claudruple/Work")
    }

    /// Prevents: the same failure with the order reversed, which a naive fix would pass.
    func testItFindsThePathWhicheverOrderTheLiteralsLandIn() throws {
        let binary = blob([
            "--user-data-dir=/Users/x/Library/Application Support/Claudruple/Work",
            "--user-data-dir=",
        ])
        XCTAssertEqual(
            ShimProfile.path(inBinary: binary),
            "/Users/x/Library/Application Support/Claudruple/Work")
    }

    /// Prevents: reading past the end of the C string into whatever follows it.
    func testThePathStopsAtTheStringTerminator() throws {
        let binary = blob(["--user-data-dir=/Users/x/Work", "trailing junk", "more junk"])
        XCTAssertEqual(ShimProfile.path(inBinary: binary), "/Users/x/Work")
    }

    /// Prevents: a binary with no flag at all returning something.
    ///
    /// The primary has no shim, and a clone whose launcher cannot be read has to report
    /// unknown rather than a guess — `Diagnostics` grades those differently.
    func testABinaryWithoutTheFlagYieldsNothing() {
        XCTAssertNil(ShimProfile.path(inBinary: blob(["nothing", "of", "interest"])))
        XCTAssertNil(ShimProfile.path(inBinary: Data()))
    }

    /// Prevents: a name with a space, which is the common case, being truncated.
    func testAPathContainingSpacesSurvivesIntact() throws {
        let expected = "/Users/x/Library/Application Support/Claudruple/Claude Two"
        XCTAssertEqual(
            ShimProfile.path(inBinary: blob(["--user-data-dir=" + expected])), expected)
    }

    /// Prevents: the scanner walking off the end when the flag is the last thing in the file.
    func testAFlagAtTheVeryEndDoesNotOverrun() {
        var data = Data("padding".utf8)
        data.append(0)
        data.append(Data("--user-data-dir=".utf8))
        XCTAssertNil(ShimProfile.path(inBinary: data), "an unterminated bare flag is not a path")
    }

    /// A stand-in for a Mach-O: NUL-separated C strings, which is all this reads.
    private func blob(_ strings: [String]) -> Data {
        var data = Data()
        for string in strings {
            data.append(Data(string.utf8))
            data.append(0)
        }
        return data
    }
}
