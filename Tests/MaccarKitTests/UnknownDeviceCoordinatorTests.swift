import Foundation
import Testing
@testable import MaccarKit

/// Wave 4 / DD-4: the unknown-iPad prompt must be rare and never repeat for the same device.
///
/// The prompt itself cannot raise an Apple popup (no `connect()` is involved), but asking on every
/// 5 s poll would be its own kind of hostile, and asking about a device the user already configured
/// would be noise.
@Suite("Unknown Device Coordinator Tests", .serialized)
struct UnknownDeviceCoordinatorTests {
    private func device(_ id: String, name: String = "VPad", model: String = "iPad16,1") -> SidecarDevice {
        SidecarDevice(identifier: id, name: name, model: model)
    }

    @Test("A registered device is never offered")
    func registeredDeviceIsNotOffered() {
        let coordinator = UnknownDeviceCoordinator()
        let offered = coordinator.nextUnknownDevice(
            reachable: [device("A")],
            registeredIdentifiers: ["A"]
        )
        #expect(offered == nil)
    }

    @Test("An unregistered device is offered once and not again in the same session")
    func offersOncePerSession() {
        let coordinator = UnknownDeviceCoordinator()
        let newDevice = device("B", name: "NewPad")

        #expect(coordinator.nextUnknownDevice(reachable: [newDevice], registeredIdentifiers: ["A"]) == newDevice)
        // The same device on the next poll must not re-prompt.
        #expect(coordinator.nextUnknownDevice(reachable: [newDevice], registeredIdentifiers: ["A"]) == nil)
    }

    @Test("Dismissing one device still allows a different new device to be offered")
    func dismissalIsPerIdentifier() {
        let coordinator = UnknownDeviceCoordinator()
        let first = device("B", name: "FirstPad")
        let second = device("C", name: "SecondPad")

        #expect(coordinator.nextUnknownDevice(reachable: [first], registeredIdentifiers: []) == first)
        coordinator.dismiss(identifier: first.identifier)

        #expect(coordinator.isDismissed(identifier: "B"))
        #expect(!coordinator.isDismissed(identifier: "C"))
        // A genuinely different iPad is still worth asking about.
        #expect(coordinator.nextUnknownDevice(reachable: [second], registeredIdentifiers: []) == second)
    }

    @Test("A dismissal does not persist across sessions, so a later replug can ask again")
    func dismissalResetsWithSession() {
        let coordinator = UnknownDeviceCoordinator()
        let newDevice = device("B", name: "NewPad")
        _ = coordinator.nextUnknownDevice(reachable: [newDevice], registeredIdentifiers: [])
        coordinator.dismiss(identifier: newDevice.identifier)

        coordinator.resetSession()
        #expect(coordinator.nextUnknownDevice(reachable: [newDevice], registeredIdentifiers: []) == newDevice)
    }

    @Test("The device the user already typed by name is not offered")
    func typedTargetNameIsNotOffered() {
        let coordinator = UnknownDeviceCoordinator()
        // Pre-registry state: identity is a typed name, not an identifier.
        let offered = coordinator.nextUnknownDevice(
            reachable: [device("B", name: "MyiPad")],
            registeredIdentifiers: [],
            currentTargetName: "MyiPad"
        )
        #expect(offered == nil, "prompting to register the device they already configured is noise")
    }

    @Test("Name matching ignores case and surrounding whitespace")
    func typedTargetNameMatchingIsForgiving() {
        let coordinator = UnknownDeviceCoordinator()
        let offered = coordinator.nextUnknownDevice(
            reachable: [device("B", name: "MyiPad")],
            registeredIdentifiers: [],
            currentTargetName: "  myipad  "
        )
        #expect(offered == nil)
    }

    @Test("Two new iPads produce two prompts, one at a time")
    func twoNewDevicesProduceTwoPrompts() {
        let coordinator = UnknownDeviceCoordinator()
        let first = device("B", name: "FirstPad")
        let second = device("C", name: "SecondPad")

        let offeredOne = coordinator.nextUnknownDevice(reachable: [first, second], registeredIdentifiers: [])
        let offeredTwo = coordinator.nextUnknownDevice(reachable: [first, second], registeredIdentifiers: [])
        let offeredThree = coordinator.nextUnknownDevice(reachable: [first, second], registeredIdentifiers: [])

        #expect(offeredOne == first)
        #expect(offeredTwo == second)
        #expect(offeredThree == nil, "each new device is offered exactly once")
    }

    @Test("A forgotten device becomes unknown again and is offered once more")
    func forgottenDeviceIsOfferedAgainAfterReRegistration() {
        let coordinator = UnknownDeviceCoordinator()
        let known = device("B", name: "NewPad")

        // Registered: never offered.
        #expect(coordinator.nextUnknownDevice(reachable: [known], registeredIdentifiers: ["B"]) == nil)

        // The user forgot it: it is genuinely unknown now, which is the whole point of Forget.
        #expect(coordinator.nextUnknownDevice(reachable: [known], registeredIdentifiers: []) == known)
    }

    @Test("An explicit session reset lets a dismissed device be offered again")
    func resetAllowsRePrompting() {
        let coordinator = UnknownDeviceCoordinator()
        let newDevice = device("B", name: "NewPad")
        _ = coordinator.nextUnknownDevice(reachable: [newDevice], registeredIdentifiers: [])
        coordinator.dismiss(identifier: newDevice.identifier)
        #expect(coordinator.nextUnknownDevice(reachable: [newDevice], registeredIdentifiers: []) == nil)

        // A user who forgets the device should be offered it again rather than being stuck with a
        // session-scoped dismissal that no longer reflects their intent.
        coordinator.clearDismissal(identifier: newDevice.identifier)
        #expect(coordinator.nextUnknownDevice(reachable: [newDevice], registeredIdentifiers: []) == newDevice)
    }
}
