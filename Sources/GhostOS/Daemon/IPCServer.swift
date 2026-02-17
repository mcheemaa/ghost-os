// IPCServer.swift — Unix domain socket server for Ghost OS JSON-RPC API

import Foundation

/// Thread-safe set for tracking active client file descriptors.
/// Uses NSLock for synchronization, safe to use from any isolation context.
/// Explicitly nonisolated to avoid inheriting @MainActor from IPCServer.
private final class ClientTracker: Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var clients: Set<Int32> = []

    nonisolated func insert(_ fd: Int32) {
        lock.lock()
        clients.insert(fd)
        lock.unlock()
    }

    nonisolated func remove(_ fd: Int32) {
        lock.lock()
        clients.remove(fd)
        lock.unlock()
    }

    /// Remove and return all tracked file descriptors
    nonisolated func removeAll() -> Set<Int32> {
        lock.lock()
        let result = clients
        clients.removeAll()
        lock.unlock()
        return result
    }
}

/// IPCServer listens on a Unix domain socket and handles JSON-RPC requests.
/// Uses newline-delimited JSON framing: each request/response is a single JSON line terminated by \n.
/// Handles multiple concurrent clients via GCD dispatch sources.
/// The socket path defaults to ~/.ghost-os/ghost.sock
@MainActor
public final class IPCServer {
    private let socketPath: String
    private let handler: RPCHandler
    private var serverSocket: Int32 = -1
    private var isRunning = false
    private var acceptSource: (any DispatchSourceRead)?
    private let acceptQueue = DispatchQueue(label: "ghost.ipc.accept")
    private let clientQueue = DispatchQueue(label: "ghost.ipc.clients", attributes: .concurrent)

    /// Track active client file descriptors for cleanup (thread-safe)
    private let clientTracker = ClientTracker()

    public init(handler: RPCHandler, socketPath: String? = nil) {
        self.handler = handler
        self.socketPath = socketPath ?? IPCServer.defaultSocketPath()
    }

