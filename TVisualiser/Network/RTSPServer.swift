import Foundation
import Network

final class RTSPServer {
    private var tcpListener: NWListener?
    private var udpAudioListener: NWListener?
    private var activeConnections: [NWConnection] = []
    private var tcpBuffers: [ObjectIdentifier: Data] = [:]
    private var configuredUDPPort: UInt16 = 6000

    var onAnnounceReceived: ((String) -> Void)?
    var onMetadataReceived: ((Data) -> Void)?
    var onAudioDataReceived: ((Data) -> Void)?
    var onPlaybackCommandReceived: ((String) -> Void)?

    func stop() {
        tcpListener?.cancel()
        udpAudioListener?.cancel()
        activeConnections.forEach { $0.cancel() }
        activeConnections.removeAll()
        tcpBuffers.removeAll()
        tcpListener = nil
        udpAudioListener = nil
    }

    func start(tcpPort: UInt16 = 5000, udpAudioPort: UInt16 = 6000) {
        configuredUDPPort = udpAudioPort
        startTCPListener(port: tcpPort)
        startUDPListener(port: udpAudioPort)
    }

    // MARK: - TCP RTSP Control Listener
    private func startTCPListener(port: UInt16) {
        do {
            let parameters = NWParameters.tcp
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }

            tcpListener = try NWListener(using: parameters, on: nwPort)

            tcpListener?.stateUpdateHandler = { state in
                DebugSettings.log("RTSP TCP state: \(state)")
                if case .ready = state {
                    DebugSettings.log("RTSP control listener ready on TCP port \(port)")
                }
            }

            tcpListener?.newConnectionHandler = { [weak self] connection in
                self?.handleNewTCPConnection(connection)
            }

            tcpListener?.start(queue: .main)
        } catch {
            print("TCP Listener initialization error: \(error)")
        }
    }

    // MARK: - UDP Audio Stream Listener
    private func startUDPListener(port: UInt16) {
        do {
            let parameters = NWParameters.udp
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }

            udpAudioListener = try NWListener(using: parameters, on: nwPort)

            udpAudioListener?.stateUpdateHandler = { state in
                DebugSettings.log("RTP UDP state: \(state)")
                if case .ready = state {
                    DebugSettings.log("RTP UDP listener ready on port \(port)")
                } else if case .failed(let error) = state {
                    DebugSettings.log("RTP UDP listener FAILED on port \(port): \(error)")
                }
            }

            udpAudioListener?.newConnectionHandler = { [weak self] connection in
                DebugSettings.log("New UDP audio connection from \(connection.endpoint)")
                self?.handleUDPConnection(connection)
            }

            udpAudioListener?.start(queue: .main)
        } catch {
            print("UDP Audio Listener error: \(error)")
        }
    }

    private func handleNewTCPConnection(_ connection: NWConnection) {
        activeConnections.append(connection)
        tcpBuffers[ObjectIdentifier(connection)] = Data()
        connection.start(queue: .main)
        DebugSettings.log("Accepted AirPlay TCP control connection")
        receiveData(from: connection)
    }

    private func handleUDPConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveUDPData(from: connection)
    }

    private func receiveUDPData(from connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            if let error {
                DebugSettings.log("UDP receive error: \(error)")
            }
            if let data = data, !data.isEmpty {
                DebugSettings.log("Received RTP/UDP packet: \(data.count) bytes")
                self?.onAudioDataReceived?(data)
            }
            if !isComplete && error == nil {
                self?.receiveUDPData(from: connection)
            }
        }
    }

    private func receiveData(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let error {
                DebugSettings.log("RTSP receive error: \(error)")
            }
            guard let self = self, let data = data, !data.isEmpty else {
                if isComplete { connection.cancel() }
                return
            }

            let connectionID = ObjectIdentifier(connection)
            self.tcpBuffers[connectionID, default: Data()].append(data)
            self.processBufferedRequests(on: connection)

            if !isComplete && error == nil {
                self.receiveData(from: connection)
            }
        }
    }

    private func processBufferedRequests(on connection: NWConnection) {
        let connectionID = ObjectIdentifier(connection)
        while let buffer = tcpBuffers[connectionID],
              let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
            let header = buffer[..<headerRange.lowerBound]
            let headerText = String(decoding: header, as: UTF8.self)
            let contentLength = headerText.components(separatedBy: "\r\n").reduce(0) { result, line in
                guard line.lowercased().hasPrefix("content-length:") else { return result }
                return Int(line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
            }
            let bodyStart = headerRange.upperBound
            let requestLength = bodyStart + contentLength
            guard buffer.count >= requestLength else { return }
            let requestData = buffer[..<requestLength]
            tcpBuffers[connectionID] = Data(buffer[requestLength...])
            DebugSettings.log("RTSP request:\n\(headerText)")
            processRTSPRequest(headerText, rawData: Data(requestData), on: connection)
        }
    }

    private func processRTSPRequest(_ request: String, rawData: Data, on connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return }

        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return }

        let method = parts[0]
        var cSeq = "1"

        for line in lines {
            if line.lowercased().hasPrefix("cseq:") {
                cSeq = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? "1"
            }
            if line.lowercased().hasPrefix("transport:") {
                DebugSettings.log("Client Transport header: \(line)")
            }
        }

        DebugSettings.log("RTSP method: \(method) [CSeq: \(cSeq)]")

        switch method {
        case "OPTIONS":
            sendOptionsResponse(cSeq: cSeq, on: connection)
        case "ANNOUNCE":
            onAnnounceReceived?(String(decoding: rawData, as: UTF8.self))
            sendOKResponse(cSeq: cSeq, on: connection)
        case "SETUP":
            sendSetupResponse(cSeq: cSeq, on: connection)
        case "SET_PARAMETER":
            if let bodyStart = rawData.range(of: Data("\r\n\r\n".utf8)) {
                onMetadataReceived?(rawData[bodyStart.upperBound...])
            }
            sendOKResponse(cSeq: cSeq, on: connection)
        case "PLAY":
            onPlaybackCommandReceived?(method)
            sendOKResponse(cSeq: cSeq, on: connection)
        case "PAUSE":
            onPlaybackCommandReceived?(method)
            sendOKResponse(cSeq: cSeq, on: connection)
        case "RECORD", "TEARDOWN":
            onPlaybackCommandReceived?(method)
            sendOKResponse(cSeq: cSeq, on: connection)
        case "FLUSH":
            onPlaybackCommandReceived?(method)
            sendOKResponse(cSeq: cSeq, on: connection)
        default:
            sendOKResponse(cSeq: cSeq, on: connection)
        }
    }

    private func sendOptionsResponse(cSeq: String, on connection: NWConnection) {
        let response = "RTSP/1.0 200 OK\r\n" +
                       "CSeq: \(cSeq)\r\n" +
                       "Public: ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, SET_PARAMETER, GET_PARAMETER\r\n\r\n"
        send(string: response, on: connection)
    }

    private func sendSetupResponse(cSeq: String, on connection: NWConnection) {
        let response = "RTSP/1.0 200 OK\r\n" +
                       "CSeq: \(cSeq)\r\n" +
                       "Transport: RTP/AVP/UDP;unicast;mode=record;server_port=\(configuredUDPPort);control_port=\(configuredUDPPort + 1);timing_port=\(configuredUDPPort + 2)\r\n" +
                       "Session: 1\r\n" +
                       "Audio-Latency: 11025\r\n" +
                       "Audio-Jack-Status: connected; type=analog\r\n\r\n"
        send(string: response, on: connection)
    }

    private func sendOKResponse(cSeq: String, on connection: NWConnection) {
        let response = "RTSP/1.0 200 OK\r\n" +
                       "CSeq: \(cSeq)\r\n" +
                       "Audio-Jack-Status: connected; type=analog\r\n\r\n"
        send(string: response, on: connection)
    }

    private func send(string: String, on connection: NWConnection) {
        if let data = string.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed({ error in
                if let error = error {
                    DebugSettings.log("RTSP send error: \(error)")
                } else {
                    let firstLine = string.components(separatedBy: "\r\n").first ?? "unknown"
                    DebugSettings.log("RTSP response sent: \(firstLine)")
                }
            }))
        }
    }
}