import XCTest
@testable import FluxDownloadCore

final class DownloadStateMachineTests: XCTestCase {
    func testAllowedHappyPath() throws {
        var status = DownloadStatus.queued
        status = try DownloadStateMachine.transition(from: status, to: .preparing)
        status = try DownloadStateMachine.transition(from: status, to: .connecting)
        status = try DownloadStateMachine.transition(from: status, to: .downloading)
        status = try DownloadStateMachine.transition(from: status, to: .verifying)
        status = try DownloadStateMachine.transition(from: status, to: .completed)
        XCTAssertEqual(status, .completed)
    }

    func testPauseAndResume() throws {
        var status = DownloadStatus.downloading
        status = try DownloadStateMachine.transition(from: status, to: .paused)
        status = try DownloadStateMachine.transition(from: status, to: .connecting)
        XCTAssertEqual(status, .connecting)
    }

    func testIllegalTransitionThrows() {
        XCTAssertThrowsError(try DownloadStateMachine.transition(from: .completed, to: .downloading))
    }

    func testRetryableErrors() {
        XCTAssertTrue(FluxError.timeout.isRetryable)
        XCTAssertTrue(FluxError.serverFailure(status: 503).isRetryable)
        XCTAssertFalse(FluxError.notFound.isRetryable)
        XCTAssertFalse(FluxError.invalidURL("x").isRetryable)
    }
}

final class FilenameSanitizerTests: XCTestCase {
    func testArabicTurkishEmoji() throws {
        XCTAssertEqual(try FilenameSanitizer.sanitize("تقرير.pdf"), "تقرير.pdf")
        XCTAssertEqual(try FilenameSanitizer.sanitize("öğrenci ödevi.zip"), "öğrenci ödevi.zip")
        XCTAssertEqual(try FilenameSanitizer.sanitize("clip 🎬.mp4"), "clip 🎬.mp4")
    }

    func testRejectsTraversal() {
        XCTAssertThrowsError(try FilenameSanitizer.sanitize("../etc/passwd"))
    }

    func testStripsPathComponents() throws {
        XCTAssertEqual(try FilenameSanitizer.sanitize("/tmp/nested/file.txt"), "file.txt")
    }

    func testContentDisposition() throws {
        XCTAssertEqual(try FilenameSanitizer.fromContentDisposition(#"attachment; filename="report (1).pdf""#), "report (1).pdf")
    }
}

final class URLValidatorTests: XCTestCase {
    func testAcceptsHTTPS() throws {
        XCTAssertEqual(try URLValidator.parse("https://example.com/file.mp4").host, "example.com")
    }

    func testRejectsFileScheme() {
        XCTAssertThrowsError(try URLValidator.parse("file:///etc/passwd"))
    }

    func testExtractsMultipleURLs() {
        XCTAssertEqual(URLValidator.extractURLs(from: "see https://a.example/x.bin and https://b.example/y.zip").count, 2)
    }
}

final class CategoryAssignmentTests: XCTestCase {
    func testAssignsVideoByExtension() {
        let cats = BuiltInCategories.defaults(downloadRoot: URL(fileURLWithPath: "/tmp/dl"))
        XCTAssertEqual(BuiltInCategories.assign(filename: "movie.mkv", mimeType: nil, host: nil, categories: cats)?.name, "Video")
    }

    func testFallsBackToGeneral() {
        let cats = BuiltInCategories.defaults(downloadRoot: URL(fileURLWithPath: "/tmp/dl"))
        XCTAssertEqual(BuiltInCategories.assign(filename: "unknown", mimeType: "application/octet-stream", host: nil, categories: cats)?.name, "General")
    }
}

final class ScheduleWindowTests: XCTestCase {
    func testOvernightWindow() {
        let schedule = Schedule(name: "Night", startHour: 22, startMinute: 0, stopHour: 6, stopMinute: 0, days: Weekday.allCases)
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 15
        components.hour = 23
        components.minute = 0
        let calendar = Calendar(identifier: .gregorian)
        XCTAssertTrue(schedule.isActive(at: calendar.date(from: components)!))
        components.hour = 12
        XCTAssertFalse(schedule.isActive(at: calendar.date(from: components)!))
    }
}

final class RedactorTests: XCTestCase {
    func testRedactsAuthorizationHeader() {
        let redacted = Redactor.redactHeaders(["Authorization": "Bearer secret", "Accept": "video/mp4"])
        XCTAssertEqual(redacted["Authorization"], "<redacted>")
        XCTAssertEqual(redacted["Accept"], "video/mp4")
    }
}
