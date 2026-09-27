import Darwin
import Foundation
import XCTest
@testable import UnquarantineCore

final class DownloadTests: XCTestCase {
    private var folder: URL!
    private var inspector: DownloadInspector { DownloadInspector(folder: folder) }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnquarantineTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    private func file(_ path: String, contents: String = "download") throws -> URL {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func quarantine(_ url: URL) throws {
        try attribute("com.apple.quarantine", value: "0081;00000000;UnquarantineTests;", on: url)
    }

    private func attribute(_ name: String, value: String, on url: URL) throws {
        let data = Data(value.utf8)
        let result = data.withUnsafeBytes { buffer in
            setxattr(url.path, name, buffer.baseAddress, buffer.count, 0, XATTR_NOFOLLOW)
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
    }

    private func target(_ url: URL) throws -> DownloadTarget? {
        guard let candidate = inspector.candidate(forEventAt: url) else { return nil }
        return try inspector.inspect(candidate)
    }

    private func monitor(onClear: @escaping (String) -> Void) -> DownloadMonitor {
        let started = expectation(description: "FSEvents started")
        let monitor = DownloadMonitor(folder: folder) { state in
            switch state {
            case .watching: started.fulfill()
            case .cleared(let name): onClear(name)
            case .problem(let message): XCTFail(message)
            }
        }
        monitor.start()
        wait(for: [started], timeout: 5)
        return monitor
    }

    private func waitForEvents(_ seconds: TimeInterval = 0.75) {
        let elapsed = expectation(description: "Allow event delivery and busy-file checks")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { elapsed.fulfill() }
        wait(for: [elapsed], timeout: seconds + 2)
    }

    func testEventPathsResolveSubfoldersAndOutermostAppWithoutScanning() throws {
        let zip = try file("subfolder/archive.ZIP")
        XCTAssertEqual(inspector.candidate(forEventAt: zip)?.standardizedFileURL.path, zip.standardizedFileURL.path)
        let child = try file("Example.app/Contents/Helpers/Nested.app/Contents/file.zip")
        XCTAssertEqual(inspector.candidate(forEventAt: child)?.lastPathComponent, "Example.app")
        XCTAssertNil(inspector.candidate(forEventAt: folder))
        XCTAssertNil(inspector.candidate(forEventAt: folder.appendingPathComponent("ordinary folder")))
        XCTAssertNil(inspector.candidate(forEventAt: folder.appendingPathComponent(".hidden/archive.zip")))
        XCTAssertNil(inspector.candidate(forEventAt: URL(fileURLWithPath: folder.path + "-other/archive.zip")))
    }

    func testPartialPathsAreIgnoredExceptForCompletionEvents() throws {
        let partial = folder.appendingPathComponent("archive.zip.crdownload")
        XCTAssertNil(inspector.candidate(forEventAt: partial))
        XCTAssertEqual(inspector.candidate(forEventAt: partial, partialRemoved: true)?.lastPathComponent, "archive.zip")
        XCTAssertNil(inspector.candidate(forEventAt: folder.appendingPathComponent("unfinished.download/inside.dmg")))
        let child = folder.appendingPathComponent("Example.app/Contents/resource.part")
        XCTAssertEqual(inspector.candidate(forEventAt: child)?.lastPathComponent, "Example.app")
    }

    func testOnlyQuarantinedEligibleTargetsAreInspected() throws {
        let zip = try file("archive.zip")
        XCTAssertNil(try target(zip))
        try quarantine(zip)
        XCTAssertNotNil(try target(zip))
        let empty = try file("empty.dmg", contents: "")
        try quarantine(empty)
        XCTAssertNil(try target(empty))
        let unsupported = try file("installer.pkg")
        try quarantine(unsupported)
        XCTAssertNil(try target(unsupported))
        let fakeApp = try file("text.app")
        try quarantine(fakeApp)
        XCTAssertNil(try target(fakeApp))
        try FileManager.default.removeItem(at: zip)
        XCTAssertNil(try target(zip))
    }

    func testPartialSiblingBlocksAClosedArchive() throws {
        let zip = try file("archive.zip")
        try quarantine(zip)
        let part = try file("archive.zip.part")
        XCTAssertNil(try target(zip))
        try FileManager.default.removeItem(at: part)
        XCTAssertNotNil(try target(zip))
        let resumed = try XCTUnwrap(inspector.candidate(forEventAt: part, partialRemoved: true))
        XCTAssertNotNil(try inspector.inspect(resumed))
    }

    func testSymlinksAndSymlinkAncestorsAreRejected() throws {
        let real = try file("real/archive.zip")
        try quarantine(real)
        let link = folder.appendingPathComponent("link.zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertNil(try target(link))
        let directoryLink = folder.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: real.deletingLastPathComponent())
        XCTAssertNil(try target(directoryLink.appendingPathComponent("archive.zip")))
        XCTAssertTrue(try hasQuarantine(real))
    }

    func testBatchedOpenHandleCheckMatchesMultipleFilesAndHardLinks() throws {
        let first = try file("first.zip")
        let second = try file("second.dmg")
        let closed = try file("closed.zip")
        for url in [first, second, closed] { try quarantine(url) }
        let alias = folder.appendingPathComponent("hard-link.zip")
        try FileManager.default.linkItem(at: first, to: alias)
        let firstHandle = try FileHandle(forWritingTo: first)
        let secondHandle = try FileHandle(forReadingFrom: second)
        defer { try? firstHandle.close(); try? secondHandle.close() }
        let targets = try [alias, second, closed].map { try XCTUnwrap(target($0)) }
        let busy = try QuarantineRemover.openFiles(targets)
        XCTAssertTrue(busy.contains(targets[0].identity))
        XCTAssertTrue(busy.contains(targets[1].identity))
        XCTAssertFalse(busy.contains(targets[2].identity))
        try firstHandle.close()
        try secondHandle.close()
        XCTAssertTrue(try QuarantineRemover.openFiles(targets).isEmpty)
    }

    func testRemovalPreservesContentsOtherAttributesAndLiteralFilenames() throws {
        let url = try file("quoted ' \" $(touch SHOULD_NOT_EXIST) ; name.zip")
        try quarantine(url)
        try attribute("me.tonsky.test", value: "keep me", on: url)
        let before = try Data(contentsOf: url)
        try QuarantineRemover.remove(from: url)
        XCTAssertFalse(try hasQuarantine(url))
        XCTAssertEqual(getxattr(url.path, "me.tonsky.test", nil, 0, 0, XATTR_NOFOLLOW), 7)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("SHOULD_NOT_EXIST").path))
    }

