import SwiftUI

// Resolves the update script's location at runtime so the app works
// regardless of which Mac, username, or folder it's copied to.
// Preference order:
//   1. "update-sonarr-radarr.sh" sitting next to this .app (lets you edit
//      the script in place without rebuilding the app)
//   2. A copy bundled inside the app's own Resources (so the .app alone
//      is portable even if the sibling script isn't copied along with it)
func resolveScriptPath() -> String? {
    let appURL = Bundle.main.bundleURL
    let siblingURL = appURL.deletingLastPathComponent().appendingPathComponent("update-sonarr-radarr.sh")
    if FileManager.default.fileExists(atPath: siblingURL.path) {
        return siblingURL.path
    }
    if let bundled = Bundle.main.path(forResource: "update-sonarr-radarr", ofType: "sh") {
        return bundled
    }
    return nil
}

// Pulls the actual URL a "<AppName>: Using <url>" line reported, so the
// UI can show what was really resolved rather than guessing independently.
func extractResolvedURL(appName: String, from text: String) -> String? {
    let marker = "\(appName): Using "
    for line in text.split(separator: "\n") {
        if let range = line.range(of: marker) {
            return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}

final class RunnerModel: ObservableObject {
    @Published var output: String = ""
    @Published var isRunning: Bool = false
    @Published var finished: Bool = false
    @Published var sonarrResolvedURL: String?
    @Published var radarrResolvedURL: String?

    private var process: Process?

    func run(sonarrURL: String, radarrURL: String) {
        guard !isRunning else { return }
        output = ""
        finished = false
        isRunning = true
        sonarrResolvedURL = nil
        radarrResolvedURL = nil

        guard let scriptPath = resolveScriptPath() else {
            output = "Couldn't find update-sonarr-radarr.sh.\n\nPlace it next to this app, or rebuild the app to bundle it."
            isRunning = false
            finished = true
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = [scriptPath]

        var env = ProcessInfo.processInfo.environment
        let trimmedSonarr = sonarrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRadarr = radarrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSonarr.isEmpty { env["SONARR_URL"] = trimmedSonarr }
        if !trimmedRadarr.isEmpty { env["RADARR_URL"] = trimmedRadarr }
        proc.environment = env

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
                guard let self else { return }
                self.isRunning = false
                self.finished = true
                self.sonarrResolvedURL = extractResolvedURL(appName: "Sonarr", from: self.output)
                self.radarrResolvedURL = extractResolvedURL(appName: "Radarr", from: self.output)
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
    @AppStorage("sonarrURL") private var sonarrURL: String = ""
    @AppStorage("radarrURL") private var radarrURL: String = ""

    private static let defaultPlaceholder = "Using Auto-detected URL and Port. Enter your own URL & Port to override & select Run Again."

    private var sonarrPlaceholder: String {
        if let resolved = model.sonarrResolvedURL {
            return "Auto-Detected Port & URL from config.xml: \(resolved) | Enter your own URL & Port to override & select Run Again."
        }
        return Self.defaultPlaceholder
    }

    private var radarrPlaceholder: String {
        if let resolved = model.radarrResolvedURL {
            return "Auto-Detected Port & URL from config.xml: \(resolved) | Enter your own URL & Port to override & select Run Again."
        }
        return Self.defaultPlaceholder
    }

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
                    Text("Sonarr-Radarr-Updater for Apple Silicon (M series)")
                        .font(.headline)
                }
                Spacer()
                Button(model.isRunning ? "Running…" : "Run Again") {
                    model.run(sonarrURL: sonarrURL, radarrURL: radarrURL)
                }
                .disabled(model.isRunning)
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sonarr URL")
                    TextField(sonarrPlaceholder, text: $sonarrURL)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Radarr URL")
                    TextField(radarrPlaceholder, text: $radarrURL)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .font(.system(size: 12))
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
        .frame(width: 900, height: 500)
        .onAppear {
            model.run(sonarrURL: sonarrURL, radarrURL: radarrURL)
        }
    }
}

struct UpdaterApp: App {
    var body: some Scene {
        WindowGroup("Sonarr-Radarr-Updater for Apple Silicon (M series)") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

UpdaterApp.main()
