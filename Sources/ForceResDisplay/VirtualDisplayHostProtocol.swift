import Foundation
import ForceResCore

/// The contract between `VirtualDisplayController` (the supervisor inside the app) and the
/// `forceres-vdhost` helper process that owns one virtual display for its lifetime.
///
/// Everything here is pure and Foundation-only so both sides, and the unit tests, share one
/// implementation of the argument list and of the single JSON line the helper prints.
///
/// Lifecycle, in order:
/// 1. The supervisor launches the helper with `Request.arguments`, keeping the helper's stdin pipe
///    open and reading its stdout.
/// 2. The helper creates the display, waits until CoreGraphics lists it, and prints exactly one
///    line: a `Reply.published` JSON object on success or `{"error":"…"}` on failure (exit 1).
/// 3. The helper stays alive until its stdin reaches EOF, it receives SIGTERM/SIGINT, or its
///    parent exits. Closing stdin (then SIGTERM, then SIGKILL) is how the supervisor destroys the
///    display; see `VirtualDisplayController` for why the display must be owned by a process.
public enum VirtualDisplayHostProtocol {
    /// File name of the helper executable (an auxiliary executable inside `ForceRes.app`).
    public static let executableName = "forceres-vdhost"

    /// `EX_USAGE`: the helper's exit status for a malformed command line.
    public static let usageExitStatus: Int32 = 64

    /// The helper's exit status when the display could not be created or published.
    public static let failureExitStatus: Int32 = 1

    /// Largest backing dimension the helper accepts. Generous, but rejects nonsense.
    public static let maximumDimension = 16_384

    // MARK: Request (command line)

    /// What the supervisor asks the helper to create. All sizes are backing pixels.
    public struct Request: Equatable, Sendable {
        /// Backing pixel width of the primary mode (for HiDPI this is twice the "looks like" width).
        public var width: Int
        /// Backing pixel height of the primary mode.
        public var height: Int
        /// When `true` the helper adds a `width/2 x height/2` mode and sets `hiDPI = 1`, which makes
        /// macOS default to the 2x "looks like" mode (docs/RESEARCH.md, addendum).
        public var hiDPI: Bool
        /// Display name shown in System Settings.
        public var name: String
        /// EDID vendor id.
        public var vendorID: UInt32
        /// EDID product id.
        public var productID: UInt32
        /// EDID serial number.
        public var serialNumber: UInt32
        /// Physical width in millimetres (drives the dpi macOS assumes).
        public var millimetersWidth: Int
        /// Physical height in millimetres.
        public var millimetersHeight: Int

        public init(width: Int, height: Int, hiDPI: Bool, name: String, vendorID: UInt32, productID: UInt32,
                    serialNumber: UInt32, millimetersWidth: Int, millimetersHeight: Int) {
            self.width = width
            self.height = height
            self.hiDPI = hiDPI
            self.name = name
            self.vendorID = vendorID
            self.productID = productID
            self.serialNumber = serialNumber
            self.millimetersWidth = millimetersWidth
            self.millimetersHeight = millimetersHeight
        }

        /// Backing size of the primary mode.
        public var pixelSize: PixelSize { PixelSize(width: width, height: height) }

        /// Size of the additional "looks like" mode for HiDPI requests; nil for 1x.
        public var looksLikeSize: PixelSize? {
            hiDPI ? PixelSize(width: width / 2, height: height / 2) : nil
        }

        /// The size the display will report in points once online.
        public var expectedPointSize: PixelSize { looksLikeSize ?? pixelSize }

        /// The command-line arguments (without the executable path) that `parse` accepts back.
        public var arguments: [String] {
            var args = ["--width", String(width), "--height", String(height),
                        "--name", name,
                        "--vendor", String(vendorID), "--product", String(productID),
                        "--serial", String(serialNumber),
                        "--mm", "\(millimetersWidth)x\(millimetersHeight)"]
            if hiDPI { args.append("--hidpi") }
            return args
        }

