import AppKit
import MaccarKit

/// Renders release screenshots entirely offscreen: window chrome, live menu items,
/// and text layout are composited with AppKit drawing, so the process never asks for
/// Screen Recording or Accessibility permission and never collides with a running app.
@MainActor
enum ScreenshotExporter {
    private static let cornerRadius: CGFloat = 12
    private static let titleBarHeight: CGFloat = 28
    private static let shadowPadding: CGFloat = 36
    private static let maskedLogPath = "~/Library/Logs/Maccar/maccar.log"
    private static let menuPadding: CGFloat = 12
    private static let menuWidth: CGFloat = 430
    private static let rowHeight: CGFloat = 22
    private static let separatorHeight: CGFloat = 9

    static func export(to directoryURL: URL) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        // Screenshots must not follow the build machine's theme, so capture under Aqua.
        // `performAsCurrentDrawingAppearance` cannot throw, so the failure is carried out by hand.
        var exportFailure: Error?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            do {
                try ScreenshotCanvas.write(
                    compositeWindow(AboutWindowController.shared.makePreviewWindow()),
                    named: "about-window.png", to: directoryURL
                )
                let logs = LogWindowController.shared.makePreviewWindow(
                    entries: sampleLogEntries(), displayLogPath: maskedLogPath
                )
                try ScreenshotCanvas.write(compositeWindow(logs), named: "diagnostics-logs.png", to: directoryURL)
                try ScreenshotCanvas.write(menuBarImage(), named: "menubar-menu.png", to: directoryURL)
            } catch {
                exportFailure = error
            }
        }
        if let exportFailure { throw exportFailure }
    }

    private static func menuBarImage() -> NSImage {
        let controller = MenuBarController(isPreview: true)
        controller.populateMenu(
            status: .connected(deviceName: "VPad", displayID: nil, mirrored: true),
            registered: "VPad",
            reachableDevices: ["VPad"],
            autoConnect: true,
            autoMirror: true,
            launchAtLogin: LaunchAtLoginMenuItem(isOn: true, title: LaunchAtLoginMenuItem.defaultTitle, needsApproval: false),
            shortcutEnabled: true,
            shortcutLabel: "⌃⌥⌘R",
            shortcutConflictLabel: nil,
            preferredResolution: "auto",
            autoCheckUpdates: true,
            isCheckingForUpdates: false,
            availableUpdateVersion: nil
        )
        return renderMenuPopover(items: controller.previewMenu.items)
    }

    // MARK: - Window chrome composite

    private static func compositeWindow(_ window: NSWindow) -> NSImage {
        guard let contentView = window.contentView else {
            return ScreenshotCanvas.render(NSSize(width: 480, height: 320)) { _ in }
        }
        // Views resolve colours from `effectiveAppearance`, which inherits from the window and
        // from each ancestor view; pinning both covers trees that were never shown on screen.
        let aqua = NSAppearance(named: .aqua)
        window.appearance = aqua
        window.layoutIfNeeded()

        let contentSize = contentView.bounds.size
        let windowSize = NSSize(width: contentSize.width, height: contentSize.height + titleBarHeight)
        let canvasSize = NSSize(
            width: windowSize.width + shadowPadding * 2,
            height: windowSize.height + shadowPadding * 2
        )
        let contentImage = ScreenshotCanvas.snapshot(contentView, appearance: aqua)

        return ScreenshotCanvas.render(canvasSize) { _ in
            let frame = NSRect(x: shadowPadding, y: shadowPadding, width: windowSize.width, height: windowSize.height)
            fillCard(frame, radius: cornerRadius, shadowAlpha: 0.28, blur: 18, offset: -6)
            drawWindowChrome(frame, title: window.title)
            contentImage.draw(
                in: NSRect(x: frame.minX, y: frame.minY, width: contentSize.width, height: contentSize.height),
                from: .zero, operation: .sourceOver, fraction: 1.0
            )
        }
    }

    /// Fills a rounded card with a drop shadow; the shared shell for windows and menu cards.
    private static func fillCard(_ rect: NSRect, radius: CGFloat, shadowAlpha: CGFloat, blur: CGFloat, offset: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(shadowAlpha)
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = NSSize(width: 0, height: offset)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawWindowChrome(_ rect: NSRect, title: String) {
        let titleRect = NSRect(x: rect.minX, y: rect.maxY - titleBarHeight, width: rect.width, height: titleBarHeight)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(rect: titleRect).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: rect.minX, y: titleRect.minY, width: rect.width, height: 1).fill()

        let colors = [
            NSColor(srgbRed: 1.00, green: 0.37, blue: 0.34, alpha: 1),
            NSColor(srgbRed: 0.99, green: 0.74, blue: 0.18, alpha: 1),
            NSColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1),
        ]
        let diameter: CGFloat = 11
        let lightY = titleRect.midY - diameter / 2
        for (index, color) in colors.enumerated() {
            color.setFill()
            let x = titleRect.minX + 13 + CGFloat(index) * (diameter + 8)
            NSBezierPath(ovalIn: NSRect(x: x, y: lightY, width: diameter, height: diameter)).fill()
        }

        let attributed = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let size = attributed.size()
        attributed.draw(at: NSPoint(x: titleRect.midX - size.width / 2, y: titleRect.midY - size.height / 2))
    }

    // MARK: - Menu popover composite

    private static func renderMenuPopover(items: [NSMenuItem]) -> NSImage {
        let headerHeight: CGFloat = 26
        let rows = items.map(MenuRow.init)
        let bodyHeight = rows.reduce(0) { $0 + height(of: $1) } + menuPadding * 2
        let canvasSize = NSSize(
            width: menuWidth + shadowPadding * 2,
            height: headerHeight + bodyHeight + shadowPadding * 2
        )

        return ScreenshotCanvas.render(canvasSize) { _ in
            NSColor.controlBackgroundColor.setFill()
            NSRect(x: 0, y: 0, width: canvasSize.width, height: headerHeight).fill()

            let iconSize: CGFloat = 18
            let iconRect = NSRect(
                x: canvasSize.width / 2 - iconSize / 2,
                y: (headerHeight - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )
            MaccarIconRenderer.renderMenuBarIcon(connected: true)
                .draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)

            let cardRect = NSRect(x: shadowPadding, y: shadowPadding, width: menuWidth, height: bodyHeight)
            fillCard(cardRect, radius: 10, shadowAlpha: 0.30, blur: 16, offset: -5)
            NSColor.separatorColor.setStroke()
            let border = NSBezierPath(roundedRect: cardRect, xRadius: 10, yRadius: 10)
            border.lineWidth = 1
            border.stroke()

            var y = cardRect.maxY - menuPadding
            for row in rows {
                let rowHeight = height(of: row)
                drawRow(row, in: NSRect(x: cardRect.minX, y: y - rowHeight, width: cardRect.width, height: rowHeight))
                y -= rowHeight
            }
        }
    }

    // MARK: - Row model and drawing

    private struct MenuRow {
        let title: String
        let isEnabled: Bool
        let isChecked: Bool
        let isSeparator: Bool
        let keyEquivalent: String

        init(_ item: NSMenuItem) {
            title = item.title
            isEnabled = item.isEnabled
            isChecked = item.state == .on
            isSeparator = item.isSeparatorItem
            keyEquivalent = item.keyEquivalent
        }
    }

    private static func height(of row: MenuRow) -> CGFloat { row.isSeparator ? separatorHeight : rowHeight }

    private static func drawRow(_ row: MenuRow, in rect: NSRect) {
        guard !row.isSeparator else {
            NSColor.separatorColor.setFill()
            NSRect(x: rect.minX + menuPadding, y: rect.midY, width: rect.width - menuPadding * 2, height: 1).fill()
            return
        }

        let color = row.isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor
        let font = NSFont.menuFont(ofSize: 13)
        let textY = rect.midY - font.capHeight / 2 - 1

        if row.isChecked {
            NSAttributedString(string: "✓", attributes: [.font: font, .foregroundColor: color])
                .draw(at: NSPoint(x: rect.minX + menuPadding, y: textY))
        }
        NSAttributedString(string: row.title, attributes: [.font: font, .foregroundColor: color])
            .draw(at: NSPoint(x: rect.minX + menuPadding + 16, y: textY))

        guard !row.keyEquivalent.isEmpty else { return }
        let shortcut = row.keyEquivalent.uppercased()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let width = NSAttributedString(string: shortcut, attributes: attributes).size().width
        NSAttributedString(string: shortcut, attributes: attributes)
            .draw(at: NSPoint(x: rect.maxX - menuPadding - width, y: textY))
    }

    // MARK: - Fixtures

    private static func sampleLogEntries() -> [LogEntry] {
        let base = Date(timeIntervalSince1970: 1_763_000_000)
        return [
            ("App", "Maccar v1.3.0 Menu Bar application starting.", LogLevel.info),
            ("Display", "Headless virtual display active: ID 42 (iPad Mini Comfortable).", .info),
            ("Sidecar", "Sidecar session established with 'VPad' over USB.", .info),
            ("Mirror", "Mirroring enabled to virtual display 42.", .info),
            ("DeviceWatcher", "USB attach burst debounced; single reconnect scheduled.", .warning),
            ("HotKey", "Registered global shortcut for Reconnect.", .info),
            ("Updater", "Update check complete: v1.3.0 is the latest release.", .info),
        ].enumerated().map { offset, sample in
            LogEntry(
                timestamp: base.addingTimeInterval(Double(offset) * 3),
                level: sample.2,
                category: sample.0,
                message: sample.1
            )
        }
    }
}
