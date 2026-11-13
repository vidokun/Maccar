import Foundation
import AppKit
import MaccarKit

private struct BrandSiteDescriptor: Sendable {
    let title: String
    let subtitle: String
    let urlString: String
    let logoName: String
    let host: String
}

private enum BrandLogoLoader {
    static func loadLogo(named name: String) -> NSImage? {
        for url in candidateURLs(for: name) {
            if FileManager.default.fileExists(atPath: url.path), let img = NSImage(contentsOf: url) {
                return img
            }
        }
        return nil
    }

    private static func candidateURLs(for name: String) -> [URL] {
        var urls: [URL] = []
        if let bundleURL = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "BrandLogos") {
            urls.append(bundleURL)
        }
        if let resourceRoot = Bundle.main.resourceURL {
            urls.append(resourceRoot.appendingPathComponent("BrandLogos/\(name).png"))
        }
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            urls.append(execDir.appendingPathComponent("../../../Resources/BrandLogos/\(name).png").standardizedFileURL)
            urls.append(execDir.appendingPathComponent("Resources/BrandLogos/\(name).png").standardizedFileURL)
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        urls.append(cwd.appendingPathComponent("Resources/BrandLogos/\(name).png"))
        return urls
    }
}

private final class FlippedContentView: NSView {
    override var isFlipped: Bool { true }
}

private final class DeveloperBadgeView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.28).setStroke()
            path.lineWidth = 1.0
            path.stroke()
        }
    }
}

@MainActor
private final class BrandSiteButton: NSControl {
    private let descriptor: BrandSiteDescriptor
    private let onError: (String) -> Void
    private let logoView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()

    private var trackingAreaRef: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false
    private var isLoading = false
    private var errorMessage: String?

    init(frame: NSRect, descriptor: BrandSiteDescriptor, onError: @escaping (String) -> Void) {
        self.descriptor = descriptor
        self.onError = onError
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(descriptor.title) — \(descriptor.host)")
        configureSubviews()
        applyVisualState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var focusRingMaskBounds: NSRect { bounds }

    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1.0 : 0.45
            window?.invalidateCursorRects(for: self)
            applyVisualState()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        return (isEnabled && bounds.contains(localPoint)) ? self : nil
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyVisualState()
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovered = true
        applyVisualState()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        applyVisualState()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        applyVisualState()
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        applyVisualState()
        let location = convert(event.locationInWindow, from: nil)
        if wasPressed, isEnabled, bounds.contains(location) { triggerOpen() }
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, let chars = event.charactersIgnoringModifiers, chars == " " || chars == "\r" || chars == "\n" else {
            super.keyDown(with: event)
            return
        }
        triggerOpen()
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
            cardFillColor().setFill()
            path.fill()
            cardBorderColor().setStroke()
            path.lineWidth = (isHovered || isPressed) ? 1.25 : 1.0
            path.stroke()
        }
    }

    private func configureSubviews() {
        logoView.frame = NSRect(x: 12, y: 8, width: 32, height: 32)
        logoView.imageScaling = .scaleProportionallyUpOrDown
        logoView.wantsLayer = true
        logoView.layer?.cornerRadius = 6
        logoView.layer?.masksToBounds = true
        if let logo = BrandLogoLoader.loadLogo(named: descriptor.logoName) {
            logoView.image = logo
        } else {
            let fallback = NSImage(systemSymbolName: "globe", accessibilityDescription: descriptor.title)
            logoView.image = fallback?.withSymbolConfiguration(.init(pointSize: 18, weight: .medium))
            logoView.contentTintColor = .secondaryLabelColor
        }
        addSubview(logoView)

        titleLabel.stringValue = descriptor.title
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 56, y: 7, width: bounds.width - 96, height: 18)
        addSubview(titleLabel)

        subtitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.frame = NSRect(x: 56, y: 25, width: bounds.width - 96, height: 16)
        addSubview(subtitleLabel)

        chevronView.frame = NSRect(x: bounds.width - 28, y: 16, width: 14, height: 14)
        chevronView.imageScaling = .scaleProportionallyDown
        addSubview(chevronView)
    }

    private func applyVisualState() {
        if let errorMessage {
            subtitleLabel.stringValue = errorMessage
            subtitleLabel.textColor = .systemRed
        } else if isLoading {
            subtitleLabel.stringValue = "Opening \(descriptor.host)…"
            subtitleLabel.textColor = .controlAccentColor
        } else {
            subtitleLabel.stringValue = descriptor.subtitle
            subtitleLabel.textColor = .secondaryLabelColor
        }

        let symbolName = isLoading ? "hourglass" : "arrow.up.right"
        let chevron = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Open website")
        chevronView.image = chevron?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        chevronView.contentTintColor = (isHovered || isPressed) ? .controlAccentColor : .tertiaryLabelColor
        needsDisplay = true
    }

    private func cardFillColor() -> NSColor {
        if isPressed { return NSColor.controlAccentColor.withAlphaComponent(0.14) }
        if isHovered { return NSColor.controlAccentColor.withAlphaComponent(0.06) }
        return NSColor.controlBackgroundColor
    }

    private func cardBorderColor() -> NSColor {
        if errorMessage != nil { return NSColor.systemRed.withAlphaComponent(0.70) }
        if isHovered || isPressed { return NSColor.controlAccentColor.withAlphaComponent(0.50) }
        return NSColor.separatorColor
    }

    private func triggerOpen() {
        guard isEnabled else { return }
        errorMessage = nil
        guard let url = URL(string: descriptor.urlString) else {
            reportOpenError("Unable to open \(descriptor.host)")
            return
        }

        isLoading = true
        applyVisualState()
        guard NSWorkspace.shared.open(url) else {
            isLoading = false
            reportOpenError("Unable to open \(descriptor.host)")
            MaccarLogger.shared.warning("About", "Failed to open URL: \(descriptor.urlString)")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            self?.isLoading = false
            self?.applyVisualState()
        }
    }

    private func reportOpenError(_ message: String) {
        errorMessage = message
        applyVisualState()
        onError(message)
    }
}