        /// Parses the helper's command line (without the executable path).
        /// - Throws: `ArgumentError` describing the first problem found.
        public static func parse(arguments: [String]) throws(ArgumentError) -> Request {
            var values: [String: String] = [:]
            var hiDPI = false
            var index = 0
            while index < arguments.count {
                let flag = arguments[index]
                index += 1
                switch flag {
                case "--hidpi":
                    hiDPI = true
                case "--width", "--height", "--name", "--vendor", "--product", "--serial", "--mm":
                    guard index < arguments.count else { throw .missingValue(flag: flag) }
                    guard values[flag] == nil else { throw .duplicateFlag(flag: flag) }
                    values[flag] = arguments[index]
                    index += 1
                default:
                    throw .unknownFlag(flag: flag)
                }
            }

            func required(_ flag: String) throws(ArgumentError) -> String {
                guard let value = values[flag] else { throw .missingFlag(flag: flag) }
                return value
            }
            func dimension(_ flag: String) throws(ArgumentError) -> Int {
                let raw = try required(flag)
                guard let value = Int(raw), (1...maximumDimension).contains(value) else {
                    throw .invalidValue(flag: flag, value: raw)
                }
                return value
            }
            func uint32(_ flag: String) throws(ArgumentError) -> UInt32 {
                let raw = try required(flag)
                guard let value = UInt32(raw) else { throw .invalidValue(flag: flag, value: raw) }
                return value
            }

            let width = try dimension("--width")
            let height = try dimension("--height")
            if hiDPI, width % 2 != 0 || height % 2 != 0 {
                throw .invalidValue(flag: "--hidpi", value: "\(width)x\(height) is not divisible by 2")
            }
            let name = try required("--name")
            guard !name.isEmpty else { throw .invalidValue(flag: "--name", value: name) }
            let millimeters = try required("--mm")
            let mmParts = millimeters.split(separator: "x", omittingEmptySubsequences: false)
            guard mmParts.count == 2, let mmWidth = Int(mmParts[0]), let mmHeight = Int(mmParts[1]),
                  mmWidth > 0, mmHeight > 0 else {
                throw .invalidValue(flag: "--mm", value: millimeters)
            }
            return Request(width: width, height: height, hiDPI: hiDPI, name: name,
                           vendorID: try uint32("--vendor"), productID: try uint32("--product"),
                           serialNumber: try uint32("--serial"),
                           millimetersWidth: mmWidth, millimetersHeight: mmHeight)
        }
    }

    /// Why a helper command line was rejected.
    public enum ArgumentError: Error, Equatable, Sendable, LocalizedError {
        case unknownFlag(flag: String)
        case missingValue(flag: String)
        case duplicateFlag(flag: String)
        case missingFlag(flag: String)
        case invalidValue(flag: String, value: String)

        public var errorDescription: String? {
            switch self {
            case .unknownFlag(let flag): "unknown option \(flag)"
            case .missingValue(let flag): "\(flag) needs a value"
            case .duplicateFlag(let flag): "\(flag) given more than once"
            case .missingFlag(let flag): "\(flag) is required"
            case .invalidValue(let flag, let value): "invalid value for \(flag): \(value)"
            }
        }
    }

    /// One-line usage text for the helper.
    public static let usage = """
        usage: \(executableName) --width W --height H --name NAME --vendor N --product N --serial N --mm WxH [--hidpi]
        """

    // MARK: Reply (stdout)

    /// What the helper reports once its display is online. Geometry is measured in the helper
    /// process with `CGDisplayBounds` (points) and `CGDisplayPixelsWide/High` (pixels).
    public struct Published: Codable, Equatable, Sendable {
        public var displayID: UInt32
        public var uuid: String
        public var pointsWidth: Int
        public var pointsHeight: Int
        public var pixelsWidth: Int
        public var pixelsHeight: Int

        public init(displayID: UInt32, uuid: String, pointsWidth: Int, pointsHeight: Int,
                    pixelsWidth: Int, pixelsHeight: Int) {
            self.displayID = displayID
            self.uuid = uuid
            self.pointsWidth = pointsWidth
            self.pointsHeight = pointsHeight
            self.pixelsWidth = pixelsWidth
            self.pixelsHeight = pixelsHeight
        }

