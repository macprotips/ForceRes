import Foundation

extension DisplaySnapshot {
    /// Encoder for fixture documents: ISO 8601 dates, pretty printed, sorted keys.
    public static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Decoder for fixture documents. Accepts `capturedAt` either as an ISO 8601 string or as the
    /// default `JSONEncoder` number (seconds since the reference date).
    public static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            let text = try container.decode(String.self)
            if let date = ISO8601DateFormatter().date(from: text) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "Unrecognised date: \(text)")
        }
        return decoder
    }

    /// Decodes a snapshot produced by `forceres-probe --json` or a test fixture.
    public static func decode(from data: Data) throws -> DisplaySnapshot {
        try makeJSONDecoder().decode(DisplaySnapshot.self, from: data)
    }

    /// Encodes this snapshot with `makeJSONEncoder()`.
    public func encodedJSON() throws -> Data {
        try Self.makeJSONEncoder().encode(self)
    }
}
