import CoreGraphics
import Foundation
import IOKit

/// Decides whether a display is backed by real hardware.
///
/// Physical displays appear in the IORegistry as `IOMobileFramebuffer` services whose
/// `DisplayAttributes.ProductAttributes` carry `LegacyManufacturerID` (equal to
/// `CGDisplayVendorNumber`) and `ProductID` (equal to `CGDisplayModelNumber`). A `CGVirtualDisplay`
/// has no such service. Measured on macOS 27 with the Odyssey G80SD (19501 / 57397). Built-in
/// panels count as physical without a registry match.
///
/// The same `DisplayAttributes` dictionary carries the panel's variable-refresh window
/// (`SupportsVariableRefreshRate`, `MinimumVariableRefreshRate`/`MaximumVariableRefreshRate` in
/// 16.16 fixed point; 48–240 Hz on the Odyssey), recorded per identity by the same scan.
///
/// Scope and caveats:
/// - Apple Silicon only: `IOMobileFramebuffer` is the Apple Silicon framebuffer class and the
///   scan was measured there alone. ForceRes ships arm64 only, so no other registry is consulted.
/// - The match is on vendor and product ids only. Anything that reports a real panel's ids —
///   a DisplayLink adapter, an AirPlay or Sidecar target, or a virtual display created with a
///   copied EDID — passes as physical; a physical panel whose framebuffer omits the ids fails.
///   ForceRes's own virtual displays use the `VirtualDisplayController.vendorID` "FR" identity and
///   never collide.
/// - The app hides every display that is not physical (it is never listed and never mirrored),
///   which is the safe failure: a misclassified display disappears from the panel silently
///   rather than becoming a mirror target, the case that crashes WindowServer.
struct PhysicalDisplayDetector: Sendable {
    /// Vendor and product ids of one framebuffer service.
    struct Identity: Hashable, Sendable {
        var vendor: UInt32
        var product: UInt32

        init(vendor: UInt32, product: UInt32) {
            self.vendor = vendor
            self.product = product
        }
    }

    /// Every (vendor, product) pair found in the registry.
    let identities: Set<Identity>
    /// Variable-refresh window in Hz for the identities whose framebuffer advertises one.
    let variableRefreshRanges: [Identity: ClosedRange<Double>]

    init(identities: Set<Identity>, variableRefreshRanges: [Identity: ClosedRange<Double>] = [:]) {
        self.identities = identities
        self.variableRefreshRanges = variableRefreshRanges
    }

    /// Divisor for IOKit's 16.16 fixed-point refresh rates.
    static let fixedPointScale = 65536.0

    /// Scans the IORegistry once. Callers cache the result for the duration of one operation.
    static func scan() -> PhysicalDisplayDetector {
        var identities = Set<Identity>()
        var ranges: [Identity: ClosedRange<Double>] = [:]
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebuffer"), &iterator)
        guard result == KERN_SUCCESS else { return PhysicalDisplayDetector(identities: []) }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let attributes = IORegistryEntryCreateCFProperty(service, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let product = attributes["ProductAttributes"] as? [String: Any],
                  let vendorNumber = product["LegacyManufacturerID"] as? NSNumber,
                  let productNumber = product["ProductID"] as? NSNumber else { continue }
            let identity = Identity(vendor: vendorNumber.uint32Value, product: productNumber.uint32Value)
            identities.insert(identity)
            if let range = variableRefreshRange(from: attributes) { ranges[identity] = range }
        }
        return PhysicalDisplayDetector(identities: identities, variableRefreshRanges: ranges)
    }

    /// Pure rule over one `DisplayAttributes` dictionary: the 16.16 window when
    /// `SupportsVariableRefreshRate` is set and both bounds are positive and ordered, else nil.
    static func variableRefreshRange(from attributes: [String: Any]) -> ClosedRange<Double>? {
        guard (attributes["SupportsVariableRefreshRate"] as? NSNumber)?.boolValue == true,
              let minimum = attributes["MinimumVariableRefreshRate"] as? NSNumber,
              let maximum = attributes["MaximumVariableRefreshRate"] as? NSNumber else { return nil }
        let lower = minimum.doubleValue / fixedPointScale
        let upper = maximum.doubleValue / fixedPointScale
        guard lower > 0, upper >= lower else { return nil }
        return lower...upper
    }

    /// The variable-refresh window recorded for the display's vendor and model, if any.
    func variableRefreshRange(vendor: UInt32, model: UInt32) -> ClosedRange<Double>? {
        variableRefreshRanges[Identity(vendor: vendor, product: model)]
    }

    /// `variableRefreshRange(vendor:model:)` with the ids CoreGraphics reports for `id`.
    func variableRefreshRange(_ id: CGDirectDisplayID) -> ClosedRange<Double>? {
        variableRefreshRange(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id))
    }

    /// Pure rule: built-in, or a registry match on both ids.
    func isPhysical(vendor: UInt32, model: UInt32, isBuiltIn: Bool) -> Bool {
        isBuiltIn || identities.contains(Identity(vendor: vendor, product: model))
    }

    /// `isPhysical(vendor:model:isBuiltIn:)` with the ids CoreGraphics reports for `id`.
    func isPhysical(_ id: CGDirectDisplayID) -> Bool {
        isPhysical(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                   isBuiltIn: CGDisplayIsBuiltin(id) != 0)
    }
}
