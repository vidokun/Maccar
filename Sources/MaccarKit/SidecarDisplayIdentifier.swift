import Foundation
import CoreGraphics

/// Identifies which online display is the Sidecar/iPad screen, without relying on the
/// order of the display list.
///
/// The shipped rule was "the first online non-builtin display that is not the virtual
/// one". That is correct only while the iPad is the sole such display. A part-time
/// headless Mac has a monitor too, and then the first entry can be the monitor — which
/// Maccar would then mirror into its virtual display, rearranging the user's physical
/// layout. That is very likely what the 2026-11-20 field report described as "the other
/// screen keeps mirroring".
///
/// The iPad can instead be named outright. Measured on 2026-11-21 with Sidecar
/// connected, `CGDisplayModelNumber` reported `1766875492`, which is `0x69506164` and
/// spells "iPad" as a four-character code.
public enum SidecarDisplayIdentifier {
    /// The model number Sidecar's display reports. `0x69506164` is the four-character
    /// code "iPad".
    public static let sidecarModelNumber: UInt32 = 0x6950_6164

    /// The four-character code encoded in a display's model number, when printable.
    ///
    /// Exposed because the error is silent otherwise: a wrong constant would simply
    /// never match, and the fallback would quietly take over.
    public static func fourCC(_ value: UInt32) -> String? {
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }

    /// Whether a display's model number is the Sidecar signature.
    public static func isSidecarModel(_ modelNumber: UInt32) -> Bool {
        modelNumber == sidecarModelNumber
    }

    /// Chooses the iPad among `candidates` — displays already known to be neither the
    /// virtual display nor built in.
    ///
    /// Positive evidence wins, regardless of where the display sits in the list.
    ///
    /// `nil` with two or more candidates means "not identifiable", and the caller must
    /// **not** mirror: guessing there would reconfigure the user's physical monitor.
    /// A single candidate cannot be ambiguous — there is nothing else it could be — so
    /// it is accepted, which keeps a headless Mac behaving exactly as it does today.
    /// That fallback matters: if Apple ever changes the Sidecar model number, a headless
    /// Mac still mirrors instead of going dark.
    public static func chooseIPad(
        candidates: [CGDirectDisplayID],
        modelNumber: (CGDirectDisplayID) -> UInt32
    ) -> CGDirectDisplayID? {
        if let identified = candidates.first(where: { isSidecarModel(modelNumber($0)) }) {
            return identified
        }
        return candidates.count == 1 ? candidates.first : nil
    }
}
