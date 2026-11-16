import Foundation
import IOKit
import Testing
@testable import MaccarKit

/// D6a regression guard.
///
/// The monitor once built its `IOServiceMatching` dictionary with an `"idVendor"` key.
/// On this platform that filter matched **zero** `IOUSBHostDevice` services even with an
/// iPad attached, so `kIOFirstMatchNotification` never delivered an attach and the
/// replug path that re-arms auto-connect was dead code. The tests below pin the two
/// properties that make the bug impossible to reintroduce silently.
@Suite("USB Attach Monitor Tests", .serialized)
struct USBDeviceAttachMonitorTests {
    @Test("Matching dictionary carries no property filter that could reject every service")
    func matchingDictionaryHasNoPropertyFilters() {
        guard let matching = USBDeviceAttachMonitor.matchingDictionary() else {
            Issue.record("matchingDictionary() returned nil")
            return
        }

        // `IOServiceMatching` returns a dictionary whose only entry is `IOProviderClass`.
        // Any additional key is a property match, and a property match that does not
        // apply on this platform silently yields zero services.
        let propertyFilters = matching.allKeys.filter { ($0 as? String) != "IOProviderClass" }
        #expect(propertyFilters.isEmpty, "Unexpected property filters: \(propertyFilters)")
    }

    @Test("Matching dictionary targets IOUSBHostDevice itself")
    func matchingDictionaryTargetsUSBHostDevice() {
        let matching = USBDeviceAttachMonitor.matchingDictionary()
        #expect((matching?["IOProviderClass"] as? String) == "IOUSBHostDevice")
    }

    @Test("A broad IOUSBHostDevice query matches at least one live service")
    func broadQueryMatchesLiveServices() {
        // Guards the opposite failure mode: if the dictionary ever becomes too narrow again,
        // `IOServiceGetMatchingServices` returns nothing and the attach callback can never fire.
        guard let matching = USBDeviceAttachMonitor.matchingDictionary() else {
            Issue.record("matchingDictionary() returned nil")
            return
        }
        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard status == KERN_SUCCESS else {
            Issue.record("IOServiceGetMatchingServices failed with status \(status)")
            return
        }
        defer { IOObjectRelease(iterator) }

        var count = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
            count += 1
        }
        #expect(count > 0, "A broad IOUSBHostDevice match must return live services")
    }
}
