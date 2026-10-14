import Foundation
import Network

struct RemoteFile: Identifiable, Hashable, Codable {
    let id: String
    let path: String

    init(path: String) {
        self.id = path
        self.path = path
    }
}

enum FileServiceError: Error, LocalizedError {
    case invalidEndpoint
    case connectionFailed
    case receiveFailed
    case sendFailed
    case decodingError
    case fileWriteFailed

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Invalid server endpoint"
        case .connectionFailed: return "Failed to connect to server"
        case .receiveFailed: return "Failed to receive data from server"
        case .sendFailed: return "Failed to send data to server"
        case .decodingError: return "Failed to decode server data"
        case .fileWriteFailed: return "Failed to write file to disk"
        }
    }
}

final class FileService {
    // TCP endpoint configuration
    let host: NWEndpoint.Host
    let port: NWEndpoint.Port

    init(host: String, port: UInt16) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    // MARK: - Public API

/// Connects and reads newline-delimited file paths until data stops coming or the connection closes.
    func fetchFileList() async throws -> [RemoteFile] {
        let data = try await connectAndReadUntilIdle()
        guard let text = String(data: data, encoding: .utf8) else { throw FileServiceError.decodingError }
        let paths = text.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
        return paths.map { RemoteFile(path: $0) }
    }

    /// Opens a new connection, sends the requested path followed by a newline, then reads all bytes until close and writes to Documents.
    func downloadFile(atPath path: String) async throws -> URL {
        // Send path + newline then read all bytes
        let requestData = (path + "\n").data(using: .utf8)!
        let data = try await connectSendAndReadAll(send: requestData)

        let destinationURL = try destinationURLForDownloaded(path: path)
        do {
            try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destinationURL, options: .atomic)
            return destinationURL
        } catch {
            throw FileServiceError.fileWriteFailed
        }
    }

    // MARK: - Networking helpers

    private func makeConnection() -> NWConnection {
        let params = NWParameters.tcp
        let conn = NWConnection(host: host, port: port, using: params)
        return conn
    }

    private func connectAndReadUntilIdle(idleTimeout: TimeInterval = 0.5, totalTimeout: TimeInterval = 5.0) async throws -> Data {
        let conn = makeConnection()
        let queue = DispatchQueue(label: "com.fileservice.network")

        return try await withCheckedThrowingContinuation { continuation in
            var buffer = Data()
            var idleWorkItem: DispatchWorkItem?
            var timeoutWorkItem: DispatchWorkItem?
            var isResumed = false

            func finish(with result: Result<Data, Error>) {
                guard !isResumed else { return }
                isResumed = true
                idleWorkItem?.cancel()
                timeoutWorkItem?.cancel()
                conn.cancel()
                switch result {
                case .success(let data):
                    continuation.resume(returning: data)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            func resetIdleTimer() {
                idleWorkItem?.cancel()
                let item = DispatchWorkItem {
                    if !buffer.isEmpty {
                        finish(with: .success(buffer))
                    } else {
                        finish(with: .failure(FileServiceError.receiveFailed))
                    }
                }
                idleWorkItem = item
                queue.asyncAfter(deadline: .now() + idleTimeout, execute: item)
            }

            // Overall timeout in case no response is received
            let timeout = DispatchWorkItem {
                if !buffer.isEmpty {
                    finish(with: .success(buffer))
                } else {
                    finish(with: .failure(FileServiceError.connectionFailed))
                }
            }
            timeoutWorkItem = timeout
            queue.asyncAfter(deadline: .now() + totalTimeout, execute: timeout)

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    receiveLoop()
                case .failed(let error):
                    finish(with: .failure(error))
                case .cancelled:
                    break
                default:
                    break
                }
            }

            func receiveLoop() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let error = error {
                        finish(with: .failure(error))
                        return
                    }
                    if let data = data, !data.isEmpty {
                        buffer.append(data)
                        resetIdleTimer()
                    }
                    if isComplete {
                        finish(with: .success(buffer))
                    } else {
                        receiveLoop()
                    }
                }
            }

            conn.start(queue: queue)
        }
    }

    private func connectSendAndReadAll(send requestData: Data) async throws -> Data {
        let conn = makeConnection()
        return try await withCheckedThrowingContinuation { continuation in
            var buffer = Data()

            func fail(_ error: Error) {
                conn.cancel()
                continuation.resume(throwing: error)
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Send request
                    conn.send(content: requestData, completion: .contentProcessed { error in
                        if let error = error {
                            fail(error)
                            return
                        }
                        receiveLoop()
                    })
                case .failed(let error):
                    fail(error)
                case .cancelled:
                    break
                default:
                    break
                }
            }

            func receiveLoop() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let error = error {
                        fail(error)
                        return
                    }
                    if let data = data, !data.isEmpty {
                        buffer.append(data)
                    }
                    if isComplete {
                        conn.cancel()
                        continuation.resume(returning: buffer)
                    } else {
                        receiveLoop()
                    }
                }
            }

            conn.start(queue: .global(qos: .userInitiated))
        }
    }

    // MARK: - File destinations

    private func destinationURLForDownloaded(path: String) throws -> URL {
        let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        // Preserve nested folders from server path
        let safePath = path.split(separator: "/").map(String.init)
        var url = docs
        for component in safePath {
            print(component)
            url.append(path: component)
        }
        return url
    }
}
