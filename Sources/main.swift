// ScreenshotRename — press a global hotkey, select a region, preview, name the file, done.
//
// Runs as a background agent (no Dock icon). The hotkey is registered with
// Carbon's RegisterEventHotKey, which needs no Accessibility permission.
// The capture itself is done by Apple's /usr/sbin/screencapture.
//
// Flow: hotkey → region selection → preview window → (optional Markup) → Done →
// Save dialog → write. Markup is Apple's own Markup extension, opened through
// the public NSSharingService API.
// The image is held in memory from capture until the Save dialog is confirmed;
// cancelling the preview or the Save dialog leaves nothing on disk.

import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

// MARK: - Configuration

// Default shortcut: Cmd + Shift + 7. Key codes are physical keys (US layout names).
let hotKeyCode = UInt32(kVK_ANSI_7)
let hotKeyModifiers = UInt32(cmdKey | shiftKey)

let lastDirectoryKey = "LastSaveDirectory"

// MARK: - Capture

final class ScreenshotController {
    private var capturing = false
    private var previews: Set<PreviewWindowController> = []

    func trigger() {
        guard !capturing else { return }
        capturing = true

        // screencapture can only write to a path. It goes to the per-user
        // private temp folder and is read back and deleted right after capture.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenshot-rename-\(UUID().uuidString).png")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i interactive region selection (Space toggles window mode, Esc cancels)
        // -x no sound, -t png lossless at native resolution
        process.arguments = ["-i", "-x", "-t", "png", tempURL.path]
        process.terminationHandler = { [weak self] _ in
            let data = try? Data(contentsOf: tempURL)
            try? FileManager.default.removeItem(at: tempURL)
            DispatchQueue.main.async { self?.captureFinished(data) }
        }
        do {
            try process.run()
        } catch {
            capturing = false
            showError("Could not start screencapture: \(error.localizedDescription)")
        }
    }

    private func captureFinished(_ data: Data?) {
        capturing = false
        // User pressed Esc: screencapture exits without writing anything.
        guard let data, !data.isEmpty, let image = NSImage(data: data) else { return }

        let preview = PreviewWindowController(imageData: data, image: image) { [weak self] p in
            self?.previews.remove(p)
        }
        previews.insert(preview)
        preview.present()
    }
}

// MARK: - Preview window

