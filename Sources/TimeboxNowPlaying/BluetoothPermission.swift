import Foundation
import CoreBluetooth

/// Triggers and tracks the macOS Bluetooth permission for this app.
///
/// IOBluetooth's `pairedDevices()` (used by the SPP transport for discovery)
/// silently returns nothing until the app has the "Bluetooth" privacy
/// permission, and it does not prompt on its own. Creating a `CBCentralManager`
/// does prompt the first time; once granted it covers IOBluetooth too.
final class BluetoothPermission: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager?

    /// Called on the main queue whenever authorization / power state changes.
    var onChange: (() -> Void)?

    var authorization: CBManagerAuthorization { CBCentralManager.authorization }

    var isReady: Bool { central?.state == .poweredOn }

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onChange?()
    }
}
