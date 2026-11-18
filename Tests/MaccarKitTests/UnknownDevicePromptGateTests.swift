import Foundation
import Testing
@testable import MaccarKit

/// Regression guard for the "New iPad detected" prompt firing with no iPad attached.
///
/// Field report, 2026-11-18 12:08: the Mac had no iPad on the cable. Sidecar listed
/// `VPad` because it was paired over Wi-Fi, so the coordinator offered to register it.
/// The user pressed Register, and from then on the app logged
/// `Skipping connect for 'VPad': no iPad is attached over USB` every five seconds — a
/// device registered that can never connect, and a prompt shown for hardware that was
/// not there.
///
/// The fix has two halves, both guarded here:
///   1. The coordinator only offers devices the caller says are physically attached.
///   2. The prompt itself refuses to run when nothing is attached.
@Suite("Unknown Device Prompt Gate Tests")
struct UnknownDevicePromptGateTests {

    private func device(_ name: String, id: String) -> SidecarDevice {
        SidecarDevice(identifier: id, name: name, model: "iPad")
    }

    @Test("A paired but unplugged iPad is never offered for registration")
    func unpluggedPairedDeviceIsNotOffered() {
        let coordinator = UnknownDeviceCoordinator()

        // `reachable` is what Sidecar reports — paired devices, not attached ones.
        // Passing an empty `attachedIdentifiers` is the "cable is out" case.
        let offered = coordinator.nextUnknownDevice(
            reachable: [device("VPad", id: "id-vpad")],
            registeredIdentifiers: [],
            currentTargetName: nil,
            attachedIdentifiers: []
        )

        #expect(offered == nil,
                "a device that is not plugged in must never trigger a registration prompt")
    }

    @Test("An attached, unregistered iPad is offered exactly once")
    func attachedUnknownDeviceIsOfferedOnce() {
        let coordinator = UnknownDeviceCoordinator()
        let vpad = device("VPad", id: "id-vpad")

        let first = coordinator.nextUnknownDevice(
            reachable: [vpad],
            registeredIdentifiers: [],
            currentTargetName: nil,
            attachedIdentifiers: ["id-vpad"]
        )
        #expect(first?.identifier == "id-vpad")

        // Second call in the same session must stay silent: one attach, one prompt.
        let second = coordinator.nextUnknownDevice(
            reachable: [vpad],
            registeredIdentifiers: [],
            currentTargetName: nil,
            attachedIdentifiers: ["id-vpad"]
        )
        #expect(second == nil, "one attach event must not produce two prompts")
    }

    @Test("A registered iPad is never offered again")
    func registeredDeviceIsNotOffered() {
        let coordinator = UnknownDeviceCoordinator()

        let offered = coordinator.nextUnknownDevice(
            reachable: [device("VPad", id: "id-vpad")],
            registeredIdentifiers: ["id-vpad"],
            currentTargetName: nil,
            attachedIdentifiers: ["id-vpad"]
        )

        #expect(offered == nil, "an iPad already in the registry must not be offered again")
    }

    @Test("Only the attached device is offered when Sidecar lists several")
    func onlyAttachedDeviceIsOfferedAmongMany() {
        let coordinator = UnknownDeviceCoordinator()

        let offered = coordinator.nextUnknownDevice(
            reachable: [device("VPad", id: "id-wifi"), device("Studio iPad", id: "id-usb")],
            registeredIdentifiers: [],
            currentTargetName: nil,
            attachedIdentifiers: ["id-usb"]
        )

        #expect(offered?.identifier == "id-usb",
                "the offer must come from the attached device, not the Wi-Fi one listed first")
    }

    @Test("Nothing attached means no prompt, even with devices reachable")
    func nothingAttachedMeansNoPrompt() {
        let coordinator = UnknownDeviceCoordinator()

        let offered = coordinator.nextUnknownDevice(
            reachable: [device("A", id: "a"), device("B", id: "b")],
            registeredIdentifiers: [],
            currentTargetName: nil,
            attachedIdentifiers: []
        )

        #expect(offered == nil)
    }

    /// Documents a real limitation rather than leaving it to be rediscovered as a bug.
    ///
    /// `SidecarCoreIsIPadAttached()` reports only whether *some* iPad is on the cable; Sidecar
    /// exposes no per-device transport, so the app cannot tell which reachable identity is the
    /// attached one. The presence gate stops the "nothing plugged in" prompt, which is the case
    /// users hit. With one cable attached and a second iPad merely paired, the offer can still
    /// name the paired one — accepted, because the alternative is claiming a transport filter
    /// that does not exist. If Sidecar ever reports transport per device, this test should start
    /// failing so the behaviour gets tightened deliberately.
    @Test("Accepted limitation: with a cable in, a paired Wi-Fi device can still be offered")
    func documentedLimitationWhenOneCableAndOnePaired() {
        let coordinator = UnknownDeviceCoordinator()

        let offered = coordinator.nextUnknownDevice(
            reachable: [device("VPad", id: "id-wifi")],
            registeredIdentifiers: [],
            currentTargetName: nil,
            // The caller can only say "these are what Sidecar listed"; it has no per-device
            // transport to narrow with.
            attachedIdentifiers: ["id-wifi"]
        )

        #expect(offered?.identifier == "id-wifi",
                "documents the limitation: identity is not distinguishable by transport today")
    }
}