        public var pointSize: PixelSize { PixelSize(width: pointsWidth, height: pointsHeight) }
        public var pixelSize: PixelSize { PixelSize(width: pixelsWidth, height: pixelsHeight) }
    }

    /// The single line the helper writes to stdout.
    public enum Reply: Equatable, Sendable {
        case published(Published)
        case failed(String)

        /// Encodes the reply as one line of JSON (no embedded newlines, trailing "\n" included).
        public var line: String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let encoded: Data?
            switch self {
            case .published(let published): encoded = try? encoder.encode(published)
            case .failed(let message): encoded = try? encoder.encode(Failure(error: message))
            }
            let data = encoded ?? Data(#"{"error":"encoding failed"}"#.utf8)
            return String(decoding: data, as: UTF8.self) + "\n"
        }

        /// Decodes one line printed by the helper. Unknown fields are ignored.
        /// - Throws: `CodecError` when the line is not a well-formed reply.
        public static func decode(line: String) throws(CodecError) -> Reply {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw .empty }
            let data = Data(trimmed.utf8)
            let decoder = JSONDecoder()
            if let failure = try? decoder.decode(Failure.self, from: data) { return .failed(failure.error) }
            let published: Published
            do {
                published = try decoder.decode(Published.self, from: data)
            } catch let error as DecodingError {
                throw CodecError(error, line: trimmed)
            } catch {
                throw .notJSONObject(trimmed)
            }
            guard !published.uuid.isEmpty else { throw .missingField("uuid") }
            return .published(published)
        }
    }

    /// The `{"error": "…"}` form of a reply.
    private struct Failure: Codable {
        var error: String
    }

    /// Why a helper reply line could not be decoded.
    public enum CodecError: Error, Equatable, Sendable, LocalizedError {
        case empty
        case notJSONObject(String)
        case missingField(String)

        /// Maps a `DecodingError` onto the closest codec error, naming the field at fault.
        init(_ error: DecodingError, line: String) {
            switch error {
            case .keyNotFound(let key, _): self = .missingField(key.stringValue)
            case .typeMismatch(_, let context), .dataCorrupted(let context):
                self = context.codingPath.last.map { .missingField($0.stringValue) } ?? .notJSONObject(line)
            case .valueNotFound(_, let context):
                self = context.codingPath.last.map { .missingField($0.stringValue) } ?? .notJSONObject(line)
            @unknown default: self = .notJSONObject(line)
            }
        }

        public var errorDescription: String? {
            switch self {
            case .empty: "the helper printed an empty line"
            case .notJSONObject(let text): "the helper printed something that is not a JSON object: \(text)"
            case .missingField(let key): "the helper reply lacks a valid \"\(key)\" field"
            }
        }
    }

    // MARK: Helper location

    /// Resolves the helper executable from candidate locations, in order:
    /// 1. `auxiliaryExecutableURL` (`Bundle.main.url(forAuxiliaryExecutable:)`, i.e. `Contents/MacOS`
    ///    of the app bundle);
    /// 2. a file named `forceres-vdhost` next to `executableURL` (covers `swift run` and
    ///    `.build/debug`).
    /// Only candidates that `isExecutableFile` accepts are returned.
    static func resolveHelperURL(auxiliaryExecutableURL: URL?, executableURL: URL?,
                                 isExecutableFile: (URL) -> Bool) -> URL? {
        var candidates: [URL] = []
        if let auxiliaryExecutableURL { candidates.append(auxiliaryExecutableURL) }
        if let executableURL {
            candidates.append(executableURL.deletingLastPathComponent().appendingPathComponent(executableName))
        }
        return candidates.first(where: isExecutableFile)
    }

    /// `resolveHelperURL` against the running process (`Bundle.main`) and the file system.
    static func locateHelper(bundle: Bundle = .main, fileManager: FileManager = .default) -> URL? {
        resolveHelperURL(auxiliaryExecutableURL: bundle.url(forAuxiliaryExecutable: executableName),
                         executableURL: bundle.executableURL,
                         isExecutableFile: { fileManager.isExecutableFile(atPath: $0.path) })
    }
}