@MainActor
public final class AboutWindowController: NSObject {
    public static let shared = AboutWindowController()

    private static let windowWidth: CGFloat = 480
    private static let windowHeight: CGFloat = 528
    private static let sideMargin: CGFloat = 32

    private var window: NSWindow?
    private var statusBannerLabel: NSTextField?

    public func show() {
        if let existing = window {
            statusBannerLabel?.isHidden = true
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let win = buildWindow()
        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() -> NSWindow {
        let rect = NSRect(x: 0, y: 0, width: Self.windowWidth, height: Self.windowHeight)
        let win = NSWindow(contentRect: rect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "About Maccar"
        win.center()
        win.isReleasedWhenClosed = false

        let content = FlippedContentView(frame: rect)
        addHeaderBlock(to: content)
        addWebsitesSection(to: content)
        addHeritageAndFooter(to: content)
        win.contentView = content
        return win
    }

    private func addHeaderBlock(to content: NSView) {
        let iconView = NSImageView(frame: NSRect(x: (Self.windowWidth - 64) / 2, y: 24, width: 64, height: 64))
        iconView.image = resolveAppIconImage()
        content.addSubview(iconView)

        content.addSubview(makeCenteredLabel("Maccar", y: 96, height: 28, font: .boldSystemFont(ofSize: 22), color: .labelColor))
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.4.0"
        content.addSubview(makeCenteredLabel("Version \(version) · Apple Silicon Native", y: 126, height: 16, font: .systemFont(ofSize: 11), color: .secondaryLabelColor))
        content.addSubview(makeCenteredLabel("Headless Virtual Display & Sidecar Manager", y: 146, height: 18, font: .systemFont(ofSize: 12, weight: .medium), color: .labelColor))

        let badgeWidth: CGFloat = 200
        let badge = DeveloperBadgeView(frame: NSRect(x: (Self.windowWidth - badgeWidth) / 2, y: 172, width: badgeWidth, height: 24))
        let devLabel = NSTextField(labelWithString: "Developed by Vido Rizki")
        devLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        devLabel.textColor = .labelColor
        devLabel.alignment = .center
        devLabel.frame = NSRect(x: 8, y: 4, width: badgeWidth - 16, height: 16)
        badge.addSubview(devLabel)
        content.addSubview(badge)
        content.addSubview(makeSeparator(y: 210))
    }

    private func addWebsitesSection(to content: NSView) {
        let innerWidth = Self.windowWidth - (Self.sideMargin * 2)
        let sectionLabel = NSTextField(labelWithString: "Websites & Studios")
        sectionLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        sectionLabel.textColor = .secondaryLabelColor
        sectionLabel.frame = NSRect(x: Self.sideMargin, y: 220, width: 200, height: 16)
        content.addSubview(sectionLabel)

        let banner = NSTextField(labelWithString: "")
        banner.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        banner.textColor = .systemRed
        banner.alignment = .right
        banner.isHidden = true
        banner.frame = NSRect(x: Self.sideMargin + 200, y: 220, width: innerWidth - 200, height: 16)
        content.addSubview(banner)
        self.statusBannerLabel = banner

        let sites: [BrandSiteDescriptor] = [
            .init(title: "Vido Rizki", subtitle: "vidokun.com · Personal Portfolio", urlString: "https://vidokun.com", logoName: "vidokun", host: "vidokun.com"),
            .init(title: "Dokun Digital", subtitle: "dokundigital.com · Digital Agency", urlString: "https://dokundigital.com", logoName: "dokundigital", host: "dokundigital.com"),
            .init(title: "Dokun Web", subtitle: "dokunweb.com · Web Engineering", urlString: "https://dokunweb.com", logoName: "dokunweb", host: "dokunweb.com")
        ]

        for (index, site) in sites.enumerated() {
            let cardFrame = NSRect(x: Self.sideMargin, y: 244 + CGFloat(index) * 56, width: innerWidth, height: 48)
            let button = BrandSiteButton(frame: cardFrame, descriptor: site) { [weak self] errorText in
                self?.statusBannerLabel?.stringValue = errorText
                self?.statusBannerLabel?.isHidden = false
            }
            content.addSubview(button)
        }
        content.addSubview(makeSeparator(y: 416))
    }

    private func addHeritageAndFooter(to content: NSView) {
        let innerWidth = Self.windowWidth - (Self.sideMargin * 2)
        let header = NSTextField(labelWithString: "Open-Source Heritage & Acknowledgements")
        header.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        header.textColor = .secondaryLabelColor
        header.frame = NSRect(x: Self.sideMargin, y: 426, width: innerWidth, height: 16)
        content.addSubview(header)

        let heritageText = """
        • sill (Saffsanity) & vdisplay (adamkpn) — Apple Silicon & CGVirtualDisplay research
        • headless-sidecar (balook) & SidecarLauncher — SidecarCore framework research
        • CoreGraphics & SidecarCore reverse-engineering community
        """
        let creditsField = NSTextField(wrappingLabelWithString: heritageText)
        creditsField.font = NSFont.systemFont(ofSize: 10.5)
        creditsField.textColor = .secondaryLabelColor
        creditsField.isSelectable = true
        creditsField.frame = NSRect(x: Self.sideMargin, y: 444, width: innerWidth, height: 48)
        content.addSubview(creditsField)

        content.addSubview(makeCenteredLabel("© 2026 Vido Rizki (kreasai) · Licensed under GPL-3.0", y: 498, height: 16, font: .systemFont(ofSize: 10), color: .tertiaryLabelColor))
    }

    internal func makePreviewWindow() -> NSWindow { buildWindow() }

    private func resolveAppIconImage() -> NSImage {
        if let icnsURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icnsImage = NSImage(contentsOf: icnsURL) {
            return icnsImage
        }
        if Bundle.main.bundleURL.pathExtension == "app", let appIcon = NSApp.applicationIconImage {
            return appIcon
        }
        return MaccarIconRenderer.renderAppIcon(size: 64)
    }

    private func makeCenteredLabel(_ text: String, y: CGFloat, height: CGFloat, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.alignment = .center
        label.frame = NSRect(x: 24, y: y, width: Self.windowWidth - 48, height: height)
        return label
    }

    private func makeSeparator(y: CGFloat) -> NSBox {
        let separator = NSBox(frame: NSRect(x: Self.sideMargin, y: y, width: Self.windowWidth - (Self.sideMargin * 2), height: 1))
        separator.boxType = .separator
        return separator
    }
}