    public static func defaultSocketPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.ghost-os/ghost.sock"
    }

    /// Directory containing the socket and PID files
    public static func runtimeDirectory() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.ghost-os"
    }

    // MARK: - Server lifecycle

    /// Start listening for connections
    public func start() throws {
        // Ensure runtime directory exists
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )

        // Remove stale socket file from a previous run
        if FileManager.default.fileExists(atPath: socketPath) {
            try FileManager.default.removeItem(atPath: socketPath)
        }

        // Create socket
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw GhostError.ipcError("Failed to create socket: \(errnoMessage())")
        }

        // Allow address reuse
        var reuseAddr: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        // Bind to Unix domain socket path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(serverSocket)
            serverSocket = -1
            throw GhostError.ipcError("Socket path too long: \(socketPath)")
        }
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path.0) { dest in
                _ = strcpy(dest, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(serverSocket)
            serverSocket = -1
            throw GhostError.ipcError("Failed to bind socket: \(errnoMessage())")
        }

        // Listen with a reasonable backlog
        guard listen(serverSocket, 8) == 0 else {
            Darwin.close(serverSocket)
            serverSocket = -1
            throw GhostError.ipcError("Failed to listen on socket: \(errnoMessage())")
        }

        // Set socket to non-blocking for use with GCD dispatch source
        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        isRunning = true

        // Create a dispatch source to accept incoming connections
        let source = DispatchSource.makeReadSource(
            fileDescriptor: serverSocket,
            queue: acceptQueue
        )

        let sock = serverSocket
        let tracker = clientTracker
        let queue = clientQueue
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.acceptConnections(on: sock, tracker: tracker, queue: queue)
        }

        source.setCancelHandler {
            if sock >= 0 {
                Darwin.close(sock)
            }
        }

        acceptSource = source
        source.resume()

        print("[ghost-daemon] Listening on \(socketPath)")
    }

    /// Stop the server and clean up all resources
    public func stop() {
        guard isRunning else { return }
        isRunning = false

        // Cancel the accept source (this also closes the server socket via cancel handler)
        if let source = acceptSource {
            source.cancel()
            acceptSource = nil
        } else if serverSocket >= 0 {
            Darwin.close(serverSocket)
        }
        serverSocket = -1

        // Close all active client connections
        let clients = clientTracker.removeAll()
        for fd in clients {
            Darwin.close(fd)
        }

        // Remove socket file
        try? FileManager.default.removeItem(atPath: socketPath)
        print("[ghost-daemon] IPC server stopped")
    }

    // MARK: - Connection handling

    /// Accept all pending connections (called from dispatch source)
    private nonisolated func acceptConnections(
        on serverFD: Int32,
        tracker: ClientTracker,
        queue: DispatchQueue
    ) {
        while true {
            let clientFD = accept(serverFD, nil, nil)
            if clientFD < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    break // No more pending connections
                }
                if err == EBADF || err == EINVAL {
                    break // Server socket closed
                }
                print("[ghost-daemon] Accept error: \(String(cString: strerror(err)))")
                break
            }

            tracker.insert(clientFD)

            queue.async { [weak self] in
                guard let self else {
                    Darwin.close(clientFD)
                    tracker.remove(clientFD)
                    return
                }
                self.handleClient(clientFD, tracker: tracker)
            }
        }
    }

    /// Handle a single client connection: read newline-delimited requests, dispatch, respond
    private nonisolated func handleClient(_ clientFD: Int32, tracker: ClientTracker) {
        defer {
            Darwin.close(clientFD)
            tracker.remove(clientFD)
        }

        // Set a read timeout of 10 seconds to avoid hanging on broken clients
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Ignore SIGPIPE on this socket (SO_NOSIGPIPE on macOS)
        var noSigPipe: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var buffer = Data()
        let chunkSize = 8192
        var readBuf = [UInt8](repeating: 0, count: chunkSize)

        // Read loop: accumulate data until we get complete newline-delimited messages
        while true {
            let bytesRead = read(clientFD, &readBuf, chunkSize)

            if bytesRead < 0 {
                let err = errno
                if err == EINTR { continue }
                if err == EAGAIN || err == EWOULDBLOCK {
                    break // Timeout
                }
                break // ECONNRESET, EPIPE, etc.
            }

            if bytesRead == 0 {
                break // Client disconnected
            }

            buffer.append(contentsOf: readBuf[0..<bytesRead])

            // Process all complete lines in the buffer
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[(newlineIndex + 1)...])

                if lineData.isEmpty { continue }

                // Dispatch on MainActor (required for AXorcist accessibility calls)
                let responseData: Data = DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        self.handler.handle(requestJSON: Data(lineData))
                    }
                }

                // Write response as newline-delimited JSON
                var responseWithNewline = responseData
                responseWithNewline.append(UInt8(ascii: "\n"))

                if !writeAll(fd: clientFD, data: responseWithNewline) {
                    return // Client disconnected
                }
            }

            // Safety: prevent unbounded buffer growth from a misbehaving client
            if buffer.count > 1_048_576 {
                print("[ghost-daemon] Client buffer exceeded 1MB without newline, disconnecting")
                return
            }
        }
    }

    /// Write all bytes to a file descriptor, handling partial writes and EINTR.
    /// Returns false if the write fails (broken pipe, connection reset, etc.)
    private nonisolated func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { ptr -> Bool in
            guard let base = ptr.baseAddress else { return false }
            var totalWritten = 0
            let count = data.count
            while totalWritten < count {
                let written = write(fd, base + totalWritten, count - totalWritten)
                if written < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    return false
                }
                if written == 0 { return false }
                totalWritten += written
            }
            return true
        }
    }

    // MARK: - Static client method

    /// Send a request to a running daemon and return the response.
    /// Uses newline-delimited JSON framing with a 5-second timeout.
    public static func sendRequest(_ request: RPCRequest, socketPath: String? = nil) throws -> RPCResponse {
        let path = socketPath ?? defaultSocketPath()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var requestData = try encoder.encode(request)
        requestData.append(UInt8(ascii: "\n"))

        // Create socket
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw GhostError.ipcError("Failed to create socket")
        }
        defer { Darwin.close(sock) }

        // Suppress SIGPIPE
        var noSigPipe: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // Set timeouts (5 seconds for send and receive)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Connect to daemon socket
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path.0) { dest in
                _ = strcpy(dest, ptr)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            let err = errno
            if err == ECONNREFUSED || err == ENOENT {
                throw GhostError.daemonNotRunning
            }
            throw GhostError.ipcError("Failed to connect: \(String(cString: strerror(err)))")
        }

        // Send request with newline delimiter
        let sendSuccess = requestData.withUnsafeBytes { ptr -> Bool in
            guard let base = ptr.baseAddress else { return false }
            var totalWritten = 0
            let count = requestData.count
            while totalWritten < count {
                let written = write(sock, base + totalWritten, count - totalWritten)
                if written < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    return false
                }
                if written == 0 { return false }
                totalWritten += written
            }
            return true
        }
        guard sendSuccess else {
            throw GhostError.ipcError("Failed to send request to daemon")
        }

        // Read response until we get a complete newline-delimited line
        var responseBuffer = Data()
        let chunkSize = 8192
        var readBuf = [UInt8](repeating: 0, count: chunkSize)

        while true {
            let bytesRead = read(sock, &readBuf, chunkSize)

            if bytesRead < 0 {
                let err = errno
                if err == EINTR { continue }
                if err == EAGAIN || err == EWOULDBLOCK {
                    throw GhostError.ipcError("Timeout waiting for daemon response")
                }
                throw GhostError.ipcError("Read error: \(String(cString: strerror(err)))")
            }

            if bytesRead == 0 {
                break // Server closed connection
            }

            responseBuffer.append(contentsOf: readBuf[0..<bytesRead])

            // Check for complete line
            if let newlineIndex = responseBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = Data(responseBuffer[responseBuffer.startIndex..<newlineIndex])
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(RPCResponse.self, from: lineData)
            }

            // Safety limit
            if responseBuffer.count > 1_048_576 {
                throw GhostError.ipcError("Response exceeded 1MB without completing")
            }
        }

        // Try parsing buffer as-is (server may have closed without trailing newline)
        guard !responseBuffer.isEmpty else {
            throw GhostError.ipcError("No response from daemon")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RPCResponse.self, from: responseBuffer)
    }

    // MARK: - Helpers

    private func errnoMessage() -> String {
        String(cString: strerror(errno))
    }
}
