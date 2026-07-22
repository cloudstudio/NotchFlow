import Darwin
import Foundation
import NotchFlowCore
import os

public final class BridgeServer {
    private static let logger = Logger(subsystem: "app.notchflow", category: "bridge")
    private let queue = DispatchQueue(label: "app.notchflow.bridge", qos: .userInitiated)
    private let clientQueue = DispatchQueue(
        label: "app.notchflow.bridge.clients",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private var serverDescriptor: Int32 = -1
    private var socketPath = BridgeLocation.socketPath

    public init() {}

    deinit {
        stop()
    }

    public func start(
        onEnvelope: @escaping (BridgeEnvelope, @escaping (InteractionDecision) -> Void) -> Void
    ) {
        queue.async { [weak self] in
            self?.listen(onEnvelope: onEnvelope)
        }
    }

    public func stop() {
        if serverDescriptor >= 0 {
            Darwin.close(serverDescriptor)
            serverDescriptor = -1
        }
        unlink(socketPath)
    }

    private func listen(
        onEnvelope: @escaping (BridgeEnvelope, @escaping (InteractionDecision) -> Void) -> Void
    ) {
        signal(SIGPIPE, SIG_IGN)
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        unlink(socketPath)

        serverDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverDescriptor >= 0 else { return }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard copySocketPath(socketPath, into: &address) else { return }

        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + socketPath.utf8.count + 1)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(serverDescriptor, $0, addressLength)
            }
        }
        guard bindResult == 0 else {
            Self.logger.error("bind failed for \(self.socketPath, privacy: .public): errno \(errno)")
            return
        }
        chmod(socketPath, S_IRUSR | S_IWUSR)
        guard Darwin.listen(serverDescriptor, 16) == 0 else {
            Self.logger.error("listen failed: errno \(errno)")
            return
        }

        while serverDescriptor >= 0 {
            let client = Darwin.accept(serverDescriptor, nil, nil)
            guard client >= 0 else {
                if errno == EBADF || errno == EINVAL { break }
                Self.logger.info("accept failed: errno \(errno)")
                usleep(100_000)
                continue
            }
            clientQueue.async { [weak self] in
                self?.readClient(client, onEnvelope: onEnvelope)
            }
        }
    }

    private func readClient(
        _ descriptor: Int32,
        onEnvelope: @escaping (BridgeEnvelope, @escaping (InteractionDecision) -> Void) -> Void
    ) {
        let responder = SocketResponder(descriptor: descriptor)
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        while !collected.contains(0x0A) {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count > 0 else {
                responder.close()
                return
            }
            collected.append(buffer, count: count)
            if collected.count > 1_048_576 {
                responder.close()
                return
            }
        }

        guard let line = collected.split(separator: 0x0A).first,
              let envelope = try? JSONDecoder().decode(BridgeEnvelope.self, from: Data(line)) else {
            responder.close()
            return
        }

        if envelope.interaction == nil {
            responder.close()
        }
        onEnvelope(envelope) { decision in responder.send(decision) }
    }

    private func copySocketPath(_ path: String, into address: inout sockaddr_un) -> Bool {
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }

        withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
            tuplePointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { target in
                for (index, byte) in bytes.enumerated() {
                    target[index] = byte
                }
            }
        }
        return true
    }
}

private final class SocketResponder {
    private let lock = NSLock()
    private var descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func send(_ decision: InteractionDecision) {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0,
              let encoded = try? JSONEncoder().encode(decision) else { return }
        let data = encoded + Data([0x0A])
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                guard written > 0 else { break }
                offset += written
            }
        }
        Darwin.close(descriptor)
        descriptor = -1
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { close() }
}
