import AppKit

if CommandLine.arguments.count > 1, CommandLine.arguments[1].hasPrefix("--") {
    Diagnostics.run(CommandLine.arguments)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    // No Dock icon and no menu bar item: Lipsync runs out of sight.
    app.setActivationPolicy(.accessory)
    app.run()
}
