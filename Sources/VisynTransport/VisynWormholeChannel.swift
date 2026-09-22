import Foundation
import MMWormhole

/// Latest-value mailboxes, not a lossless video stream. Each endpoint owns its own instance.
public final class VisynWormholeChannel {
    public enum Mailbox: String {
        case status = "broadcastStatus"
        case frame = "screenCapture"
    }

    private let wormhole: MMWormhole
    private let namespace: String

    public init(configuration: VisynConfiguration) throws {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: configuration.appGroupIdentifier
        ) else { throw VisynError.missingAppGroup(configuration.appGroupIdentifier) }
        var directory = root.appendingPathComponent("Visyn", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        wormhole = MMWormhole(applicationGroupIdentifier: configuration.appGroupIdentifier,
                              optionalDirectory: "Visyn")
        namespace = configuration.appGroupIdentifier
    }

    // Allows transport tests to use an isolated temporary mailbox, without provisioning an App Group.
    init(wormhole: MMWormhole, namespace: String) {
        self.wormhole = wormhole
        self.namespace = namespace
    }

    private func identifier(_ mailbox: Mailbox) -> String { "\(namespace).\(mailbox.rawValue)" }

    public func send<T: Encodable>(_ value: T, to mailbox: Mailbox) throws {
        let data = try JSONEncoder().encode(value)
        let key = identifier(mailbox)
        // MMWormhole's void API hides write errors; use its messenger result before notifying.
        guard wormhole.wormholeMessenger.writeMessageObject(data as NSData, forIdentifier: key) else {
            throw VisynError.writeFailed
        }
        wormhole.passMessageObject(nil, identifier: key)
    }

    public func read<T: Decodable>(_ type: T.Type, from mailbox: Mailbox) throws -> T? {
        guard let object = wormhole.message(withIdentifier: identifier(mailbox)) else { return nil }
        guard let data = object as? Data, data.count <= 3_000_000 else { throw VisynError.invalidMessage }
        return try JSONDecoder().decode(type, from: data)
    }

    public func listen(to mailbox: Mailbox, onChange: @escaping () -> Void) {
        // Reread on consumption: queued Darwin callbacks may refer to overwritten values.
        wormhole.listenForMessage(withIdentifier: identifier(mailbox)) { _ in onChange() }
    }

    public func clear(_ mailbox: Mailbox) {
        wormhole.clearMessageContents(forIdentifier: identifier(mailbox))
    }

    public func stopListening() {
        wormhole.stopListeningForMessage(withIdentifier: identifier(.status))
        wormhole.stopListeningForMessage(withIdentifier: identifier(.frame))
    }
}
