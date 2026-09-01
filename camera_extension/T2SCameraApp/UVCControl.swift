import Foundation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib

/// Sends the T2S+'s control commands over USB.
///
/// This camera exposes no real controls; its firmware reuses the standard UVC
/// "Zoom, Absolute" control as a general-purpose register poke, and every
/// setting (raw mode, shutter/NUC trigger, emissivity, temperature range) is
/// written as a 16-bit value through it. Confirmed against the device's own
/// USB descriptor: Camera Terminal ID 1 on VideoControl interface 0, with the
/// Zoom Absolute bit (D9) set in bmControls.
///
/// The Python prototype shells out to the vendored `uvc-util` binary for this
/// because pyusb cannot claim the interface on macOS. In-process IOKit has no
/// such problem and keeps the app self-contained.
enum UVCControl {

    static let vendorID = 0x1514
    static let productID = 0x0001

    /// IOKit exposes these as C macros that don't import into Swift, so the
    /// UUIDs from IOUSBLib.h / IOCFPlugIn.h are rebuilt by hand here.
    private static func uuid(_ b: [UInt8]) -> CFUUID {
        CFUUIDGetConstantUUIDWithBytes(nil,
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
    }
    private static var plugInInterfaceID: CFUUID {
        uuid([0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
              0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F])
    }
    private static var deviceUserClientTypeID: CFUUID {
        uuid([0x9D, 0xC7, 0xB7, 0x80, 0x9E, 0xC0, 0x11, 0xD4,
              0xA5, 0x4F, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61])
    }
    private static var deviceInterfaceID: CFUUID {
        uuid([0x5C, 0x81, 0x87, 0xD0, 0x9E, 0xF3, 0x11, 0xD4,
              0x8B, 0x45, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61])
    }
    private static var interfaceUserClientTypeID: CFUUID {
        uuid([0x2D, 0x97, 0x86, 0xC6, 0x9E, 0xF3, 0x11, 0xD4,
              0xAD, 0x51, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61])
    }
    private static var interfaceInterfaceID: CFUUID {
        uuid([0x73, 0xC9, 0x7A, 0xE8, 0x9E, 0xF3, 0x11, 0xD4,
              0xB1, 0xD0, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61])
    }

    /// UVC spec: SET_CUR request, Zoom Absolute selector, Camera Terminal 1,
    /// VideoControl interface 0.
    private static let setCurRequest: UInt8 = 0x01
    private static let zoomAbsoluteSelector: UInt16 = 0x0B
    private static let cameraTerminalID: UInt16 = 0x01
    private static let videoControlInterface: UInt16 = 0x00

    // Command values, same as the Python side.
    static let cmdRawMode: UInt16 = 0x8004
    static let cmdShutterClose: UInt16 = 0x8000
    static let cmdSaveParameters: UInt16 = 0x80FF
    static let cmdRangeNormal: UInt16 = 0x8020
    static let cmdRangeHigh: UInt16 = 0x8021

    // Parameter positions within the camera's "user area" register block.
    static let posCorrection = 0 * 4
    static let posReflection = 1 * 4
    static let posAirTemp = 2 * 4
    static let posHumidity = 3 * 4
    static let posEmissivity = 4 * 4
    static let posDistance = 5 * 4

    enum UVCError: LocalizedError {
        case deviceNotFound
        case interfaceUnavailable(String)
        case requestFailed(kern_return_t)

        var errorDescription: String? {
            switch self {
            case .deviceNotFound:
                return "T2S+ not found on USB (expected \(String(format: "%04x:%04x", vendorID, productID)))."
            case .interfaceUnavailable(let why):
                return "Could not open the camera's USB control interface: \(why)"
            case .requestFailed(let kr):
                return "USB control request failed (kern_return \(String(format: "0x%08x", kr)))."
            }
        }
    }

    /// Opens the VideoControl interface, runs `body`, and always closes it.
    private static func withControlInterface<T>(
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface>?>) throws -> T
    ) throws -> T {
        guard let matching = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary? else {
            throw UVCError.interfaceUnavailable("no matching dictionary")
        }
        matching[kUSBVendorID] = vendorID
        matching[kUSBProductID] = productID

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            throw UVCError.deviceNotFound
        }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else { throw UVCError.deviceNotFound }
        defer { IOObjectRelease(service) }

        // Device plug-in -> IOUSBDeviceInterface
        var devPlugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(service, deviceUserClientTypeID,
                                                plugInInterfaceID, &devPlugIn, &score) == KERN_SUCCESS,
              let devPlugIn else {
            throw UVCError.interfaceUnavailable("device plug-in")
        }
        defer { _ = devPlugIn.pointee?.pointee.Release(devPlugIn) }

