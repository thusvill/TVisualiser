import Foundation

final class FTPControlConnection {
    enum FTPError: Error, LocalizedError {
        case connectionFailed
        case unexpectedResponse(String)
        case dataConnectionFailed
        case notConnected

        var errorDescription: String? {
            switch self {
            case .connectionFailed: return "Could not connect to FTP server."
            case .unexpectedResponse(let r): return "Unexpected FTP response: \(r)"
            case .dataConnectionFailed: return "Could not open FTP data connection."
            case .notConnected: return "FTP control connection is not open."
            }
        }
    }

    private let host: String
    private let port: Int
    private let username: String
    private let password: String

    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private let queue = DispatchQueue(label: "ftp.control.connection")
    private var isConnected = false

    init(host: String, port: Int, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username.isEmpty ? "anonymous" : username
        self.password = password
    }

    /// Opens the control connection and logs in once; subsequent calls reuse the session.
    func connectIfNeeded() throws {
        try queue.sync {
            guard !isConnected else { return }

            var inStream: InputStream?
            var outStream: OutputStream?
            Stream.getStreamsToHost(withName: host, port: port, inputStream: &inStream, outputStream: &outStream)
            guard let input = inStream, let output = outStream else {
                throw FTPError.connectionFailed
            }
            input.open()
            output.open()
            inputStream = input
            outputStream = output

            _ = try readResponseLocked() // 220 welcome
            try sendCommandLocked("USER \(username)")
            _ = try readResponseLocked() // 331
            try sendCommandLocked("PASS \(password)")
            let loginResponse = try readResponseLocked() // 230
            guard loginResponse.hasPrefix("230") else {
                throw FTPError.unexpectedResponse(loginResponse)
            }
            try sendCommandLocked("TYPE I")
            _ = try readResponseLocked() // 200

            isConnected = true
        }
    }

    func close() {
        queue.sync {
            inputStream?.close()
            outputStream?.close()
            inputStream = nil
            outputStream = nil
            isConnected = false
        }
    }

    /// Returns the size in bytes of a remote file using SIZE.
    func fileSize(path: String) throws -> Int64 {
        try connectIfNeeded()
        return try queue.sync {
            try sendCommandLocked("SIZE \(path)")
            let response = try readResponseLocked()
            if response.hasPrefix("213") {
                let parts = response.split(separator: " ")
                if parts.count >= 2, let size = Int64(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return size
                }
            }
            throw FTPError.unexpectedResponse(response)
        }
    }

    /// Downloads a byte range [offset, offset+length) from `path`, invoking `onChunk`
    /// for each block read. Opens a fresh PASV data connection per call, reusing
    /// the already-authenticated control connection.
    ///
    /// IMPORTANT ordering: the data socket must be opened right after PASV,
    /// *before* REST/RETR are sent. This server's RETR handler blocks on
    /// accept() and only replies "150" once the client has connected to the
    /// data port — so if the client waits for "150" before connecting, both
    /// sides wait on each other and the transfer times out with 425.
    func retrieveRange(path: String, offset: Int64, length: Int64?, onChunk: (Data) -> Void) throws {
        try connectIfNeeded()
        try queue.sync {
            try sendCommandLocked("PASV")
            let pasvResponse = try readResponseLocked()
            let (dataHost, dataPort) = try parsePASVLocked(pasvResponse)

            // Open (and fully connect) the data socket BEFORE sending REST/RETR.
            let dataInput = try openDataConnectionLocked(host: dataHost, port: dataPort)
            defer { dataInput.close() }

            try sendCommandLocked("REST \(offset)")
            _ = try readResponseLocked() // 350

            try sendCommandLocked("RETR \(path)")
            let retrResponse = try readResponseLocked() // 150
            guard retrResponse.hasPrefix("150") else {
                throw FTPError.unexpectedResponse(retrResponse)
            }

            try readDataLocked(from: dataInput, maxLength: length, onChunk: onChunk)

            _ = try? readResponseLocked() // 226 Transfer complete (best-effort)
        }
    }

    // MARK: - Private (must run on `queue`)

    private func sendCommandLocked(_ command: String) throws {
        guard let output = outputStream else { throw FTPError.notConnected }
        let line = command + "\r\n"
        guard let data = line.data(using: .utf8) else { return }
        let written = data.withUnsafeBytes {
            output.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: data.count)
        }
        guard written > 0 else { throw FTPError.connectionFailed }
        print("[FTP ->] \(command)")
    }

    private func readResponseLocked() throws -> String {
        guard let input = inputStream else { throw FTPError.notConnected }
        var buffer = [UInt8](repeating: 0, count: 2048)
        let count = input.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { throw FTPError.unexpectedResponse("empty response") }
        let response = String(bytes: buffer[0..<count], encoding: .utf8) ?? ""
        print("[FTP <-] \(response.trimmingCharacters(in: .whitespacesAndNewlines))")
        return response
    }

    private func parsePASVLocked(_ response: String) throws -> (String, Int) {
        guard let start = response.firstIndex(of: "("),
              let end = response.firstIndex(of: ")") else {
            throw FTPError.unexpectedResponse(response)
        }
        let numbers = response[response.index(after: start)..<end]
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard numbers.count == 6 else { throw FTPError.unexpectedResponse(response) }
        let ip = "\(numbers[0]).\(numbers[1]).\(numbers[2]).\(numbers[3])"
        let port = numbers[4] * 256 + numbers[5]
        return (ip, port)
    }

    /// Opens the data connection socket and waits for it to actually be open
    /// (not just requested) before returning, so the server's accept() has
    /// something to accept as soon as RETR is sent.
    private func openDataConnectionLocked(host: String, port: Int) throws -> InputStream {
        var inStream: InputStream?
        Stream.getStreamsToHost(withName: host, port: port, inputStream: &inStream, outputStream: nil)
        guard let dataInput = inStream else { throw FTPError.dataConnectionFailed }
        dataInput.open()

        // Give the underlying socket a brief moment to complete its TCP
        // handshake before we send RETR — Stream.open() is asynchronous
        // under the hood, so without this the RETR could still race ahead
        // of the actual connect completing on some networks.
        let deadline = Date().addingTimeInterval(5.0)
        while dataInput.streamStatus == .opening && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard dataInput.streamStatus == .open || dataInput.streamStatus == .reading else {
            dataInput.close()
            throw FTPError.dataConnectionFailed
        }

        return dataInput
    }

    private func readDataLocked(from dataInput: InputStream, maxLength: Int64?, onChunk: (Data) -> Void) throws {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var totalRead: Int64 = 0

        while true {
            if let maxLength = maxLength, totalRead >= maxLength { break }
            if !dataInput.hasBytesAvailable && dataInput.streamStatus == .atEnd { break }

            var readLimit = buffer.count
            if let maxLength = maxLength {
                let remaining = maxLength - totalRead
                readLimit = min(readLimit, Int(remaining))
                if readLimit <= 0 { break }
            }

            let count = dataInput.read(&buffer, maxLength: readLimit)
            if count < 0 { throw FTPError.dataConnectionFailed }
            if count == 0 { break }

            onChunk(Data(buffer[0..<count]))
            totalRead += Int64(count)
        }
    }
}
