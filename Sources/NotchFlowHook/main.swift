import AppKit
import Darwin
import Foundation
import NotchFlowCore

private let maximumPayloadSize = 1_048_576

enum InterceptPolicy: String {
    case always
    case background
    case never
}

struct HookOptions {
    var agent: AgentKind?
    var socketPath = BridgeLocation.socketPath
    var strict = false
    var payloadArgument: Data?
    var responseTimeout: Int = 300
    var intercept: InterceptPolicy = .background
}

let options = parseOptions(Array(CommandLine.arguments.dropFirst()))
let input = options.payloadArgument
    ?? (try? FileHandle.standardInput.read(upToCount: maximumPayloadSize + 1))
    ?? Data()

let ancestry = agentAncestry(agent: options.agent)
let context = HookContext(
    forcedAgent: options.agent,
    environment: ProcessInfo.processInfo.environment,
    tty: ancestry.tty,
    agentPid: ancestry.agentPid
)

guard !input.isEmpty, input.count <= maximumPayloadSize,
      var hook = HookNormalizer.normalize(input: input, context: context) else {
    if options.strict { exit(2) }
    exit(0)
}

if hook.envelope.interaction != nil,
   shouldSuppressInteraction(options: options, ownTTY: ancestry.tty) {
    hook = NormalizedHook(
        envelope: BridgeEnvelope(event: hook.envelope.event, interaction: nil),
        toolInput: hook.toolInput
    )
}

guard let encoded = try? JSONEncoder().encode(hook.envelope) else {
    if options.strict { exit(2) }
    exit(0)
}

let result = send(
    encoded + Data([0x0A]),
    to: options.socketPath,
    waitingForResponse: hook.envelope.interaction != nil,
    timeout: options.responseTimeout
)

if let decision = result.decision,
   let interaction = hook.envelope.interaction,
   decision.requestId == interaction.id,
   let output = HookNormalizer.providerOutput(
       decision: decision,
       interaction: interaction,
       toolInput: hook.toolInput
   ) {
    FileHandle.standardOutput.write(output)
    FileHandle.standardOutput.write(Data([0x0A]))
}

if options.strict, !result.delivered { exit(1) }

func parseOptions(_ arguments: [String]) -> HookOptions {
    var options = HookOptions()
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--agent" where index + 1 < arguments.count:
            options.agent = AgentKind(rawValue: arguments[index + 1].lowercased()) ?? .unknown
            index += 2
        case "--socket" where index + 1 < arguments.count:
            options.socketPath = arguments[index + 1]
            index += 2
        case "--response-timeout" where index + 1 < arguments.count:
            options.responseTimeout = max(1, Int(arguments[index + 1]) ?? 300)
            index += 2
        case "--intercept" where index + 1 < arguments.count:
            options.intercept = InterceptPolicy(rawValue: arguments[index + 1]) ?? .background
            index += 2
        case "--strict":
            options.strict = true
            index += 1
        default:
            if arguments[index].first == "{" {
                options.payloadArgument = arguments[index].data(using: .utf8)
            }
            index += 1
        }
    }
    return options
}

/// Suppression must be pane-precise or not happen at all: guessing at app
/// level once hid a question behind an unfocused Warp tab, invisible until
/// timeout. Only iTerm2 and Terminal.app can prove which tty is focused;
/// everywhere else the card always goes to the notch.
func shouldSuppressInteraction(options: HookOptions, ownTTY: String?) -> Bool {
    switch options.intercept {
    case .always: return false
    case .never: return true
    case .background: break
    }
    guard let program = ProcessInfo.processInfo.environment["TERM_PROGRAM"],
          let ownTTY,
          let script = frontTTYScript(forProgram: program) else { return false }
    let candidates = TerminalCatalog.bundleIdentifiers(forProgram: program)
    guard !candidates.isEmpty,
          let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
          candidates.contains(frontmost) else {
        return false
    }
    guard let frontTTY = runAppleScript(script, timeout: 0.4) else { return true }
    return frontTTY.trimmingCharacters(in: .whitespacesAndNewlines) == "/dev/\(ownTTY)"
}

func frontTTYScript(forProgram program: String) -> String? {
    switch program {
    case "iTerm.app":
        return "tell application \"iTerm2\" to tty of current session of current tab of current window"
    case "Apple_Terminal":
        return "tell application \"Terminal\" to tty of selected tab of front window"
    default:
        return nil
    }
}

func runAppleScript(_ script: String, timeout: TimeInterval) -> String? {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    process.standardOutput = output
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return nil }

    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        process.waitUntilExit()
        done.signal()
    }
    guard done.wait(timeout: .now() + timeout) == .success else {
        process.terminate()
        return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
}

/// One walk up the process tree finds both the controlling terminal (for
/// exact tab jumps) and the agent's own PID (for liveness checks).
func agentAncestry(agent: AgentKind?) -> (tty: String?, agentPid: Int32?) {
    let agentNames: Set<String> = ["claude", "codex", "cursor", "gemini", "opencode"]
    var pid = getppid()
    var tty: String?
    var agentPid: Int32?
    for _ in 0..<12 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { break }
        if tty == nil, info.e_tdev != 0, info.e_tdev != UInt32.max,
           let name = devname(dev_t(bitPattern: info.e_tdev), mode_t(S_IFCHR)) {
            tty = String(cString: name)
        }
        if agentPid == nil {
            let comm = withUnsafeBytes(of: info.pbi_comm) { buffer -> String in
                String(cString: buffer.bindMemory(to: CChar.self).baseAddress!)
            }.lowercased()
            // Versioned installs run a binary named after the release
            // (e.g. "2.1.215"), so the executable path decides.
            var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let path = pathLength > 0 ? String(cString: pathBuffer).lowercased() : ""
            if agentNames.contains(comm) || agentNames.contains(where: path.contains) {
                agentPid = pid
            }
        }
        if tty != nil, agentPid != nil { break }
        guard info.pbi_ppid > 1 else { break }
        pid = pid_t(info.pbi_ppid)
    }
    return (tty, agentPid)
}

func send(
    _ data: Data,
    to socketPath: String,
    waitingForResponse: Bool,
    timeout: Int
) -> (delivered: Bool, decision: InteractionDecision?) {
    signal(SIGPIPE, SIG_IGN)
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return (false, nil) }
    defer { Darwin.close(descriptor) }

    var sendTimeout = timeval(tv_sec: 0, tv_usec: 500_000)
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
    var receiveTimeout = timeval(tv_sec: timeout, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return (false, nil) }
    withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
        tuplePointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { target in
            for (index, byte) in bytes.enumerated() { target[index] = byte }
        }
    }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, length)
        }
    }
    guard connected == 0 else { return (false, nil) }

    let delivered = data.withUnsafeBytes { buffer -> Bool in
        guard let base = buffer.baseAddress else { return false }
        var written = 0
        while written < data.count {
            let count = Darwin.write(descriptor, base.advanced(by: written), data.count - written)
            guard count > 0 else { return false }
            written += count
        }
        return true
    }
    guard delivered, waitingForResponse else { return (delivered, nil) }

    var collected = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while !collected.contains(0x0A), collected.count <= 65_536 {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count > 0 else { break }
        collected.append(buffer, count: count)
    }
    guard let line = collected.split(separator: 0x0A).first,
          let decision = try? JSONDecoder().decode(InteractionDecision.self, from: Data(line)) else {
        return (true, nil)
    }
    return (true, decision)
}
