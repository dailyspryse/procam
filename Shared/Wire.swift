import Foundation

/// Wire format shared by the iPhone app and ProCam Studio on the Mac.
///
/// One TCP connection carries everything. Every message is
///
///     [u32 big-endian length of (type + payload)] [u8 type] [payload]
///
/// TCP instead of UDP because the same framing has to run over USB later
/// (usbmux only tunnels TCP), and on a LAN the sender's backpressure check
/// (see `StreamServer`) keeps latency flat without a retransmit-free protocol.
enum ProCamWire {
    static let bonjourType = "_procam._tcp"
    static let protocolVersion = 1
    static let defaultPort: UInt16 = 47800
    static let maxMessageSize = 32 * 1024 * 1024
}

enum MessageType: UInt8 {
    /// JSON `Hello`, both directions, first message on the connection.
    case hello = 1
    /// JSON `Command`, Mac → iPhone.
    case command = 2
    /// JSON `CameraStatus`, iPhone → Mac, ~5 Hz.
    case status = 3
    /// JSON `VideoFormat`, iPhone → Mac, before the first frame and on change.
    case videoFormat = 4
    /// Binary: [u64 BE pts µs][u8 flags][AVCC sample data], iPhone → Mac.
    case videoFrame = 5
    case ping = 6
    case pong = 7
}

struct WireMessage {
    let type: MessageType
    let payload: Data

    func encoded() -> Data {
        var out = Data(capacity: payload.count + 5)
        let length = UInt32(payload.count + 1).bigEndian
        withUnsafeBytes(of: length) { out.append(contentsOf: $0) }
        out.append(type.rawValue)
        out.append(payload)
        return out
    }

    static func json<T: Encodable>(_ type: MessageType, _ value: T) -> WireMessage {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return WireMessage(type: type, payload: data)
    }

    func decode<T: Decodable>(_: T.Type) -> T? {
        try? JSONDecoder().decode(T.self, from: payload)
    }
}

/// Incremental parser for the length-prefixed stream.
struct MessageParser {
    private var buffer = Data()

    enum ParseError: Error { case oversized(Int) }

    mutating func feed(_ chunk: Data) throws -> [WireMessage] {
        buffer.append(chunk)
        var messages: [WireMessage] = []
        var offset = buffer.startIndex

        while buffer.endIndex - offset >= 5 {
            let length = buffer[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard length >= 1, length <= ProCamWire.maxMessageSize else {
                throw ParseError.oversized(length)
            }
            guard buffer.endIndex - offset >= 4 + length else { break }
            let typeByte = buffer[offset + 4]
            let payload = buffer.subdata(in: offset + 5 ..< offset + 4 + length)
            offset += 4 + length
            // Unknown types are skipped, not fatal: a newer peer may send more.
            if let type = MessageType(rawValue: typeByte) {
                messages.append(WireMessage(type: type, payload: payload))
            }
        }

        if offset != buffer.startIndex {
            buffer = buffer.subdata(in: offset..<buffer.endIndex)
        }
        return messages
    }
}

struct Hello: Codable {
    var protocolVersion = ProCamWire.protocolVersion
    var role: String          // "iphone" | "studio"
    var name: String
}

enum VideoCodec: String, Codable, CaseIterable {
    case hevc, h264
}

struct VideoFormat: Codable, Equatable {
    var codec: VideoCodec
    var width: Int
    var height: Int
    /// HEVC: VPS, SPS, PPS. H.264: SPS, PPS. Raw NAL units without start codes.
    var parameterSets: [Data]
    var nalLengthSize: Int
}

/// Binary video frame payload helpers.
enum VideoFramePayload {
    static let keyframeFlag: UInt8 = 1

    static func encode(ptsUs: UInt64, keyframe: Bool, sample: Data) -> Data {
        var out = Data(capacity: sample.count + 9)
        withUnsafeBytes(of: ptsUs.bigEndian) { out.append(contentsOf: $0) }
        out.append(keyframe ? keyframeFlag : 0)
        out.append(sample)
        return out
    }

    static func decode(_ data: Data) -> (ptsUs: UInt64, keyframe: Bool, sample: Data)? {
        guard data.count > 9 else { return nil }
        let s = data.startIndex
        let pts = data[s..<s + 8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let flags = data[s + 8]
        return (pts, flags & keyframeFlag != 0, data.subdata(in: s + 9 ..< data.endIndex))
    }
}
