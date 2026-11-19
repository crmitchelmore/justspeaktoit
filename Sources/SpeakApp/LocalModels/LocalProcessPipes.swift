#if !APP_STORE
import Darwin
import Foundation

/// Worker-owned descriptors. Parent ends are nonblocking, so a child that never
/// reads stdin, or a descendant holding stdout open, cannot trap the deadline loop.
final class LocalProcessPipes {
    enum End: Int, CaseIterable {
        case inputRead, inputWrite, outputRead, outputWrite, errorRead, errorWrite
    }

    private var descriptors = [Int32](repeating: -1, count: 6)
    private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)

    init() throws {
        do {
            for index in stride(from: 0, to: 6, by: 2) {
                var pair: [Int32] = [-1, -1]
                guard pipe(&pair) == 0 else { throw LocalProcessError.systemCall("pipe", errno) }
                descriptors[index] = pair[0]
                descriptors[index + 1] = pair[1]
            }
            for index in descriptors.indices {
                let descriptor = descriptors[index]
                if descriptor < 3 {
                    let duplicated = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
                    guard duplicated >= 0 else { throw LocalProcessError.systemCall("duplicate pipe", errno) }
                    _ = Darwin.close(descriptor)
                    descriptors[index] = duplicated
                } else if fcntl(descriptor, F_SETFD, FD_CLOEXEC) == -1 {
                    throw LocalProcessError.systemCall("close-on-exec", errno)
                }
            }
            for end in [End.inputWrite, .outputRead, .errorRead] {
                let flags = fcntl(self[end], F_GETFL)
                guard flags != -1, fcntl(self[end], F_SETFL, flags | O_NONBLOCK) != -1 else {
                    throw LocalProcessError.systemCall("nonblocking pipe", errno)
                }
            }
            // Suppress SIGPIPE only for our stdin pipe; never change app-wide signal handling.
            guard fcntl(self[.inputWrite], F_SETNOSIGPIPE, 1) != -1 else {
                throw LocalProcessError.systemCall("stdin SIGPIPE protection", errno)
            }
        } catch {
            closeAll()
            throw error
        }
    }

    deinit { closeAll() }

    private subscript(_ end: End) -> Int32 { descriptors[end.rawValue] }

    func close(_ end: End) {
        let descriptor = self[end]
        guard descriptor >= 0 else { return }
        descriptors[end.rawValue] = -1
        _ = Darwin.close(descriptor)
    }

    private func closeAll() {
        for end in End.allCases { close(end) }
    }

    func closeChildEnds() {
        for end in [End.inputRead, .outputWrite, .errorWrite] { close(end) }
    }

    var outputIsClosed: Bool { self[.outputRead] < 0 && self[.errorRead] < 0 }

    func readOutput(into output: ProcessOutputAccumulator) throws {
        // One bounded read per stream per loop: continuous output must not starve
        // cancellation checks or the other pipe.
        for end in [End.outputRead, .errorRead] where self[end] >= 0 {
            let descriptor = self[end]
            let count = readBuffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                let data = Data(readBuffer.prefix(count))
                if end == .outputRead { output.appendStdout(data) } else { output.appendStderr(data) }
            } else if count == 0 {
                close(end)
            } else if errno != EAGAIN && errno != EINTR {
                throw LocalProcessError.systemCall("read output", errno)
            }
        }
    }

    func writeInput(_ input: Data, offset: inout Int) throws {
        guard self[.inputWrite] >= 0 else { return }
        guard offset < input.count else {
            close(.inputWrite)
            return
        }
        let count = input.withUnsafeBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return 0 }
            return Darwin.write(self[.inputWrite], base.advanced(by: offset), min(64 * 1024, input.count - offset))
        }
        if count > 0 {
            offset += count
        } else if count == -1, errno == EPIPE {
            // Let the child's stderr/exit status explain an early rejection of input.
            close(.inputWrite)
        } else if count == -1, errno != EAGAIN && errno != EINTR {
            throw LocalProcessError.systemCall("write input", errno)
        }
    }

    func waitForActivity() throws {
        var descriptors = [
            pollfd(fd: self[.outputRead], events: Int16(POLLIN), revents: 0),
            pollfd(fd: self[.errorRead], events: Int16(POLLIN), revents: 0),
            pollfd(fd: self[.inputWrite], events: Int16(POLLOUT), revents: 0)
        ]
        if poll(&descriptors, nfds_t(descriptors.count), 20) == -1, errno != EINTR {
            throw LocalProcessError.systemCall("poll", errno)
        }
    }

    func spawn(executableURL: URL, arguments: [String], environment: [String: String]) throws -> pid_t {
        let environment = ProcessInfo.processInfo.environment.merging(environment) { _, replacement in replacement }
        let argumentStrings = [executableURL.path] + arguments
        let environmentStrings = environment.map { "\($0.key)=\($0.value)" }
        guard executableURL.isFileURL, argumentStrings.allSatisfy({ !$0.contains("\0") }),
            environmentStrings.allSatisfy({ !$0.contains("\0") })
        else { throw LocalProcessError.failed("The local process configuration contains an invalid argument.") }
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions), operation: "initialize file actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes), operation: "initialize spawn attributes")
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setpgroup(&attributes, 0), operation: "create process group")
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        try check(posix_spawnattr_setflags(&attributes, flags), operation: "set spawn flags")
        let redirections = [(End.inputRead, STDIN_FILENO), (.outputWrite, STDOUT_FILENO), (.errorWrite, STDERR_FILENO)]
        for (end, destination) in redirections {
            try check(posix_spawn_file_actions_adddup2(&actions, self[end], destination), operation: "redirect pipe")
        }
        for descriptor in descriptors {
            try check(posix_spawn_file_actions_addclose(&actions, descriptor), operation: "close child pipe")
        }
        var identifier: pid_t = 0
        let result = try withCStringArray(argumentStrings) { arguments in
            try withCStringArray(environmentStrings) { environment in
                posix_spawn(&identifier, executableURL.path, &actions, &attributes, arguments, environment)
            }
        }
        try check(result, operation: "spawn")
        return identifier
    }

    private func check(_ result: Int32, operation: String) throws {
        if result != 0 { throw LocalProcessError.systemCall(operation, result) }
    }

    private func withCStringArray<Result>(
        _ strings: [String], body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) throws -> Result {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        defer { pointers.forEach { free($0) } }
        for string in strings {
            guard let pointer = strdup(string) else { throw LocalProcessError.systemCall("allocate arguments", ENOMEM) }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            // The terminating nil guarantees nonempty storage, including an empty env.
            guard let base = buffer.baseAddress else {
                throw LocalProcessError.systemCall("allocate arguments", ENOMEM)
            }
            return try body(base)
        }
    }
}
#endif
