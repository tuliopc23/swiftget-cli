import Foundation

class ConfigurationManager {
    private let configURL: URL
    private var config: [String: Any] = [:]
    
    init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let configDir = homeDir.appendingPathComponent(".config/swiftget")
        self.configURL = configDir.appendingPathComponent("config.json")
        
        loadConfiguration()
    }
    
    func showConfiguration() {
        print("SwiftGet Configuration:")
        print("Config file: \(configURL.path)")
        print()
        
        if config.isEmpty {
            print("No configuration settings found.")
        } else {
            for (key, value) in config.sorted(by: { $0.key < $1.key }) {
                print("\(key) = \(value)")
            }
        }
    }
    
    func setConfiguration(_ setting: String) throws {
        let parts = setting.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else {
            throw ConfigurationError.invalidFormat("Format should be 'key=value'")
        }
        
        let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
        
        // Validate known configuration keys
        guard isValidConfigurationKey(key) else {
            throw ConfigurationError.unknownKey(key)
        }
        
        config[key] = parseValue(value)
        try saveConfiguration()
        
        print("Set \(key) = \(value)")
    }
    
    func getValue<T>(_ key: String, defaultValue: T) -> T {
        return config[key] as? T ?? defaultValue
    }
    
    private func loadConfiguration() {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return
        }
        
        do {
            let data = try Data(contentsOf: configURL)
            if let loadedConfig = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                config = loadedConfig
            }
        } catch {
            print("Warning: Failed to load configuration: \(error)")
        }
    }
    
    private func saveConfiguration() throws {
        let configDir = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        
        let data = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
        try data.write(to: configURL)
    }
    
    private func isValidConfigurationKey(_ key: String) -> Bool {
        let validKeys = [
            "default-directory",
            "default-connections",
            "default-user-agent",
            "max-speed",
            "proxy",
            "check-certificate",
            "auto-extract",
            "show-progress",
            "quiet",
            "verbose"
        ]
        return validKeys.contains(key)
    }
    
    private func parseValue(_ value: String) -> Any {
        // Try to parse as boolean
        if value.lowercased() == "true" {
            return true
        } else if value.lowercased() == "false" {
            return false
        }
        
        // Try to parse as integer
        if let intValue = Int(value) {
            return intValue
        }
        
        // Return as string
        return value
    }
}

enum ConfigurationError: Error, LocalizedError {
    case invalidFormat(String)
    case unknownKey(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidFormat(let message):
            return "Invalid format: \(message)"
        case .unknownKey(let key):
            return "Unknown configuration key: \(key)"
        }
    }
}