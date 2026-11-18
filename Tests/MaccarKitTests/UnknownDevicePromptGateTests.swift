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

    /// Field report, 2026-11-18 (after v1.5.0): the user pressed "Not Now" once, and from then
    /// on the iPad could never be registered — replugging did not bring the prompt back, so there
    /// was no path to registration at all short of restarting the app.
    ///
    /// The class comment promises "a dismissal survives for the session only, so a future replug
    /// may ask again". `offered` never expires and was checked before `dismissed`, so a single
    /// decline silenced the device for the whole session. `dismissed` existed but was never
    /// consulted, which is why the promise was not kept.
    @Test("Declining once must not silence the device for the rest of the session")
    func dismissalIsUndoneByReplug() {
        let coordinator = UnknownDeviceCoordinator()
        let vpad = device("VPad", id: "id-vpad")

        let first = coordinator.nextUnknownDevice(
            reachable: [vpad], registeredIdentifiers: [], currentTargetName: nil,
            attachedIdentifiers: ["id-vpad"])
        #expect(first != nil)
        coordinator.dismiss(identifier: "id-vpad")

        // Same session, cable pulled and plugged back in.
        coordinator.noteUSBReattach()
        let afterReplug = coordinator.nextUnknownDevice(
            reachable: [vpad], registeredIdentifiers: [], currentTargetName: nil,
            attachedIdentifiers: ["id-vpad"])
        #expect(afterReplug != nil,
                "a replug is a new decision point; one 'Not Now' must not be permanent")
    }

    @Test("An accepted registration needs no replug to stay registered")
    func registeredDeviceStaysSilentAcrossReplug() {
        let coordinator = UnknownDeviceCoordinator()
        let vpad = device("VPad", id: "id-vpad")

        _ = coordinator.nextUnknownDevice(
            reachable: [vpad], registeredIdentifiers: [], currentTargetName: nil,
            attachedIdentifiers: ["id-vpad"])
        coordinator.noteUSBReattach()

        // Now it is in the registry, which is what actually suppresses the prompt.
        let offered = coordinator.nextUnknownDevice(
            reachable: [vpad], registeredIdentifiers: ["id-vpad"], currentTargetName: nil,
            attachedIdentifiers: ["id-vpad"])
        #expect(offered == nil, "a registered iPad is never offered again")
    }

    @Test("A replug does not re-ask about a device that is still unregistered only by dismissal policy")
    func replugDoesNotSpam() {
        let coordinator = UnknownDeviceCoordinator()
        let vpad = device("VPad", id: "id-vpad")
        _ = coordinator.nextUnknownDevice(
            reachable: [vpad], registeredIdentifiers: [], currentTargetName: nil,
            attachedIdentifiers: ["id-vpad"])
        coordinator.dismiss(identifier: "id-vpad")
        coordinator.noteUSBReattach()

        // One prompt per attach event, not one per poll: the second call in the same attach
        // window must stay quiet.
        _ = coordinator.nextUnknownDevice(
            reachable: [vpad], registeredIdentifiers: [], currentTargetName: nil,
            attachedIdentifiers: ["id-vpad"])
        let second = coordinator.nextUnknownDevice(
            reachable: [vpad], registeredIdentifiers: [], currentTargetName: nil,
            attachedIdentifiers: ["id-vpad"])
        #expect(second == nil, "the prompt fires once per attach, not on every tick")
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
            attachedIdentifiers: ["id-wifi"]
        )

        #expect(offered?.identifier == "id-wifi",
                "documents the limitation: identity is not distinguishable by transport today")
    }
}
