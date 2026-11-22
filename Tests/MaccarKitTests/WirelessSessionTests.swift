import Foundation
import Testing
@testable import MaccarKit

/// Wi-Fi is a session permission, not a saved setting. These tests pin the two properties that
/// make it safe: it starts off, and nothing persists it.
@Suite("Wireless Session Tests")
struct WirelessSessionTests {

    @Test("A fresh session is off, so launch is always wired")
    func startsDisabled() {
        let session = WirelessSession()
        #expect(session.isEnabled == false)
        #expect(session.prefersWired)
    }

    @Test("Enabling switches the connect argument to transport-agnostic")
    func enablePrefersWireless() {
        let session = WirelessSession()
        session.enable()
        #expect(session.isEnabled)
        #expect(session.prefersWired == false,
                "while enabled, connect must be allowed to choose Wi-Fi")
    }

    @Test("Disabling returns to wired-only")
    func disableRestoresWired() {
        let session = WirelessSession()
        session.enable()
        session.disable()
        #expect(session.isEnabled == false)
        #expect(session.prefersWired)
    }

    @Test("Enabling twice is idempotent")
    func enableIsIdempotent() {
        let session = WirelessSession()
        session.enable()
        session.enable()
        #expect(session.isEnabled)
    }

    @Test("A new session never inherits the previous one's permission")
    func doesNotPersist() {
        // The requirement in the user's words: "setiap aplikasi maccar baru nyala, otomatis
        // wifi mode set ke off". A fresh instance is what a relaunch gets, so this is the
        // property that must hold even if someone later wires this type to UserDefaults.
        let first = WirelessSession()
        first.enable()

        let second = WirelessSession()
        #expect(second.isEnabled == false,
                "a relaunch must never resume an armed session — the permission is per-session")
    }

    @Test("prefersWired is exactly the inverse of isEnabled")
    func prefersWiredTracksState() {
        let session = WirelessSession()
        for enabled in [true, false, true, false] {
            if enabled { session.enable() } else { session.disable() }
            #expect(session.prefersWired == !session.isEnabled)
        }
    }
}
