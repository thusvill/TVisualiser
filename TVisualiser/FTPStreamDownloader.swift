import Foundation

actor FTPStreamDownloader {
    enum FTPError: Error {
        case connectionFailed
        case unexpectedResponse(String)
        case dataConnectionFailed
    }

    private let host: String
    private let port: Int
    private let username: String
    private let password: String

    init(host: String, port: Int, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username.isEmpty ? "anonymous" : username
        self.password = password
    }

    /// Downloads `remotePath` to `destinationURL`, calling `onProgress` after each
    /// chunk is written so the caller can decide when enough is buffered to start playback.
    func download(remotePath: String, to destinationURL: URL,
                  onProgress: @escaping (Int64) -> Void) async throws {

        let (inputStream, outputStream) = try openControlConnection()
        defer { inputStream.close(); outputStream.close() }

//        try readResponse(inputStream) // 220 welcome
        try sendCommand(outputStream, "USER \(username)")
        _ = try readResponse(inputStream) // 331
        try sendCommand(outputStream, "PASS \(password)")
        _ = try readResponse(inputStream) // 230
        try sendCommand(outputStream, "TYPE I")
        _ = try readResponse(inputStream) // 200

        try sendCommand(outputStream, "PASV")
        let pasvResponse = try readResponse(inputStream)
        let (dataHost, dataPort) = try parsePASV(pasvResponse)

        try sendCommand(outputStream, "REST 0")
        _ = try readResponse(inputStream) // 350 (tolerate 502 too, see note below)

        try sendCommand(outputStream, "RETR \(remotePath)")
        let retrResponse = try readResponse(inputStream) // 150
        guard retrResponse.hasPrefix("150") else {
            throw FTPError.unexpectedResponse(retrResponse)
        }

        // Open the data connection and stream it to disk
        try await streamDataConnection(host: dataHost, port: dataPort,
                                        to: destinationURL, onProgress: onProgress)

        // Drain final 226 Transfer complete (best-effort, ignore failures)
        _ = try? readResponse(inputStream)
        try? sendCommand(outputStream, "QUIT")
    }

    // MARK: - Control connection helpers

    private func openControlConnection() throws -> (InputStream, OutputStream) {
        var inStream: InputStream?
        var outStream: OutputStream?
        Stream.getStreamsToHost(withName: host, port: port, inputStream: &inStream, outputStream: &outStream)
        guard let input = inStream, let output = outStream else { throw FTPError.connectionFailed }
        input.open()
        output.open()
        return (input, output)
    }

    private func sendCommand(_ stream: OutputStream, _ command: String) throws {
        let line = command + "\r\n"
        guard let data = line.data(using: .utf8) else { return }
        _ = data.withUnsafeBytes { stream.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: data.count) }
        print("[FTP ->] \(command)")
    }

    private func readResponse(_ stream: InputStream) throws -> String {
        var buffer = [UInt8](repeating: 0, count: 1024)
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { throw FTPError.unexpectedResponse("empty response") }
        let response = String(bytes: buffer[0..<count], encoding: .utf8) ?? ""
        print("[FTP <-] \(response.trimmingCharacters(in: .whitespacesAndNewlines))")
        return response
    }

    private func parsePASV(_ response: String) throws -> (String, Int) {
        // 227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)
        guard let start = response.firstIndex(of: "("),
              let end = response.firstIndex(of: ")") else {
            throw FTPError.unexpectedResponse(response)
        }
        let numbers = response[response.index(after: start)..<end]
            .split(separator: ",")
            .compactMap { Int($0) }
        guard numbers.count == 6 else { throw FTPError.unexpectedResponse(response) }
        let ip = "\(numbers[0]).\(numbers[1]).\(numbers[2]).\(numbers[3])"
        let port = numbers[4] * 256 + numbers[5]
        return (ip, port)
    }

    // MARK: - Data connection streaming

    private func streamDataConnection(host: String, port: Int, to destinationURL: URL,
                                       onProgress: @escaping (Int64) -> Void) async throws {
        var inStream: InputStream?
        Stream.getStreamsToHost(withName: host, port: port, inputStream: &inStream, outputStream: nil)
        guard let dataInput = inStream else { throw FTPError.dataConnectionFailed }
        dataInput.open()
        defer { dataInput.close() }

        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destinationURL)
        defer { try? handle.close() }

        var totalWritten: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 65536)

        while dataInput.hasBytesAvailable {
            let count = dataInput.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw FTPError.dataConnectionFailed }
            if count == 0 { break }
            handle.write(Data(buffer[0..<count]))
            totalWritten += Int64(count)
            onProgress(totalWritten)
        }
    }
}
