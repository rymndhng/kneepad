import Foundation

// A dependency-free test harness.
//
// This Command Line Tools install ships neither a usable XCTest nor a working
// Testing.framework (the latter links lib_TestingInterop.dylib, which is not
// present on the system). Rather than require a full Xcode install, tests run
// as an ordinary executable: `swift run hidcore-tests`.

enum TestRunner {
    static var passed = 0
    static var failed = 0
    static var currentSuite = ""

    static func suite(_ name: String, _ body: () throws -> Void) {
        currentSuite = name
        print("\n\(name)")
        print(String(repeating: "─", count: max(name.count, 40)))
        do {
            try body()
        } catch {
            failed += 1
            print("  ✗ suite threw: \(error)")
        }
    }

    static func test(_ name: String, _ body: () throws -> Void) {
        let before = failed
        do {
            try body()
        } catch {
            failed += 1
            print("  ✗ \(name)\n      threw: \(error)")
            return
        }
        if failed == before {
            passed += 1
            print("  ✓ \(name)")
        } else {
            print("    ↑ in: \(name)")
        }
    }

    static func fail(_ message: String, _ line: UInt) {
        failed += 1
        print("  ✗ \(message)  (line \(line))")
    }

    static func summarize() -> Int32 {
        print("\n" + String(repeating: "═", count: 40))
        print("\(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func check(_ condition: Bool, _ message: String, line: UInt = #line) {
    if !condition { TestRunner.fail(message, line) }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "",
                               line: UInt = #line) {
    if actual != expected {
        TestRunner.fail("\(message.isEmpty ? "" : message + ": ")"
            + "expected \(expected), got \(actual)", line)
    }
}

func expectClose(_ actual: Double, _ expected: Double, _ tolerance: Double = 0.001,
                 _ message: String = "", line: UInt = #line) {
    if abs(actual - expected) > tolerance {
        TestRunner.fail("\(message.isEmpty ? "" : message + ": ")"
            + "expected \(expected) ± \(tolerance), got \(actual)", line)
    }
}

func expectNil<T>(_ value: T?, _ message: String = "", line: UInt = #line) {
    if value != nil {
        TestRunner.fail("\(message.isEmpty ? "" : message + ": ")expected nil", line)
    }
}

/// Unwrap or throw, so a missing value aborts the test rather than crashing.
func require<T>(_ value: T?, _ message: String = "unexpected nil") throws -> T {
    guard let value else { throw TestFailure(description: message) }
    return value
}

func expectThrows(_ message: String = "expected an error",
                  line: UInt = #line, _ body: () throws -> Void) {
    do {
        try body()
        TestRunner.fail(message, line)
    } catch {
        // expected
    }
}
