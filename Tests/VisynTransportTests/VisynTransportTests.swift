import XCTest
import MMWormhole
@testable import VisynTransport

private final class TemporaryFileTransport: MMWormholeFileTransiting {
    var testDirectory = ""
    override func messagePassingDirectoryPath() -> String? { testDirectory }
}

final class VisynTransportTests: XCTestCase {
    private var directory: URL!
    private let namespace = "test.\(UUID().uuidString)"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func channel() -> VisynWormholeChannel {
        let wormhole = MMWormhole(applicationGroupIdentifier: nil, optionalDirectory: nil)
        let messenger = TemporaryFileTransport(applicationGroupIdentifier: nil, optionalDirectory: nil)
        messenger.testDirectory = directory.path
        wormhole.wormholeMessenger = messenger
        return VisynWormholeChannel(wormhole: wormhole, namespace: namespace)
    }

    func testStatusAndBinaryFrameTransferAndCleanup() throws {
        let sender = channel(), receiver = channel()
        let status = VisynBroadcastStatus(sessionID: UUID(), state: .broadcasting)
        let frame = VisynCapturedFrame(sessionID: status.sessionID, width: 414, height: 896,
                                  jpegData: Data([0xff, 0xd8, 0x00, 0x80, 0xff, 0xd9]))
        try sender.send(status, to: .status)
        try sender.send(frame, to: .frame)
        XCTAssertEqual(try receiver.read(VisynBroadcastStatus.self, from: .status), status)
        let received = try XCTUnwrap(receiver.read(VisynCapturedFrame.self, from: .frame))
        XCTAssertEqual(received.jpegData, frame.jpegData)
        XCTAssertEqual(received.sessionID, status.sessionID)
        try received.validate()
        receiver.clear(.frame)
        XCTAssertNil(try sender.read(VisynCapturedFrame.self, from: .frame))
        XCTAssertNotNil(try sender.read(VisynBroadcastStatus.self, from: .status))
    }

    func testDarwinNotificationDeliversToOtherWormholeInstance() throws {
        let sender = channel(), receiver = channel()
        let notification = expectation(description: "Wormhole callback")
        receiver.listen(to: .status) { notification.fulfill() }
        try sender.send(VisynBroadcastStatus(sessionID: UUID(), state: .paused), to: .status)
        wait(for: [notification], timeout: 3)
        XCTAssertEqual(try receiver.read(VisynBroadcastStatus.self, from: .status)?.state, .paused)
        receiver.stopListening()
    }

    func testLatestStatusWinsAndInvalidPayloadIsRejected() throws {
        let sender = channel(), receiver = channel()
        let session = UUID()
        try sender.send(VisynBroadcastStatus(sessionID: session, state: .broadcasting), to: .status)
        try sender.send(VisynBroadcastStatus(sessionID: session, state: .stopped), to: .status)
        XCTAssertEqual(try receiver.read(VisynBroadcastStatus.self, from: .status)?.state, .stopped)
        try sender.send(["unexpected": "payload"], to: .frame)
        XCTAssertThrowsError(try receiver.read(VisynCapturedFrame.self, from: .frame))
    }

    func testStaleStatusAndFramesCannotBecomeCurrent() throws {
        let now = Date()
        XCTAssertFalse(VisynBroadcastStatus(sessionID: UUID(), state: .broadcasting,
                                       updatedAt: now.addingTimeInterval(-7)).isCurrent(at: now))
        let old = VisynCapturedFrame(sessionID: UUID(), capturedAt: now.addingTimeInterval(-4),
                                width: 100, height: 100, jpegData: Data([1]))
        XCTAssertThrowsError(try old.validate(at: now))
        let future = VisynCapturedFrame(sessionID: UUID(), capturedAt: now.addingTimeInterval(10),
                                   width: 100, height: 100, jpegData: Data([1]))
        XCTAssertThrowsError(try future.validate(at: now))
        let oversized = VisynCapturedFrame(sessionID: UUID(), width: 100, height: 100,
                                      jpegData: Data(repeating: 0, count: 2_000_001))
        XCTAssertThrowsError(try oversized.validate(at: now))
    }
}
