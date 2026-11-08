import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The name this phone gives itself when pairing, shown by `hermes lekora devices`.
///
/// iOS only reveals the user-chosen device name to apps with a special entitlement,
/// so this uses the hardware model and OS version, e.g. "iPhone19,2 · iOS 27.0.1".
/// Together with the pairing time that is enough to tell phones and leftovers apart.
public enum DeviceName {
    @MainActor
    public static var current: String {
        #if canImport(UIKit)
        let system = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #else
        let system = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #endif
        return "\(modelIdentifier) · \(system)"
    }

    /// Hardware model such as "iPhone19,2" ("arm64" etc. on the simulator).
    public static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return machine.isEmpty ? "iPhone" : machine
    }
}
