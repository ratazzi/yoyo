import Foundation

enum ProcessInspector {
    // Read-only diagnostics use this actual signed executable, preserving daemon authentication.
    static func run(arguments: [String]) -> Int32? {
        guard arguments.dropFirst().first == "--inspect-process" else { return nil }
        guard arguments.count == 3, let pid = Int(arguments[2]), pid > 1,
              let configURL = Bundle.main.url(forResource: "lab-config", withExtension: "json"),
              let data = try? Data(contentsOf: configURL),
              let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let directory = config["state_directory"] as? String else {
            FileHandle.standardError.write(Data("Usage: Yoyo --inspect-process PID\n".utf8)); return 2
        }
        let response = TZControl(directory + "/control.sock", ["command": "process", "pid": pid])
            ?? ["error": "Background service unavailable"]
        guard let result = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) else { return 2 }
        FileHandle.standardOutput.write(result + Data("\n".utf8))
        return response["process"] is [String: Any] ? 0 : 1
    }
}
