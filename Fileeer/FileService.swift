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

    /// Connects and reads newline-delimited file paths until the server closes the connection.
    func fetchFileList() async throws -> [RemoteFile] {
        let data = try await connectAndReadAll()
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

    private func connectAndReadAll() async throws -> Data {
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
                    receiveLoop()
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
            url.append(path: component)
        }
        return url
    }
}