        var deviceInterface: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>?
        let devUUID = CFUUIDGetUUIDBytes(deviceInterfaceID)
        withUnsafeMutablePointer(to: &deviceInterface) { ptr in
            ptr.withMemoryRebound(to: Optional<LPVOID>.self, capacity: 1) { voidPtr in
                _ = devPlugIn.pointee?.pointee.QueryInterface(devPlugIn, devUUID, voidPtr)
            }
        }
        guard let deviceInterface else { throw UVCError.interfaceUnavailable("device interface") }
        defer { _ = deviceInterface.pointee?.pointee.Release(deviceInterface) }

        // Find the VideoControl interface (class 14 / subclass 1).
        var request = IOUSBFindInterfaceRequest(
            bInterfaceClass: 14, bInterfaceSubClass: 1,
            bInterfaceProtocol: UInt16(kIOUSBFindInterfaceDontCare),
            bAlternateSetting: UInt16(kIOUSBFindInterfaceDontCare))
        var interfaceIterator: io_iterator_t = 0
        guard deviceInterface.pointee?.pointee.CreateInterfaceIterator(
                deviceInterface, &request, &interfaceIterator) == KERN_SUCCESS else {
            throw UVCError.interfaceUnavailable("interface iterator")
        }
        defer { IOObjectRelease(interfaceIterator) }

        let usbInterface = IOIteratorNext(interfaceIterator)
        guard usbInterface != 0 else { throw UVCError.interfaceUnavailable("no VideoControl interface") }
        defer { IOObjectRelease(usbInterface) }

        var ifPlugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        guard IOCreatePlugInInterfaceForService(usbInterface, interfaceUserClientTypeID,
                                                plugInInterfaceID, &ifPlugIn, &score) == KERN_SUCCESS,
              let ifPlugIn else {
            throw UVCError.interfaceUnavailable("interface plug-in")
        }
        defer { _ = ifPlugIn.pointee?.pointee.Release(ifPlugIn) }

        var interface: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface>?>?
        let ifUUID = CFUUIDGetUUIDBytes(interfaceInterfaceID)
        withUnsafeMutablePointer(to: &interface) { ptr in
            ptr.withMemoryRebound(to: Optional<LPVOID>.self, capacity: 1) { voidPtr in
                _ = ifPlugIn.pointee?.pointee.QueryInterface(ifPlugIn, ifUUID, voidPtr)
            }
        }
        guard let interface else { throw UVCError.interfaceUnavailable("interface interface") }
        defer { _ = interface.pointee?.pointee.Release(interface) }

        // Note: no USBInterfaceOpen() here. The system's UVC driver owns the
        // interface for streaming; control requests still go through on the
        // default pipe, which is exactly how uvc-util does it.
        return try body(interface)
    }

    /// Writes one 16-bit value through the Zoom Absolute control.
    static func send(_ value: UInt16) throws {
        try withControlInterface { interface in
            var data = value.littleEndian
            let kr: kern_return_t = withUnsafeMutablePointer(to: &data) { dataPtr in
                var request = IOUSBDevRequest(
                    bmRequestType: 0x21,       // host->device | class | interface
                    bRequest: setCurRequest,
                    wValue: zoomAbsoluteSelector << 8,
                    wIndex: (cameraTerminalID << 8) | videoControlInterface,
                    wLength: 2,
                    pData: UnsafeMutableRawPointer(dataPtr),
                    wLenDone: 0)
                return interface.pointee?.pointee.ControlRequest(interface, 0, &request) ?? KERN_FAILURE
            }
            guard kr == KERN_SUCCESS else { throw UVCError.requestFailed(kr) }
        }
    }

    /// Writes a float parameter one byte at a time, the way this firmware
    /// expects: each byte carries its position in the high byte.
    static func sendFloat(position: Int, value: Float) throws {
        var bits = value.bitPattern.littleEndian
        let bytes = withUnsafeBytes(of: &bits) { Array($0) }
        for (i, byte) in bytes.enumerated() {
            try send(UInt16((position + i) << 8) | UInt16(byte))
        }
    }

    static func sendUInt16(position: Int, value: UInt16) throws {
        let v = value.littleEndian
        let bytes = withUnsafeBytes(of: v) { Array($0) }
        for (i, byte) in bytes.enumerated() {
            try send(UInt16((position + i) << 8) | UInt16(byte))
        }
    }

    /// Applies the radiometric parameters and commits them.
    ///
    /// saveParameters() is essential and easy to miss: without it the writes
    /// silently do not stick (emissivity stays at a bogus 0.02 and the
    /// temperature table comes out full of NaN). Also note the firmware only
    /// reliably accepts one such change per session.
    static func applyParameters(emissivity: Float, distanceMeters: UInt16,
                                airTemp: Float, reflectedTemp: Float) throws {
        try sendFloat(position: posEmissivity, value: emissivity)
        try sendUInt16(position: posDistance, value: distanceMeters)
        try sendFloat(position: posAirTemp, value: airTemp)
        try sendFloat(position: posReflection, value: reflectedTemp)
        try send(cmdSaveParameters)
    }
}
