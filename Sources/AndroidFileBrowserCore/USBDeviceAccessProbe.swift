import Foundation
import IOKit

struct USBDeviceAccessSnapshot: Equatable, Sendable {
    var vendorID: Int
    var productID: Int
    var vendorName: String
    var productName: String
    var exclusiveOwner: String?

    var displayName: String {
        if !productName.isEmpty { return productName }
        if !vendorName.isEmpty { return vendorName }
        return "Android device"
    }

    var isADBExclusiveOwner: Bool {
        exclusiveOwner?.localizedCaseInsensitiveContains("adb") == true
    }
}

struct USBInterfaceAccessSnapshot: Equatable, Sendable {
    var vendorID: Int
    var productID: Int
    var vendorName: String
    var productName: String
    var interfaceName: String
    var interfaceClass: Int
    var interfaceSubclass: Int
    var interfaceProtocol: Int
    var interfaceNumber: Int
    var exclusiveOwner: String?

    var displayName: String {
        if !productName.isEmpty { return productName }
        if !vendorName.isEmpty { return vendorName }
        return "Android device"
    }

    var isAndroidMTPInterface: Bool {
        vendorID != 0x05AC
            && interfaceClass == 6
            && interfaceProtocol == 1
            && interfaceName.localizedCaseInsensitiveContains("MTP")
    }

    var isOwnedByMacOSCameraService: Bool {
        exclusiveOwner?.localizedCaseInsensitiveContains("ptpcamerad") == true
    }
}

enum USBDeviceAccessProbe {
    static func firstADBExclusiveAndroidDevice() -> USBDeviceAccessSnapshot? {
        snapshots().first { snapshot in
            snapshot.isADBExclusiveOwner && snapshot.vendorID != 0x05AC
        }
    }

    static func firstAndroidMTPInterface() -> USBInterfaceAccessSnapshot? {
        interfaceSnapshots().first(where: \.isAndroidMTPInterface)
    }

    static func releaseMacOSCameraClients() {
        terminateProcesses(named: ["icdd", "ptpcamerad"], force: true)
    }

    static func withMacOSCameraClientsReleased<T>(during operation: () async -> T) async -> T {
        releaseMacOSCameraClients()
        let releaseTask = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { break }
                releaseMacOSCameraClients()
            }
        }

        let result = await operation()
        releaseTask.cancel()
        _ = await releaseTask.result
        return result
    }

    static func snapshots() -> [USBDeviceAccessSnapshot] {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return [] }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var result: [USBDeviceAccessSnapshot] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            result.append(USBDeviceAccessSnapshot(
                vendorID: intProperty(service, "idVendor") ?? -1,
                productID: intProperty(service, "idProduct") ?? -1,
                vendorName: stringProperty(service, "USB Vendor Name") ?? stringProperty(service, "kUSBVendorString") ?? "",
                productName: stringProperty(service, "USB Product Name") ?? stringProperty(service, "kUSBProductString") ?? "",
                exclusiveOwner: stringProperty(service, "UsbExclusiveOwner")
            ))
        }
        return result
    }

    static func interfaceSnapshots() -> [USBInterfaceAccessSnapshot] {
        guard let matching = IOServiceMatching("IOUSBHostInterface") else { return [] }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var result: [USBInterfaceAccessSnapshot] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            result.append(USBInterfaceAccessSnapshot(
                vendorID: intProperty(service, "idVendor") ?? -1,
                productID: intProperty(service, "idProduct") ?? -1,
                vendorName: stringProperty(service, "USB Vendor Name") ?? stringProperty(service, "kUSBVendorString") ?? "",
                productName: stringProperty(service, "USB Product Name") ?? stringProperty(service, "kUSBProductString") ?? "",
                interfaceName: stringProperty(service, "USB Interface Name") ?? stringProperty(service, "kUSBString") ?? "",
                interfaceClass: intProperty(service, "bInterfaceClass") ?? -1,
                interfaceSubclass: intProperty(service, "bInterfaceSubClass") ?? -1,
                interfaceProtocol: intProperty(service, "bInterfaceProtocol") ?? -1,
                interfaceNumber: intProperty(service, "bInterfaceNumber") ?? -1,
                exclusiveOwner: stringProperty(service, "UsbExclusiveOwner")
            ))
        }
        return result
    }

    private static func intProperty(_ service: io_service_t, _ key: String) -> Int? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue(),
            let number = value as? NSNumber
        else {
            return nil
        }
        return number.intValue
    }

    private static func stringProperty(_ service: io_service_t, _ key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        else {
            return nil
        }
        return value as? String
    }

    private static func terminateProcesses(named names: [String], force: Bool = false) {
        for name in names {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            process.arguments = force ? ["-9", name] : [name]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                continue
            }
        }
    }
}
