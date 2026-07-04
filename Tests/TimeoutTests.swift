import XCTest
@testable import Minutia

final class TimeoutTests: XCTestCase {
    func test_withTimeout_returnsValueWhenOperationBeatsDeadline() async throws {
        let value = try await withTimeout(seconds: 5) { 42 }
        XCTAssertEqual(value, 42)
    }

    func test_withTimeout_throwsTimeoutErrorWhenOperationExceedsDeadline() async {
        do {
            _ = try await withTimeout(seconds: 0.05) {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return 1
            }
            XCTFail("expected TimeoutError")
        } catch is TimeoutError {
            // expected
        } catch {
            XCTFail("expected TimeoutError, got \(error)")
        }
    }

    func test_withTimeout_propagatesOperationError() async {
        struct Boom: Error {}
        do {
            _ = try await withTimeout(seconds: 5) { throw Boom() }
            XCTFail("expected Boom")
        } catch is Boom {
            // expected: the operation's own error wins the race, not TimeoutError
        } catch {
            XCTFail("expected Boom, got \(error)")
        }
    }
}