final class PreviewWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
                                     NSSharingServiceDelegate {
    private static let actionsItem = NSToolbarItem.Identifier("actions")

    // Apple's system Markup extension (MarkupUI.framework/PlugIns/Markup.appex).
    private static let markupServiceName = NSSharingService.Name("com.apple.MarkupUI.Markup")

    // Original PNG bytes from screencapture; replaced only if Markup returns an edit.
    private var imageData: Data
    private let imageView = NSImageView()
    private var markupService: NSSharingService?
    private var actionButtons: NSStackView!
    private let onClose: (PreviewWindowController) -> Void

    init(imageData: Data, image: NSImage, onClose: @escaping (PreviewWindowController) -> Void) {
        self.imageData = imageData
        self.onClose = onClose

        // NSImage size is in points (screencapture tags Retina PNGs at 144 dpi),
        // so the preview shows the capture at its true on-screen size when it fits.
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let maxSize = NSSize(width: visible.width * 0.8, height: visible.height * 0.8)
        let scale = min(1, maxSize.width / image.size.width, maxSize.height / image.size.height)

        let window = NSWindow(contentRect: .zero,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Screenshot"
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor

        imageView.image = image
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        window.contentView = imageView

        super.init(window: window)
        window.delegate = self
        actionButtons = makeActionButtons()

        // Keep the window wide enough that the toolbar never pushes buttons into
        // an overflow (») menu: traffic lights + title + the button group.
        let minWidth = ceil(actionButtons.fittingSize.width) + 320
        window.minSize = NSSize(width: minWidth, height: 220)
        window.setContentSize(NSSize(width: max(minWidth, image.size.width * scale),
                                     height: max(220, image.size.height * scale)))

        let toolbar = NSToolbar(identifier: "ScreenshotPreview")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Toolbar

    /// Markup, Cancel and Done live in one toolbar item so they always show together.
    private func makeActionButtons() -> NSStackView {
        // Markup is always shown; the extension is looked up when it's clicked,
        // since the system may not have it ready the moment the window opens.
        let symbol = NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: "Markup")!
        let markup = NSButton(image: symbol, target: self, action: #selector(markup))
        markup.toolTip = "Markup"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}" // Esc
        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.keyEquivalent = "\r" // Return; also gives the accent-colored default style
        let buttons = [markup, cancel, done]
        buttons.forEach { $0.bezelStyle = .push }
        return NSStackView(views: buttons)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.actionsItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == Self.actionsItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = actionButtons
        item.label = "Actions"
        return item
    }

    // MARK: Actions

    @objc private func markup() {
        openMarkup(attemptsLeft: 10)
    }

    private func openMarkup(attemptsLeft: Int) {
        guard let window, window.attachedSheet == nil, markupService == nil,
              let image = imageView.image else { return }
        guard let service = NSSharingService(named: Self.markupServiceName) else {
            // Extension discovery can lag briefly; retry for up to ~2 seconds.
            if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.openMarkup(attemptsLeft: attemptsLeft - 1)
                }
            } else {
                showError("Markup isn't available on this Mac right now.")
            }
            return
        }
        service.delegate = self
        markupService = service
        service.perform(withItems: [image])
        detachMarkupEditor(attemptsLeft: 30)
    }

    /// Markup opens as a borderless overlay pinned to the preview. Turn its editor
    /// into a normal window (title bar, draggable, resizable) placed beside the
    /// preview. If the editor window can't be found, Markup keeps its default look.
    private func detachMarkupEditor(attemptsLeft: Int) {
        guard let window, markupService != nil else { return }
        let overlay = window.childWindows ?? []
        // The editor is the overlay window with a title ("Markup"); the others are
        // its dimming and blur backdrop.
        guard let editor = overlay.first(where: { !$0.title.isEmpty }) else {
            if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.detachMarkupEditor(attemptsLeft: attemptsLeft - 1)
                }
            }
            return
        }

        let contentSize = editor.frame.size
        for child in overlay {
            window.removeChildWindow(child)
            if child !== editor { child.orderOut(nil) }
        }
        editor.styleMask = [.titled]
        editor.styleMask.insert(.resizable) // dropped if set together with .titled on a borderless window
        // The editor's own frame doesn't lay out a real title bar (blank buttons,
        // title drawn over them), so hide those and keep the strip as a drag handle.
        // Markup is closed with its own Cancel/Done, so the buttons aren't needed.
        editor.titleVisibility = .hidden
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            editor.standardWindowButton(kind)?.isHidden = true
        }
        // The editor's window class is always transparent and relied on the hidden
        // backdrop for its material and shadow, so put a standard window
        // background behind its title bar and content.
        if let frameView = editor.contentView?.superview {
            // A solid fill, not a vibrancy material: materials blend with what's
            // behind the window and let the desktop show through.
            let background = NSBox(frame: frameView.bounds)
            background.boxType = .custom
            background.borderWidth = 0
            background.fillColor = .windowBackgroundColor // follows light/dark mode
            background.autoresizingMask = [.width, .height]
            frameView.addSubview(background, positioned: .below, relativeTo: nil)

            // Centered "Markup" label in the drag strip.
            let label = NSTextField(labelWithString: "Markup")
            label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.sizeToFit()
            let strip = frameView.bounds.height - (editor.contentView?.frame.height ?? 0)
            let y = (strip - label.frame.height) / 2
            label.setFrameOrigin(NSPoint(x: (frameView.bounds.width - label.frame.width) / 2,
                                         y: frameView.isFlipped ? y : frameView.bounds.height - strip + y))
            label.autoresizingMask = [.minXMargin, .maxXMargin, frameView.isFlipped ? .maxYMargin : .minYMargin]
            frameView.addSubview(label, positioned: .above, relativeTo: background)
        }
        editor.hasShadow = true
        editor.minSize = editor.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 480, height: 240)).size

        // Beside the preview if there's room (right, then left), else overlapping; always on screen.
        var frame = editor.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        frame.size.width = min(frame.width, screen.width)
        frame.size.height = min(frame.height, screen.height)
        if window.frame.maxX + 16 + frame.width <= screen.maxX {
            frame.origin.x = window.frame.maxX + 16
        } else if window.frame.minX - 16 - frame.width >= screen.minX {
            frame.origin.x = window.frame.minX - 16 - frame.width
        } else {
            frame.origin.x = min(max(window.frame.minX, screen.minX), screen.maxX - frame.width)
        }
        frame.origin.y = min(max(window.frame.maxY - frame.height, screen.minY), screen.maxY - frame.height)
        editor.setFrame(frame, display: true)
        editor.makeKeyAndOrderFront(nil)
    }

    @objc private func cancel() {
        guard markupService == nil else { return } // finish or cancel Markup first
        window?.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        markupService == nil
    }

    @objc private func done() {
        // While Markup is open, its edits aren't in the preview yet.
        guard let window, window.attachedSheet == nil, markupService == nil else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultName()
        panel.directoryURL = lastDirectory()

        panel.beginSheetModal(for: window) { [weak self] response in
            // Cancelling the Save dialog returns to the preview; nothing is written.
            guard let self, response == .OK, let dest = panel.url else { return }
            do {
                // The save panel already confirmed any overwrite with the user.
                try self.imageData.write(to: dest, options: .atomic)
                UserDefaults.standard.set(dest.deletingLastPathComponent().path, forKey: lastDirectoryKey)
                window.close()
            } catch {
                showError("Could not save screenshot: \(error.localizedDescription)")
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose(self)
    }

    // MARK: Markup (NSSharingServiceDelegate)

    func sharingService(_ sharingService: NSSharingService,
                        sourceWindowForShareItems items: [Any],
                        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        window // Markup attaches its overlay here; detachMarkupEditor() then frees it
    }

    func sharingService(_ sharingService: NSSharingService, sourceFrameOnScreenForShareItem item: Any) -> NSRect {
        // Without this the editor briefly appears at the screen's bottom-left corner.
        guard let window else { return .zero }
        return window.convertToScreen(imageView.convert(imageView.bounds, to: nil))
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        markupService = nil
        loadEditedImage(from: items) { [weak self] edited in
            DispatchQueue.main.async {
                guard let self, let edited else { return }
                guard let png = pngPreservingResolution(edited, like: self.imageData) else {
                    showError("Could not read the edited image from Markup.")
                    return
                }
                self.imageData = png
                self.imageView.image = NSImage(data: png)
            }
        }
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        markupService = nil // Markup was cancelled; keep the current image
    }
}

// MARK: - Markup result handling

/// Extracts the edited image from whatever form the Markup extension hands back.
func loadEditedImage(from items: [Any], completion: @escaping (NSImage?) -> Void) {
    for item in items {
        if let image = item as? NSImage { return completion(image) }
        if let url = item as? URL { return completion(NSImage(contentsOf: url)) }
        if let data = item as? Data { return completion(NSImage(data: data)) }
        let providers = (item as? NSExtensionItem)?.attachments ?? [item as? NSItemProvider].compactMap { $0 }
        if let provider = providers.first(where: { $0.canLoadObject(ofClass: NSImage.self) }) {
            provider.loadObject(ofClass: NSImage.self) { object, _ in completion(object as? NSImage) }
            return
        }
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                completion(data.flatMap(NSImage.init(data:)))
            }
            return
        }
    }
    completion(nil)
}

