import Foundation
import ForceResCore
import ForceResDisplay

/// Owns the one live `AppModel` shared by the SwiftUI scene and the app delegate.
@MainActor
enum AppEnvironment {
    static let model: AppModel = makeLiveModel()

    private static func makeLiveModel() -> AppModel {
        let registry = VirtualDisplayRegistry()
        let service = CoreGraphicsDisplayService(virtualDisplays: registry)
        let support = VirtualDisplayController.isSupported
        let controller: VirtualDisplayController? = support.0
            ? VirtualDisplayController(service: service, registry: registry)
            : nil
        if !support.0 {
            Log.virtual.notice("Virtual displays unsupported; missing \(support.missingSymbols.joined(separator: ", "))")
        }
        return AppModel(service: service, store: UserDefaultsPreferencesStore(), virtualProvider: controller)
    }
}
