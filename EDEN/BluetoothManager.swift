import Foundation
import Combine
import CoreBluetooth

/// CoreBluetooth wrapper. This is the whole reason the native app exists:
/// iOS Safari has no Web Bluetooth, so a web app can never do any of this.
///
/// Writes are deliberately separated from reads and require an explicit call
/// from a button — matching the rule the Python side enforces, that nothing
/// which changes the physical world happens without a human pressing something.
@MainActor
final class BluetoothManager: NSObject, ObservableObject {

    struct Device: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
        var peripheral: CBPeripheral
        static func == (a: Device, b: Device) -> Bool { a.id == b.id }
    }

    struct Characteristic: Identifiable {
        let id: String
        let uuid: CBUUID
        let serviceUUID: CBUUID
        let properties: CBCharacteristicProperties
        var value: String?
        var readable: Bool { properties.contains(.read) }
        var writable: Bool {
            properties.contains(.write) || properties.contains(.writeWithoutResponse)
        }
        var notifying: Bool { properties.contains(.notify) }
    }

    @Published var state: CBManagerState = .unknown
    @Published var devices: [Device] = []
    @Published var scanning = false
    @Published var connected: Device?
    @Published var characteristics: [Characteristic] = []
    @Published var status: String = "Idle"

    private var central: CBCentralManager!
    private var target: CBPeripheral?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Human-readable reason the radio isn't usable, or nil when it is.
    var unavailableReason: String? {
        switch state {
        case .poweredOn:   return nil
        case .poweredOff:  return "Bluetooth is off. Turn it on in Settings."
        case .unauthorized:return "EDEN isn't allowed Bluetooth. Settings › EDEN › Bluetooth."
        case .unsupported: return "This device has no Bluetooth LE."
        case .resetting:   return "Bluetooth is restarting."
        default:           return "Starting Bluetooth…"
        }
    }

    func startScan() {
        guard state == .poweredOn else {
            status = unavailableReason ?? "Bluetooth unavailable"
            return
        }
        devices.removeAll()
        scanning = true
        status = "Scanning…"
        // allowDuplicates false: we only want each device once, and true
        // drains the battery noticeably.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            self.stopScan()
        }
    }

    func stopScan() {
        guard scanning else { return }
        central.stopScan()
        scanning = false
        status = devices.isEmpty ? "Nothing found" : "\(devices.count) devices"
    }

    func connect(_ device: Device) {
        stopScan()
        characteristics.removeAll()
        target = device.peripheral
        status = "Connecting to \(device.name)…"
        central.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        if let p = target { central.cancelPeripheralConnection(p) }
        connected = nil
        characteristics.removeAll()
        status = "Disconnected"
    }

    func read(_ characteristic: Characteristic) {
        guard let p = target,
              let cb = find(characteristic, on: p) else { return }
        p.readValue(for: cb)
    }

    /// Only ever called from an explicit button press with a confirmation.
    func write(_ characteristic: Characteristic, hex: String) {
        guard let p = target, let cb = find(characteristic, on: p) else { return }
        guard let data = Data(hexString: hex), !data.isEmpty else {
            status = "Not valid hex"
            return
        }
        let mode: CBCharacteristicWriteType =
            characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(data, for: cb, type: mode)
        status = "Wrote \(data.count) bytes"
    }

    func setNotify(_ characteristic: Characteristic, on: Bool) {
        guard let p = target, let cb = find(characteristic, on: p) else { return }
        p.setNotifyValue(on, for: cb)
    }

    private func find(_ c: Characteristic, on p: CBPeripheral) -> CBCharacteristic? {
        p.services?
            .first { $0.uuid == c.serviceUUID }?
            .characteristics?
            .first { $0.uuid == c.uuid }
    }
}

// MARK: - Central delegate

extension BluetoothManager: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            self.state = central.state
            self.status = self.unavailableReason ?? "Ready"
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? "(unnamed)"
        Task { @MainActor in
            guard !self.devices.contains(where: { $0.id == peripheral.identifier }) else { return }
            self.devices.append(Device(id: peripheral.identifier,
                                       name: name,
                                       rssi: RSSI.intValue,
                                       peripheral: peripheral))
            self.devices.sort { $0.rssi > $1.rssi }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices(nil)
        Task { @MainActor in
            self.connected = self.devices.first { $0.id == peripheral.identifier }
            self.status = "Connected. Discovering…"
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.status = "Couldn't connect. \(error?.localizedDescription ?? "")"
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.connected = nil
            self.characteristics.removeAll()
            self.status = "Disconnected"
        }
    }
}

// MARK: - Peripheral delegate

extension BluetoothManager: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        peripheral.services?.forEach {
            peripheral.discoverCharacteristics(nil, for: $0)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        let found = (service.characteristics ?? []).map {
            Characteristic(id: "\(service.uuid)|\($0.uuid)",
                           uuid: $0.uuid,
                           serviceUUID: service.uuid,
                           properties: $0.properties,
                           value: nil)
        }
        Task { @MainActor in
            self.characteristics.append(contentsOf: found)
            self.status = "\(self.characteristics.count) characteristics"
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        let data = characteristic.value ?? Data()
        // Show it several ways — a raw value means nothing without knowing
        // how the device encodes it.
        var rendered = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        if let text = String(data: data, encoding: .utf8),
           !text.isEmpty,
           text.allSatisfy({ !$0.isNewline && ($0.isASCII) }) {
            rendered += "  “\(text)”"
        }
        if data.count == 2 {
            rendered += "  int16le \(UInt16(data[0]) | UInt16(data[1]) << 8)"
        }
        let key = "\(characteristic.service?.uuid.uuidString ?? "")|\(characteristic.uuid.uuidString)"
        Task { @MainActor in
            if let i = self.characteristics.firstIndex(where: { $0.id == key }) {
                self.characteristics[i].value = rendered
            }
        }
    }
}

extension Data {
    init?(hexString: String) {
        let clean = hexString
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "0x", with: "")
        guard clean.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let b = UInt8(clean[index..<next], radix: 16) else { return nil }
            bytes.append(b)
            index = next
        }
        self.init(bytes)
    }
}
