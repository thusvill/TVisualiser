import Foundation
import Network

final class RTSPServer {
    private var tcpListener: NWListener?
    private var udpAudioListener: NWListener?
    private var activeConnections: [NWConnection] = []
    
    var onAnnounceReceived: ((String) -> Void)?
    var onAudioDataReceived: ((Data) -> Void)?

    func stop() {
        tcpListener?.cancel()
        udpAudioListener?.cancel()
        activeConnections.forEach { $0.cancel() }
        activeConnections.removeAll()
        tcpListener = nil
        udpAudioListener = nil
    }
    
    func start(tcpPort: UInt16 = 5000, udpAudioPort: UInt16 = 6000) {
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
                }
            }
            
            udpAudioListener?.newConnectionHandler = { [weak self] connection in
                self?.handleUDPConnection(connection)
            }
            
            udpAudioListener?.start(queue: .main)
        } catch {
            print("UDP Audio Listener error: \(error)")
        }
    }
    
    private func handleNewTCPConnection(_ connection: NWConnection) {
        activeConnections.append(connection)
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
            
            if let requestString = String(data: data, encoding: .utf8) {
                DebugSettings.log("RTSP request:\n\(requestString)")
                self.processRTSPRequest(requestString, on: connection)
            } else {
                DebugSettings.log("Received non-UTF8 RTSP data: \(data.count) bytes")
            }
            
            if !isComplete && error == nil {
                self.receiveData(from: connection)
            }
        }
    }
    
    private func processRTSPRequest(_ request: String, on connection: NWConnection) {
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
        }
        
        DebugSettings.log("RTSP method: \(method) [CSeq: \(cSeq)]")
        
        switch method {
        case "OPTIONS":
            sendOptionsResponse(cSeq: cSeq, on: connection)
        case "ANNOUNCE":
            onAnnounceReceived?(request)
            sendOKResponse(cSeq: cSeq, on: connection)
        case "SETUP":
            sendSetupResponse(cSeq: cSeq, on: connection)
        case "RECORD", "SET_PARAMETER", "TEARDOWN", "FLUSH":
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
                       "Transport: RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;server_port=6000\r\n" +
                       "Session: 1\r\n" +
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