/// Encodes `image` as PNG at its full pixel size, keeping the original capture's
/// pixel density (e.g. 144 dpi on Retina) so it opens at the same size.
func pngPreservingResolution(_ image: NSImage, like originalPNG: Data) -> Data? {
    guard let original = NSBitmapImageRep(data: originalPNG) else { return nil }
    let bitmap: NSBitmapImageRep
    if let best = image.representations.compactMap({ $0 as? NSBitmapImageRep })
        .max(by: { $0.pixelsWide < $1.pixelsWide }),
       let copy = best.copy() as? NSBitmapImageRep {
        bitmap = copy
    } else {
        // Vector or other rep: render at the original capture's pixel size.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: original.pixelsWide, pixelsHigh: original.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: original.pixelsWide, height: original.pixelsHigh))
        NSGraphicsContext.restoreGraphicsState()
        bitmap = rep
    }
    let pointsPerPixel = original.size.width / CGFloat(original.pixelsWide)
    bitmap.size = NSSize(width: CGFloat(bitmap.pixelsWide) * pointsPerPixel,
                         height: CGFloat(bitmap.pixelsHigh) * pointsPerPixel)
    return bitmap.representation(using: .png, properties: [:])
}

// MARK: - Helpers

func defaultName() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    return "Screenshot \(f.string(from: Date())).png"
}

func lastDirectory() -> URL {
    if let path = UserDefaults.standard.string(forKey: lastDirectoryKey),
       FileManager.default.fileExists(atPath: path) {
        return URL(fileURLWithPath: path)
    }
    return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
}

func showError(_ message: String) {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "ScreenshotRename"
    alert.informativeText = message
    alert.runModal()
}

// MARK: - Global hotkey

let controller = ScreenshotController()

func registerHotKey() {
    var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                  eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        DispatchQueue.main.async { controller.trigger() }
        return noErr
    }, 1, &eventType, nil, nil)

    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: OSType(0x5353_524E), id: 1) // 'SSRN'
    let status = RegisterEventHotKey(hotKeyCode, hotKeyModifiers, id,
                                     GetApplicationEventTarget(), 0, &ref)
    if status != noErr {
        NSLog("ScreenshotRename: failed to register hotkey (status \(status)); is it already in use?")
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Only one copy should run: an older one would keep the hotkey and shadow this build.
for other in NSRunningApplication.runningApplications(withBundleIdentifier: "local.screenshot-rename")
    where other.processIdentifier != getpid() {
    other.forceTerminate()
}
// Start extension discovery early so Markup is ready by the first capture.
_ = NSSharingService(named: NSSharingService.Name("com.apple.MarkupUI.Markup"))

registerHotKey()
app.run()