    func testAppRemovalTouchesOnlyBundleDirectory() throws {
        let child = try file("Example.app/Contents/MacOS/Example")
        let app = folder.appendingPathComponent("Example.app")
        let outside = try file("outside.zip")
        for url in [app, child, outside] { try quarantine(url) }
        let link = app.appendingPathComponent("Contents/external")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try quarantine(link)
        try QuarantineRemover.remove(from: app)
        XCTAssertFalse(try hasQuarantine(app))
        XCTAssertTrue(try hasQuarantine(child))
        XCTAssertTrue(try hasQuarantine(link))
        XCTAssertTrue(try hasQuarantine(outside))
        // Quarantined children alone must not keep the app pending.
        XCTAssertNil(try target(app))
    }

    func testCommandExitAndTimeoutDoNotNeedPolling() throws {
        let result = try runCommand("/usr/bin/printf", ["hello"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "hello")
        let start = Date()
        XCTAssertThrowsError(try runCommand("/bin/sleep", ["10"], timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testMonitorQuicklyClearsNewNestedDownloadAndLeavesExistingFiles() throws {
        let existing = try file("existing.zip")
        try quarantine(existing)
        let cleared = expectation(description: "New download cleared without settling delay")
        let monitor = monitor { name in
            XCTAssertEqual(name, "new download.dmg")
            cleared.fulfill()
        }
        defer { monitor.stop() }
        let download = try file("nested/new download.dmg")
        try quarantine(download)
        wait(for: [cleared], timeout: 4)
        XCTAssertFalse(try hasQuarantine(download))
        XCTAssertTrue(try hasQuarantine(existing))
    }

    func testMonitorRetriesBusyArchiveAfterCloseWithoutAnotherWrite() throws {
        let download = try file("busy.zip")
        let handle = try FileHandle(forWritingTo: download)
        defer { try? handle.close() }
        let cleared = expectation(description: "Closed download cleared by pending-only retry")
        let monitor = monitor { name in
            XCTAssertEqual(name, "busy.zip")
            cleared.fulfill()
        }
        defer { monitor.stop() }
        try quarantine(download)
        waitForEvents()
        XCTAssertTrue(try hasQuarantine(download))
        try handle.close()
        wait(for: [cleared], timeout: 3)
        XCTAssertFalse(try hasQuarantine(download))
    }

    func testMonitorProcessesPartialRenameAndPartialSiblingRemoval() throws {
        let download = try file("firefox.zip")
        let sibling = try file("firefox.zip.part")
        let cleared = expectation(description: "Both browser completion patterns handled")
        cleared.expectedFulfillmentCount = 2
        let monitor = monitor { name in
            XCTAssertTrue(["firefox.zip", "chrome.dmg"].contains(name))
            cleared.fulfill()
        }
        defer { monitor.stop() }
        try quarantine(download)
        waitForEvents()
        XCTAssertTrue(try hasQuarantine(download))
        try FileManager.default.removeItem(at: sibling)
        let partial = try file("chrome.dmg.crdownload")
        try quarantine(partial)
        let final = folder.appendingPathComponent("chrome.dmg")
        try FileManager.default.moveItem(at: partial, to: final)
        wait(for: [cleared], timeout: 4)
        XCTAssertFalse(try hasQuarantine(download))
        XCTAssertFalse(try hasQuarantine(final))
    }

    func testMonitorClearsAppWhileChildIsOpenAndHandlesReappliedQuarantine() throws {
        let child = try file("Example.app/Contents/MacOS/Example")
        let app = folder.appendingPathComponent("Example.app")
        try quarantine(child)
        let handle = try FileHandle(forWritingTo: child)
        defer { try? handle.close() }
        let first = expectation(description: "App cleared without waiting for its child")
        let second = expectation(description: "Reapplied app quarantine cleared")
        var count = 0
        let monitor = monitor { name in
            XCTAssertEqual(name, "Example.app")
            count += 1
            if count == 1 { first.fulfill() }
            else if count == 2 { second.fulfill() }
            else { XCTFail("Unexpected repeated clearing") }
        }
        defer { monitor.stop() }
        try quarantine(app)
        wait(for: [first], timeout: 3)
        XCTAssertTrue(try hasQuarantine(child))
        try quarantine(app)
        wait(for: [second], timeout: 3)
        XCTAssertFalse(try hasQuarantine(app))
        XCTAssertTrue(try hasQuarantine(child))
    }
}
