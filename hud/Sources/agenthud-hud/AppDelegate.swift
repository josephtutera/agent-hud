import AppKit
import Combine
import SwiftUI
import HUDCore

/// Wires the HUD to one store as a plain menu-bar app. An NSStatusItem hosts the
/// glance (a severity-colored quota ring cluster per subscription, the soonest
/// reset, and a setup dot). Left-click opens the full card panel below it;
/// right-click offers Quit (there's no dock icon or app menu).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = HUDStore()
    private var statusItem: NSStatusItem!
    private var panel: NSPanel?
    /// Redraws the glance whenever the store publishes a new snapshot.
    private var cancellables = Set<AnyCancellable>()
    /// Redraws it when the menu bar changes appearance, which the snapshot knows
    /// nothing about.
    private var appearanceObserver: NSKeyValueObservation?
    /// Mouse monitors that collapse the card on a click outside it. Only alive
    /// while the card is open.
    private var dismissMonitors: [Any] = []
    /// The daemon we spawned, if we did, so we can stop it again on quit and not
    /// leave an orphan behind.
    private var daemonProcess: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launching the app is all it takes: bring up the data daemon ourselves
        // rather than making the user run `agenthud serve` in a second terminal.
        daemonProcess = DaemonLauncher.ensureRunning()
        store.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            // Left-click toggles the card; right-click offers Quit.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // The glance draws in real color, so it does not get AppKit's tint
            // for free and has to be redrawn when the bar flips light or dark.
            appearanceObserver = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.renderGlance() }
            }
        }

        // Re-render on every poll. Published fires the current value on
        // subscribe, so this also draws the initial state.
        renderGlance()
        store.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.renderGlance() }
            .store(in: &cancellables)
    }

    /// Rasterize the glance to a plain (non-template) NSImage.
    ///
    /// A template image would be the conventional choice, and it is what this
    /// used to be: AppKit throws the pixels away, keeps the alpha, and tints the
    /// result for guaranteed contrast over any wallpaper. But the whole point of
    /// the rings is that severity is a color, and a template would flatten
    /// green, amber and red into one shade — leaving a ring that says how much
    /// is spent but not whether that is fine.
    ///
    /// So it draws in color, and everything that is not severity is resolved
    /// against the menu bar's own appearance instead, which buys back the
    /// legibility the template was giving us: near-white ink on a dark bar,
    /// near-black on a light one.
    private func renderGlance() {
        guard let button = statusItem?.button else { return }
        let appearance = button.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        let glance = MenuBarContentView(
            snapshot: store.snapshot,
            now: store.now,
            ink: isDark ? .white : .black
        )
        .environment(\.colorScheme, isDark ? .dark : .light)

        var image: NSImage?
        // Resolve the dynamic Theme colors (severity, amber) against the bar's
        // appearance rather than the app's, which for an accessory app with no
        // windows is not reliably the same thing.
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: glance)
            renderer.scale = button.window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor ?? 2
            renderer.isOpaque = false
            image = renderer.nsImage
        }
        guard let image else { return }
        image.isTemplate = false
        button.image = image
        button.imagePosition = .imageOnly
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeDismissMonitors()
        store.stop()
        // Only stop the daemon if we started it; leave a user-run one alone.
        daemonProcess?.terminate()
    }

    // MARK: - Status item interaction

    @objc private func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
            return
        }
        if let panel, panel.isVisible {
            hidePanel()
            return
        }
        showPanel()
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Quit Agent HUD",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        if let button = statusItem.button {
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: button.bounds.height + 4),
                in: button
            )
        }
    }

    @objc private func quitApp() {
        AppActions.quit()
    }

    // MARK: - Card panel

    private func hidePanel() {
        panel?.orderOut(nil)
        removeDismissMonitors()
    }

    /// Watch for the click that means "I am done looking at this".
    ///
    /// The card is a non-activating panel, so it never becomes key and there is
    /// no resignKey to hang this on. Two monitors cover the two halves: a global
    /// one for clicks that land in another app or on the desktop, and a local one
    /// for clicks inside this app, where most of them must *not* dismiss.
    ///
    /// They only exist while the card is open, so nothing is watching the mouse
    /// the rest of the time.
    private func installDismissMonitors() {
        removeDismissMonitors()

        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]

        let global = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePanel() }
        }
        if let global { dismissMonitors.append(global) }

        // The event is read for its window and then handed straight back:
        // dismissing is not the same as swallowing the click that caused it, and
        // NSEvent must not cross out of the main actor, so only the window does.
        let local = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            let clickedWindow = event.window
            MainActor.assumeIsolated { self?.dismissIfOutside(clickedWindow) }
            return event
        }
        if let local { dismissMonitors.append(local) }
    }

    private func dismissIfOutside(_ clickedWindow: NSWindow?) {
        guard let panel else { return }
        if PanelDismissal.shouldDismiss(
            clickedWindow: clickedWindow,
            panel: panel,
            statusItemWindow: statusItem?.button?.window
        ) {
            hidePanel()
        }
    }

    private func removeDismissMonitors() {
        dismissMonitors.forEach(NSEvent.removeMonitor)
        dismissMonitors.removeAll()
    }

    private func showPanel() {
        let card = CardHost().environmentObject(store)
        let hosting = NSHostingController(rootView: AnyView(card))

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Position just below the status item, right-aligned to it.
        if let button = statusItem.button, let screen = button.window?.screen {
            let buttonFrame = button.window?.convertToScreen(button.frame) ?? .zero
            let size = hosting.view.fittingSize
            var origin = NSPoint(
                x: buttonFrame.maxX - size.width,
                y: buttonFrame.minY - size.height - 6
            )
            origin.x = max(screen.visibleFrame.minX + 8, origin.x)
            panel.setContentSize(size)
            panel.setFrameOrigin(origin)
        }

        panel.orderFrontRegardless()
        self.panel = panel
        installDismissMonitors()
    }
}

/// SwiftUI wrapper for the card so it redraws on every poll.
private struct CardHost: View {
    @EnvironmentObject var store: HUDStore
    var body: some View {
        PopoverCard(snapshot: store.snapshot, now: store.now) {
            store.refreshNow()
        }
        .padding(10)
    }
}
