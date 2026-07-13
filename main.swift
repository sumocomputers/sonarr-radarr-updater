import SwiftUI

// Resolves the update script's location at runtime so the app works
// regardless of which Mac, username, or folder it's copied to.
// Preference order:
//   1. "update-servarr.sh" sitting next to this .app (lets you edit the
//      script in place without rebuilding the app)
//   2. A copy bundled inside the app's own Resources (so the .app alone
//      is portable even if the sibling script isn't copied along with it)
func resolveScriptPath() -> String? {
    let appURL = Bundle.main.bundleURL
    let siblingURL = appURL.deletingLastPathComponent().appendingPathComponent("update-servarr.sh")
    if FileManager.default.fileExists(atPath: siblingURL.path) {
        return siblingURL.path
    }
    if let bundled = Bundle.main.path(forResource: "update-servarr", ofType: "sh") {
        return bundled
    }
    return nil
}

final class RunnerModel: ObservableObject {
    @Published var output: String = ""
    @Published var isRunning: Bool = false
    @Published var finished: Bool = false

    private var process: Process?

    func run() {
        guard !isRunning else { return }
        output = ""
        finished = false
        isRunning = true

        guard let scriptPath = resolveScriptPath() else {
            output = "Couldn't find update-servarr.sh.\n\nPlace it next to this app, or rebuild the app to bundle it."
            isRunning = false
            finished = true
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = [scriptPath]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.output += str
            }
        }

        proc.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.finished = true
            }
        }

        self.process = proc

        do {
            try proc.run()
        } catch {
            output += "\nFailed to launch script: \(error.localizedDescription)\n"
            isRunning = false
            finished = true
        }
    }
}

struct ContentView: View {
    @StateObject private var model = RunnerModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if model.isRunning {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 4)
                    Text("Checking for updates…")
                        .font(.headline)
                } else if model.finished {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Done")
                        .font(.headline)
                } else {
                    Text("Sonarr / Radarr Updater")
                        .font(.headline)
                }
                Spacer()
                Button(model.isRunning ? "Running…" : "Run Again") {
                    model.run()
                }
                .disabled(model.isRunning)
            }
            .padding()

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.output.isEmpty ? "Waiting to start…" : model.output)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("outputEnd")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: model.output) { _, _ in
                    proxy.scrollTo("outputEnd", anchor: .bottom)
                }
            }
        }
        .frame(width: 640, height: 420)
        .onAppear {
            model.run()
        }
    }
}

struct UpdaterApp: App {
    var body: some Scene {
        WindowGroup("Sonarr / Radarr Updater") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

UpdaterApp.main()
