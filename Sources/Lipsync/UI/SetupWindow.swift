import AppKit
import SwiftUI

/// First-run setup: four permissions, then Lipsync disappears into the background.
@MainActor final class SetupModel: ObservableObject {
    enum StepState: Equatable {
        case todo
        case working
        case done
        case failed(String)
    }

    @Published var appleMusic: StepState = .todo
    @Published var spotifyControl: StepState = .todo
    @Published var mute: StepState = .todo
    @Published var spotifyAccount: StepState = .todo
    @Published var clientID = Settings.spotifyClientID ?? ""
    /// The Music app plays the songs (no developer account); otherwise MusicKit does.
    @Published var usesMusicApp = true
    @Published var openAtLogin = true

    var allowAppleMusic: () -> Void = {}
    var allowSpotifyControl: () -> Void = {}
    var allowMute: () -> Void = {}
    var connectSpotify: () -> Void = {}
    var finish: () -> Void = {}

    var needsClientID: Bool { Settings.spotifyClientID == nil }
    var canFinish: Bool { appleMusic == .done && spotifyControl == .done }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lipsync").font(.system(size: 20, weight: .semibold))
                    Text("Use Spotify like always. Hear it from Apple Music.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 20)

            VStack(spacing: 14) {
                if model.usesMusicApp {
                    StepRow(number: 1, title: "Control Music",
                            detail: "Lipsync plays each song in the Music app, so you get Lossless, Dolby Atmos and your Music settings.",
                            state: model.appleMusic, button: "Allow", action: model.allowAppleMusic)
                } else {
                    StepRow(number: 1, title: "Apple Music",
                            detail: "Plays every song from your Apple Music subscription, in Lossless or Dolby Atmos when your settings allow.",
                            state: model.appleMusic, button: "Allow", action: model.allowAppleMusic)
                }
                StepRow(number: 2, title: "Control Spotify",
                        detail: "Lets Lipsync see what Spotify is playing and keep it in step.",
                        state: model.spotifyControl, button: "Allow", action: model.allowSpotifyControl)
                StepRow(number: 3, title: "Silence Spotify",
                        detail: "macOS will ask to let Lipsync record audio. That's how it mutes Spotify without Spotify knowing. Nothing is recorded or saved.",
                        state: model.mute, button: "Allow", action: model.allowMute)
                VStack(alignment: .leading, spacing: 8) {
                    StepRow(number: 4, title: "Spotify account",
                            detail: "Lets Lipsync see what's queued next, so each song starts with no gap.",
                            state: model.spotifyAccount, button: "Connect", action: model.connectSpotify)
                    if model.needsClientID {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Spotify app client ID", text: $model.clientID)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                            Text("Create an app at developer.spotify.com with redirect URI \(SpotifyAuth.redirectURI), then paste its client ID.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .padding(.leading, 36)
                    }
                }
            }

            Divider().padding(.vertical, 18)

            HStack {
                Toggle("Open Lipsync at login", isOn: $model.openAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Spacer()
                Button("Done", action: model.finish)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canFinish)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

private struct StepRow: View {
    let number: Int
    let title: String
    let detail: String
    let state: SetupModel.StepState
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(state == .done ? Color.green.opacity(0.18) : Color.secondary.opacity(0.14))
                    .frame(width: 24, height: 24)
                if state == .done {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.green)
                } else {
                    Text("\(number)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if case .failed(let message) = state {
                    Text(message).font(.system(size: 11.5)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            switch state {
            case .done:
                EmptyView()
            case .working:
                ProgressView().controlSize(.small).frame(width: 64)
            case .todo, .failed:
                Button(button, action: action).controlSize(.regular).frame(minWidth: 64)
            }
        }
    }
}

@MainActor enum SetupWindow {
    static func make(model: SetupModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SetupView(model: model))
        window.center()
        return window
    }
}
