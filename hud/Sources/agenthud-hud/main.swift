import AppKit
import HUDCore

// Entry point. Three modes:
//   agenthud-hud                                   -> run the menu-bar HUD
//   agenthud-hud --render-preview out.png          -> render the card (dark) to a PNG
//   agenthud-hud --render-preview-light out.png    -> render the card in light mode
//   agenthud-hud --render-preview-clear out.png    -> render the card on a day
//                                                  when nothing is wrong
//   agenthud-hud --render-preview-menubar out.png  -> render the menu-bar glance and
//                                                  its dropdown card, then exit
// The preview modes are how reviewers (and CI) see the UI headlessly.

let args = CommandLine.arguments

func runRender(_ flag: String, defaultName: String, render: @MainActor (URL) throws -> Void) {
    guard let flagIndex = args.firstIndex(of: flag) else { return }
    let outPath = args.indices.contains(flagIndex + 1) ? args[flagIndex + 1] : defaultName
    let url = URL(fileURLWithPath: outPath)
    // ImageRenderer needs the AppKit machinery initialized, but not a full run
    // loop. Touch the shared application, then render on the main actor.
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    do {
        try MainActor.assumeIsolated {
            try render(url)
        }
        FileHandle.standardError.write(Data("rendered preview to \(url.path)\n".utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("preview render failed: \(error)\n".utf8))
        exit(1)
    }
}

runRender("--render-preview", defaultName: "preview.png") { url in
    try PreviewRenderer.renderCardPNG(to: url, scale: 2, colorScheme: .dark)
}
runRender("--render-preview-light", defaultName: "preview-light.png") { url in
    try PreviewRenderer.renderCardPNG(to: url, scale: 2, colorScheme: .light)
}
runRender("--render-preview-clear", defaultName: "preview-all-clear.png") { url in
    try PreviewRenderer.renderAllClearPNG(to: url, scale: 2, colorScheme: .dark)
}
runRender("--render-preview-menubar", defaultName: "preview-menubar.png") { url in
    try PreviewRenderer.renderMenubarPNG(to: url, scale: 2)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // LSUIElement-style: no dock icon
    app.run()
}
