import Foundation
import Testing
@testable import MaccarKit

/// The fallback manifest URL moved from GitHub Pages to the site's own domain.
///
/// GitHub Pages was retired on 2026-11-17 and `vidokun.github.io/Maccar/manifest.json` now
/// returns 404, so the fallback spent a request on a dead host every time the primary failed.
/// The site at maccar.vidokun.com serves the same manifest through its build step.
///
/// The allowlist in `TrustedReleaseURLValidator` is the reason this needs a test rather than a
/// one-line URL swap: a fallback the validator rejects is never fetched, so the change would
/// look correct and do nothing.
@Suite("Fallback Manifest URL Tests")
struct FallbackManifestURLTests {

    @Test("The fallback points at the site's own domain, not the retired Pages host")
    func fallbackUsesProductionDomain() {
        let host = ReleaseUpdater.fallbackManifestURL.host?.lowercased()
        #expect(host == "maccar.vidokun.com", "fallback must target the live site, got \(host ?? "nil")")
        #expect(ReleaseUpdater.fallbackManifestURL.lastPathComponent == "manifest.json")
    }

    @Test("The validator accepts the fallback URL")
    func validatorAcceptsFallback() throws {
        // Without this, the URL is rejected before any fetch and the fallback silently never runs.
        try TrustedReleaseURLValidator.validateURL(ReleaseUpdater.fallbackManifestURL)
    }

    @Test("The validator accepts the primary URL")
    func validatorAcceptsPrimary() throws {
        try TrustedReleaseURLValidator.validateURL(ReleaseUpdater.primaryManifestURL)
    }

    @Test("The retired Pages host is no longer trusted")
    func retiredHostIsRejected() {
        let retired = URL(string: "https://vidokun.github.io/Maccar/manifest.json")!
        #expect(throws: ReleaseUpdateError.self) {
            try TrustedReleaseURLValidator.validateURL(retired)
        }
    }

    @Test("The allowlist is not a wildcard: other hosts stay rejected")
    func unrelatedHostsAreRejected() {
        for hostile in ["https://evil.example.com/manifest.json",
                        "https://maccar.vidokun.com.evil.com/manifest.json",
                        "https://vidokun.github.io.evil.com/Maccar/manifest.json"] {
            let url = URL(string: hostile)!
            #expect(throws: ReleaseUpdateError.self) {
                try TrustedReleaseURLValidator.validateURL(url)
            }
        }
    }
}
