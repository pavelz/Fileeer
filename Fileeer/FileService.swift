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
        let rawData = try await connectAndReadUntilIdle()
        let listData = extractFileListData(from: rawData)
        guard let text = String(data: listData, encoding: .utf8) else { throw FileServiceError.decodingError }
        let paths = text.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "0" && $0 != "\0" }
        return paths.map { RemoteFile(path: $0) }
    }

    /// Opens a new connection, sends the requested path followed by a newline,
    /// then reads all bytes, strips the leading file list delimiter, and writes the file body to Documents.
    func downloadFile(atPath path: String) async throws -> URL {
        // Send path + newline then read all bytes
        let requestData = (path + "\n").data(using: .utf8)!
        let rawData = try await connectSendAndReadAll(send: requestData)
        let fileData = extractFileContent(from: rawData)

        do {
            let destinationURL = URL.documentsDirectory.appending(path: path)
            try fileData.write(to: destinationURL, options: .atomic)
            return destinationURL
        } catch {
            throw FileServiceError.fileWriteFailed
        }
    }

    // MARK: - Delimiter Stripping Helpers

    /// Extracts the file content by removing the leading file list and the delimiter.
    /// Supports a null byte (`0x00`), a line with ASCII `'0'`, or `'0'` right after the file list.
    private func extractFileContent(from data: Data) -> Data {
        // 1. Check for null byte delimiter (0x00)
        if let nullIndex = data.firstIndex(of: 0x00) {
            var startIndex = data.index(after: nullIndex)
            // Skip optional trailing \r\n or \n immediately after the null byte
            if startIndex < data.endIndex && data[startIndex] == 0x0D {
                startIndex = data.index(after: startIndex)
            }
            if startIndex < data.endIndex && data[startIndex] == 0x0A {
                startIndex = data.index(after: startIndex)
            }
            return data.subdata(in: startIndex..<data.endIndex)
        }

        // 2. Check for ASCII '0' delimiter with newline boundaries
        let newlinePatterns = [
            "\r\n0\r\n",
            "\n0\n",
            "\r\n0\n",
            "0\r\n",
            "0\n"
        ]
        for pattern in newlinePatterns {
            if let range = data.range(of: Data(pattern.utf8)) {
                return data.subdata(in: range.upperBound..<data.endIndex)
            }
        }

        // 3. Check for newline followed immediately by ASCII '0' (e.g. "...path\n0<binary/text content>")
        let directPatterns = [
            "\r\n0",
            "\n0"
        ]
        for pattern in directPatterns {
            if let range = data.range(of: Data(pattern.utf8)) {
                return data.subdata(in: range.upperBound..<data.endIndex)
            }
        }

        // 4. Fallback if the data starts directly with ASCII '0'
        if data.first == 0x30 {
            return data.subdata(in: data.index(after: data.startIndex)..<data.endIndex)
        }

        return data
    }

    /// Extracts the file list bytes occurring before the delimiter.
    private func extractFileListData(from data: Data) -> Data {
        if let nullIndex = data.firstIndex(of: 0x00) {
            return data.subdata(in: data.startIndex..<nullIndex)
        }

        let delimiterPatterns = [
            "\r\n0\r\n",
            "\n0\n",
            "\r\n0\n",
            "0\r\n",
            "0\n",
            "\r\n0",
            "\n0"
        ]
        for pattern in delimiterPatterns {
            if let range = data.range(of: Data(pattern.utf8)) {
                return data.subdata(in: data.startIndex..<range.lowerBound)
            }
        }

        return data
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

}
