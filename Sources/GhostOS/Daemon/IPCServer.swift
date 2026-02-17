// IPCServer.swift — Unix domain socket server for Ghost OS JSON-RPC API

import Foundation

/// IPCServer listens on a Unix domain socket and handles JSON-RPC requests.
/// Each connection can send one request and receives one response (request-response pattern).
/// The socket path defaults to ~/.ghost-os/ghost.sock
@MainActor
public final class IPCServer {
    private let socketPath: String
    private let handler: RPCHandler
    private var serverSocket: Int32 = -1
    private var isRunning = false

    public init(handler: RPCHandler, socketPath: String? = nil) {
        self.handler = handler
        self.socketPath = socketPath ?? IPCServer.defaultSocketPath()
    }

    public static func defaultSocketPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.ghost-os/ghost.sock"
    }

    /// Start listening for connections
    public func start() throws {
        // Ensure directory exists
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )

        // Remove stale socket file
        if FileManager.default.fileExists(atPath: socketPath) {
            try FileManager.default.removeItem(atPath: socketPath)
        }

        // Create socket
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw GhostError.ipcError("Failed to create socket: \(String(cString: strerror(errno)))")
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
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
            close(serverSocket)
            throw GhostError.ipcError("Failed to bind socket: \(String(cString: strerror(errno)))")
        }

        // Listen
        guard listen(serverSocket, 5) == 0 else {
            close(serverSocket)
            throw GhostError.ipcError("Failed to listen: \(String(cString: strerror(errno)))")
        }

        isRunning = true
        print("[ghost-daemon] Listening on \(socketPath)")

        // Accept connections in a background task
        // We dispatch back to MainActor for each request since AXorcist requires it
        let sock = serverSocket
        let handlerRef = handler

        Task.detached {
            while true {
                let clientSocket = accept(sock, nil, nil)
                if clientSocket < 0 {
                    break // Server shut down
                }

                // Read request
                var buffer = [UInt8](repeating: 0, count: 65536)
                let bytesRead = read(clientSocket, &buffer, buffer.count)

                if bytesRead > 0 {
                    let requestData = Data(buffer[0 ..< bytesRead])

                    // Process on MainActor (required for AXorcist)
                    let responseData = await MainActor.run {
                        handlerRef.handle(requestJSON: requestData)
                    }

                    // Send response
                    responseData.withUnsafeBytes { ptr in
                        _ = write(clientSocket, ptr.baseAddress!, responseData.count)
                    }
                }

                close(clientSocket)
            }
        }
    }

    /// Stop the server
    public func stop() {
        isRunning = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        try? FileManager.default.removeItem(atPath: socketPath)
        print("[ghost-daemon] Stopped")
    }

    /// Send a request to a running daemon (static client method)
    public static func sendRequest(_ request: RPCRequest, socketPath: String? = nil) throws -> RPCResponse {
        let path = socketPath ?? defaultSocketPath()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let requestData = try encoder.encode(request)

        // Connect
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw GhostError.ipcError("Failed to create socket")
        }
        defer { close(sock) }

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
            throw GhostError.daemonNotRunning
        }

        // Send
        requestData.withUnsafeBytes { ptr in
            _ = write(sock, ptr.baseAddress!, requestData.count)
        }

        // Receive
        var buffer = [UInt8](repeating: 0, count: 1_048_576) // 1MB buffer
        let bytesRead = read(sock, &buffer, buffer.count)
        guard bytesRead > 0 else {
            throw GhostError.ipcError("No response from daemon")
        }

        let responseData = Data(buffer[0 ..< bytesRead])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RPCResponse.self, from: responseData)
    }
}
