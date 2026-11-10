import XCTest
@testable import SH2Protocol

/// The generated device password is what the firmware stores (32 bytes) and what the official app
/// produced (letters and digits), drawn uniformly.
final class RecoveryPasswordTests: XCTestCase {

    private let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    func testPasswordIs32SymbolsOfTheAlphabet() {
        for _ in 0..<50 {
            let p = Recovery.generateDevicePassword()
            XCTAssertEqual(p.count, 32)
            XCTAssertEqual(p.utf8.count, 32, "ASCII only: the firmware takes exactly 32 bytes")
            XCTAssertTrue(p.allSatisfy { alphabet.contains($0) }, p)
        }
    }

    func testTwoPasswordsDiffer() {
        XCTAssertNotEqual(Recovery.generateDevicePassword(), Recovery.generateDevicePassword())
    }

    /// With `byte % 62` the first eight symbols ("A"…"H") came out 5/4 times as often as the rest.
    /// Over 2 000 passwords (64 000 symbols) each symbol is expected ≈ 1 032 times; "A"…"H" together
    /// ≈ 8 258 unbiased against ≈ 10 000 biased. Six sigma apart: no flakiness in practice.
    func testTheFirstSymbolsAreNotFavoured() {
        var firstEight = 0
        var total = 0
        for _ in 0..<2000 {
            for c in Recovery.generateDevicePassword() {
                total += 1
                if "ABCDEFGH".contains(c) { firstEight += 1 }
            }
        }
        let expected = Double(total) * 8 / 62
        XCTAssertLessThan(Double(firstEight), expected * 1.08, "biased towards A…H: \(firstEight) of \(total)")
        XCTAssertGreaterThan(Double(firstEight), expected * 0.92)
    }
}
