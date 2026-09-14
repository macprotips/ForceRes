import ForceResCore
import ForceResDisplay

/// The slice of `VirtualDisplayController` the app model needs, as a protocol so tests can
/// substitute a fake that never touches CoreGraphics.
protocol VirtualDisplayProviding: Sendable {
    /// Creates a virtual display and returns its UUID string. See `VirtualDisplayController.create`.
    @discardableResult
    func create(name: String, pixelSize: PixelSize, hiDPI: Bool, physicalDisplayID: String) throws -> String
    /// Releases one virtual display (dissolving mirrors that target it). Unknown ids are ignored.
    func destroy(displayID: String)
    /// Releases every virtual display owned by this provider.
    func destroyAll()
    /// UUIDs of the virtual displays currently alive.
    var activeDisplayIDs: [String] { get }
}

extension VirtualDisplayController: VirtualDisplayProviding {}
