import Foundation
import AppKit
import MaccarKit

@MainActor
public final class LogWindowController: NSObject, NSWindowDelegate {
    public static let shared = LogWindowController()

    private static let defaultWidth: CGFloat = 680
    private static let defaultHeight: CGFloat = 440
    private static let minWidth: CGFloat = 520
    private static let minHeight: CGFloat = 320

    private var window: NSWindow?
    private var pathLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var emptyStateLabel: NSTextField?
    private var copyButton: NSButton?
    private var clearButton: NSButton?
    private var scrollView: NSScrollView?
    private var textView: NSTextView?

    private var isRefreshScheduled = false
    private var currentEntryCount = 0
    private var feedbackResetTask: Task<Void, Never>?
    private var refreshCoalesceTask: Task<Void, Never>?

    private override init() {
        super.init()
    }

    public func show() {
        let win = window ?? buildWindow()
        self.window = win
        subscribeToLogger()
        refreshLogs(scrollToBottom: true)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) {
        MaccarLogger.shared.setOnNewEntry(nil)
        feedbackResetTask?.cancel()
        feedbackResetTask = nil
        refreshCoalesceTask?.cancel()
        refreshCoalesceTask = nil
        isRefreshScheduled = false
    }

    /// Renders the live window chrome with supplied content for offscreen capture.
    /// Deliberately skips `subscribeToLogger()` so a screenshot never installs a live hook.
    internal func makePreviewWindow(entries: [LogEntry], displayLogPath: String) -> NSWindow {
        let win = buildWindow()
        self.window = win

        pathLabel?.stringValue = "Log file: \(displayLogPath)"
        pathLabel?.toolTip = displayLogPath

        let formatted = entries.map(\.formattedLine).joined(separator: "\n")
        currentEntryCount = entries.count
        textView?.string = formatted
        emptyStateLabel?.isHidden = !entries.isEmpty
        copyButton?.isEnabled = !entries.isEmpty
        clearButton?.isEnabled = !entries.isEmpty
        updateDefaultStatusText()

        win.layoutIfNeeded()
        if let layoutManager = textView?.layoutManager, let container = textView?.textContainer {
            layoutManager.ensureLayout(for: container)
        }
        return win
    }

    private func buildWindow() -> NSWindow {
        let rect = NSRect(x: 0, y: 0, width: Self.defaultWidth, height: Self.defaultHeight)
        let win = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Maccar Diagnostics & Logs"
        win.minSize = NSSize(width: Self.minWidth, height: Self.minHeight)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()

        let root = NSView(frame: rect)
        root.wantsLayer = true
        let header = buildHeaderView()
        let divider = makeSeparator()
        let logArea = buildLogArea()

        [header, divider, logArea].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            divider.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            logArea.topAnchor.constraint(equalTo: divider.bottomAnchor),
            logArea.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            logArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            logArea.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        win.contentView = root
        return win
    }

