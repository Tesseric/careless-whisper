import XCTest
@testable import CarelessWhisper

final class AudioBufferTests: XCTestCase {
    func testAppendAndFlush() {
        let buffer = AudioBuffer()
        buffer.append([1.0, 2.0, 3.0])
        buffer.append([4.0, 5.0])

        let result = buffer.flush()
        XCTAssertEqual(result, [1.0, 2.0, 3.0, 4.0, 5.0])
    }

    func testFlushClearsBuffer() {
        let buffer = AudioBuffer()
        buffer.append([1.0, 2.0])
        _ = buffer.flush()
        let result = buffer.flush()
        XCTAssertTrue(result.isEmpty)
    }

    func testCount() {
        let buffer = AudioBuffer()
        XCTAssertEqual(buffer.count, 0)
        buffer.append([1.0, 2.0, 3.0])
        XCTAssertEqual(buffer.count, 3)
    }

    func testConcurrentAccess() async {
        let buffer = AudioBuffer()
        let iterations = 1000

        await withTaskGroup(of: Void.self) { group in
            // Writer tasks
            for i in 0..<10 {
                group.addTask {
                    for j in 0..<iterations {
                        buffer.append([Float(i * iterations + j)])
                    }
                }
            }
        }

        let result = buffer.flush()
        XCTAssertEqual(result.count, 10 * iterations)
    }
}
