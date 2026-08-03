import Foundation

/// Starts the Python snapshot daemon so launching the menu-bar app is the only
/// thing you do — no separate `agenthud serve` in another terminal. On launch the
/// HUD checks whether a daemon is already answering on the loopback port; if
/// not, it finds the repo's `main.py` by walking up from its own executable and
/// spawns `python main.py serve`. The spawned process is handed back so the app
/// can stop it again when it quits, leaving no orphan daemon.
enum DaemonLauncher {
    static let port = 8737

    /// Ensure a daemon is running; returns the process we spawned (nil if one
    /// was already up, or if we couldn't locate the daemon to start it).
    static func ensureRunning() -> Process? {
        if isReachable() { return nil }
        guard let paths = resolvePaths() else {
            let message = "agenthud-hud: couldn't find the daemon (main.py) near the app; "
                + "start it manually with `python3 main.py serve`\n"
            FileHandle.standardError.write(Data(message.utf8))
            return nil
        }
        let proc = Process()
        proc.executableURL = paths.python
        proc.arguments = paths.pythonArguments + [paths.mainPy.path, "serve"]
        proc.currentDirectoryURL = paths.mainPy.deletingLastPathComponent()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            return proc
        } catch {
            FileHandle.standardError.write(Data("agenthud-hud: failed to start daemon: \(error)\n".utf8))
            return nil
        }
    }

    /// A quick synchronous liveness check against /v1/health. Runs once at
    /// startup, so a short block is fine.
    static func isReachable() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.6
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 { ok = true }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 1.0)
        return ok
    }

    struct DaemonPaths {
        let python: URL
        /// Leading arguments the interpreter itself needs, before `main.py`.
        /// Empty for a real interpreter path; `["python3"]` when we go via `env`.
        let pythonArguments: [String]
        let mainPy: URL
    }

    /// Find the daemon's `main.py`, and an interpreter to run it with. First walk
    /// up from the executable (the dev case: binary at
    /// `<root>/hud/.build/<config>/agenthud-hud`); then fall back to the
    /// AHDaemonRoot path build-app.sh baked into Info.plist, so an installed copy
    /// in /Applications still finds the repo it came from.
    static func resolvePaths() -> DaemonPaths? {
        let exe = (Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "")).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<6 {
            if let found = daemonPaths(in: dir) { return found }
            dir = dir.deletingLastPathComponent()
        }
        if let root = Bundle.main.object(forInfoDictionaryKey: "AHDaemonRoot") as? String,
           !root.isEmpty,
           let found = daemonPaths(in: URL(fileURLWithPath: root)) {
            return found
        }
        return nil
    }

    /// The daemon is standard library only, so a checkout with no virtualenv is
    /// the normal case and `python3` off PATH runs it. A `.venv` is still
    /// preferred when one exists, since that is the interpreter whoever made it
    /// meant this repo to use.
    private static func daemonPaths(in dir: URL) -> DaemonPaths? {
        let mainPy = dir.appendingPathComponent("main.py")
        guard FileManager.default.fileExists(atPath: mainPy.path) else { return nil }
        let venvPython = dir.appendingPathComponent(".venv/bin/python")
        if FileManager.default.fileExists(atPath: venvPython.path) {
            return DaemonPaths(python: venvPython, pythonArguments: [], mainPy: mainPy)
        }
        return DaemonPaths(
            python: URL(fileURLWithPath: "/usr/bin/env"),
            pythonArguments: ["python3"],
            mainPy: mainPy
        )
    }
}