    private func buildHeaderView() -> NSView {
        let pathField = makePathLabel()
        let statusField = makeStatusLabel()
        self.pathLabel = pathField
        self.statusLabel = statusField

        let refreshBtn = makeActionButton("Refresh", action: #selector(refreshTapped), tip: "Reload diagnostic logs")
        let copyBtn = makeActionButton("Copy All", action: #selector(copyAllTapped), tip: "Copy all visible log entries")
        let clearBtn = makeActionButton("Clear", action: #selector(clearTapped), tip: "Clear in-memory log buffer")
        let revealBtn = makeActionButton("Reveal in Finder", action: #selector(revealTapped), tip: "Show log file in Finder")
        self.copyButton = copyBtn
        self.clearButton = clearBtn

        let buttonsRow = NSStackView(views: [refreshBtn, copyBtn, clearBtn, revealBtn])
        buttonsRow.orientation = .horizontal
        buttonsRow.spacing = 8
        buttonsRow.setHuggingPriority(.required, for: .horizontal)

        let bottomRow = NSStackView(views: [statusField, NSView(), buttonsRow])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 8

        let container = NSStackView(views: [pathField, bottomRow])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8

        bottomRow.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        pathField.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        return container
    }

    private func buildLogArea() -> NSView {
        let wrapper = NSView()
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let tv = makeLogTextView()
        scroll.documentView = tv
        self.textView = tv
        self.scrollView = scroll

        let emptyLabel = makeEmptyStateLabel()
        self.emptyStateLabel = emptyLabel
        wrapper.addSubview(scroll)
        wrapper.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: wrapper.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: wrapper.widthAnchor, constant: -48)
        ])
        return wrapper
    }

    private func makeLogTextView() -> NSTextView {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: Self.defaultWidth, height: Self.defaultHeight))
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: Self.defaultWidth, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.usesFindBar = true
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textColor = .labelColor
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 12, height: 12)
        return tv
    }

    private func makeEmptyStateLabel() -> NSTextField {
        let emptyLabel = NSTextField(wrappingLabelWithString: "No diagnostic logs recorded yet.\nEvents will appear here automatically as Maccar runs.")
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        return emptyLabel
    }

    private func makePathLabel() -> NSTextField {
        let logPath = MaccarLogger.shared.logFileURL.path
        let label = NSTextField(labelWithString: "Log file: \(logPath)")
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.isSelectable = true
        label.toolTip = logPath
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func makeStatusLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "0 entries")
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func makeActionButton(_ title: String, action: Selector, tip: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.toolTip = tip
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func makeSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func subscribeToLogger() {
        MaccarLogger.shared.setOnNewEntry { _ in
            Task { @MainActor [weak self] in
                self?.scheduleLiveRefresh()
            }
        }
    }

    private func scheduleLiveRefresh() {
        guard !isRefreshScheduled else { return }
        isRefreshScheduled = true

        // Coalesce burst log writes onto MainActor without delaying individual loggers.
        refreshCoalesceTask?.cancel()
        refreshCoalesceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled else { return }
            self.isRefreshScheduled = false
            guard self.window?.isVisible == true else { return }
            self.refreshLogs(scrollToBottom: self.isScrolledNearBottom())
        }
    }

    private func isScrolledNearBottom() -> Bool {
        guard let tv = textView else { return true }
        return tv.visibleRect.maxY >= (tv.bounds.height - 24)
    }

    private func refreshLogs(scrollToBottom: Bool) {
        let entries = MaccarLogger.shared.recentEntries()
        currentEntryCount = entries.count

        let formatted = entries.map(\.formattedLine).joined(separator: "\n")
        if textView?.string != formatted {
            textView?.string = formatted
        }

        let isEmpty = entries.isEmpty
        emptyStateLabel?.isHidden = !isEmpty
        copyButton?.isEnabled = !isEmpty
        clearButton?.isEnabled = !isEmpty
        updateDefaultStatusText()

        if scrollToBottom, !formatted.isEmpty {
            textView?.scrollToEndOfDocument(nil)
        }
    }

    private func updateDefaultStatusText() {
        statusLabel?.textColor = .secondaryLabelColor
        if currentEntryCount == 0 {
            statusLabel?.stringValue = "No log entries in memory"
        } else if currentEntryCount == 1 {
            statusLabel?.stringValue = "1 entry (max 500 in memory)"
        } else {
            statusLabel?.stringValue = "\(currentEntryCount) entries (max 500 in memory)"
        }
    }

    private func showTransientFeedback(_ message: String, isError: Bool = false) {
        feedbackResetTask?.cancel()
        statusLabel?.stringValue = message
        statusLabel?.textColor = isError ? .systemRed : .controlAccentColor

        feedbackResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.updateDefaultStatusText()
        }
    }

    @objc private func refreshTapped() {
        refreshLogs(scrollToBottom: true)
        showTransientFeedback("Logs refreshed")
    }

    @objc private func copyAllTapped() {
        let text = MaccarLogger.shared.formattedLogs()
        guard !text.isEmpty else {
            showTransientFeedback("Nothing to copy", isError: true)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let unit = currentEntryCount == 1 ? "entry" : "entries"
        showTransientFeedback("Copied \(currentEntryCount) log \(unit) to clipboard")
    }

    @objc private func clearTapped() {
        MaccarLogger.shared.clearMemoryBuffer()
        refreshLogs(scrollToBottom: false)
        showTransientFeedback("Cleared in-memory log buffer")
    }

    @objc private func revealTapped() {
        _ = MaccarLogger.shared.flush(timeout: 0.5)
        let logFileURL = MaccarLogger.shared.logFileURL
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: logFileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logFileURL])
            return
        }

        let dirURL = MaccarLogger.shared.logDirectoryURL
        do {
            try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
            if !NSWorkspace.shared.open(dirURL) {
                showTransientFeedback("Unable to open log folder in Finder.", isError: true)
            }
        } catch {
            showTransientFeedback("Unable to access log folder: \(error.localizedDescription)", isError: true)
        }
    }
}
