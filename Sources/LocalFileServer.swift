import AppKit
import Foundation

final class LocalFileServer {
    static let shared = LocalFileServer()

    private struct Entry {
        let process: Process
        let port: Int
        let rootPath: String
    }

    private var servers: [String: Entry] = [:]
    private let queue = DispatchQueue(label: "com.cmux.local-file-server")
    private var nextPort = 18900

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    func openInBrowser(filePath: String, rootPath: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let port = self.ensureServer(for: rootPath)
            guard port > 0 else { return }

            var relativePath = filePath
            if relativePath.hasPrefix(rootPath) {
                relativePath = String(relativePath.dropFirst(rootPath.count))
            }
            if !relativePath.hasPrefix("/") {
                relativePath = "/" + relativePath
            }

            guard let encoded = relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "http://127.0.0.1:\(port)\(encoded)") else {
                return
            }
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func stopAll() {
        queue.sync {
            for (_, entry) in servers {
                if entry.process.isRunning {
                    entry.process.terminate()
                }
            }
            servers.removeAll()
        }
    }

    // MARK: - Private

    private func ensureServer(for rootPath: String) -> Int {
        if let existing = servers[rootPath], existing.process.isRunning {
            return existing.port
        }
        servers.removeValue(forKey: rootPath)

        let usedPorts = Set(servers.values.map(\.port))

        for _ in 0..<100 {
            let port = allocatePort()
            if usedPorts.contains(port) { continue }
            if let entry = tryStartServer(port: port, rootPath: rootPath) {
                servers[rootPath] = entry
                return port
            }
        }
        return 0
    }

    private func tryStartServer(port: Int, rootPath: String) -> Entry? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1"]
        process.currentDirectoryURL = URL(fileURLWithPath: rootPath)
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe

        let capturedRoot = rootPath
        process.terminationHandler = { [weak self] _ in
            self?.queue.async {
                self?.servers.removeValue(forKey: capturedRoot)
            }
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        // Wait briefly and check if the process is still alive (port bind failure
        // causes immediate exit).
        Thread.sleep(forTimeInterval: 0.3)

        guard process.isRunning else {
            return nil
        }

        return Entry(process: process, port: port, rootPath: rootPath)
    }

    private func allocatePort() -> Int {
        let port = nextPort
        nextPort += 1
        if nextPort > 18999 { nextPort = 18900 }
        return port
    }

    @objc private func appWillTerminate() {
        stopAll()
    }
}
