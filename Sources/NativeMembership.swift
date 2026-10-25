import Foundation
import Security

struct NativeSkin: Decodable, Sendable {
    let id: String
    let name: String
}

struct NativeMembershipSnapshot: Decodable {
    let active: Bool
    let expiresAt: String?
}

private struct NativeActivationResponse: Decodable {
    let token: String
    let expiresAt: String
}

private struct NativeSkinCatalog: Decodable {
    let skins: [NativeSkin]
}

enum NativeMembershipError: LocalizedError {
    case serverNotConfigured
    case invalidServerConfiguration
    case keychainUnavailable
    case invalidActivationCode
    case membershipRequired
    case serviceUnavailable
    case invalidSkinResponse

    var errorDescription: String? {
        switch self {
        case .serverNotConfigured: return "Kroma membership is not configured for this build yet."
        case .invalidServerConfiguration: return "Kroma's membership server address is invalid."
        case .keychainUnavailable: return "Kroma could not store the activation securely in macOS Keychain."
        case .invalidActivationCode: return "This activation code is invalid, expired, or already used."
        case .membershipRequired: return "No active Kroma membership was found for this Mac."
        case .serviceUnavailable: return "Kroma could not verify membership. Check your connection and try again."
        case .invalidSkinResponse: return "Kroma received an invalid skin from its private library."
        }
    }
}

final class NativeMembershipClient {
    private let service = "com.kroma.walletstudio.membership"
    private let fileManager = FileManager.default

    var isConfigured: Bool {
        do { _ = try apiBaseURL(); return true } catch { return false }
    }

    func deviceID() throws -> String {
        if let value = try readKey("device-id") { return value }
        let value = UUID().uuidString.lowercased()
        try writeKey(value, account: "device-id")
        return value
    }

    func activate(code: String) async throws {
        let url = try endpoint("api/native/activate")
        let body: [String: String] = ["code": code, "deviceId": try deviceID()]
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try deviceID(), forHTTPHeaderField: "X-Kroma-Device-ID")
        if let existingToken = try readKey("license-token") {
            request.setValue("Bearer \(existingToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NativeMembershipError.serviceUnavailable }
        guard http.statusCode == 201,
              let payload = try? JSONDecoder().decode(NativeActivationResponse.self, from: data) else {
            if http.statusCode == 400 { throw NativeMembershipError.invalidActivationCode }
            throw NativeMembershipError.serviceUnavailable
        }
        try writeKey(payload.token, account: "license-token")
    }

    func membership() async throws -> NativeMembershipSnapshot {
        guard let token = try readKey("license-token") else {
            return NativeMembershipSnapshot(active: false, expiresAt: nil)
        }
        var request = try authorizedRequest(path: "api/native/membership", token: token)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NativeMembershipError.serviceUnavailable }
        if http.statusCode == 401 { return NativeMembershipSnapshot(active: false, expiresAt: nil) }
        guard http.statusCode == 200,
              let snapshot = try? JSONDecoder().decode(NativeMembershipSnapshot.self, from: data) else {
            throw NativeMembershipError.serviceUnavailable
        }
        return snapshot
    }

    func downloadLibrary() async throws -> [(NativeSkin, URL)] {
        guard let token = try readKey("license-token") else { throw NativeMembershipError.membershipRequired }
        var request = try authorizedRequest(path: "api/native/skins", token: token)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NativeMembershipError.serviceUnavailable }
        guard http.statusCode == 200, let catalog = try? JSONDecoder().decode(NativeSkinCatalog.self, from: data) else {
            if http.statusCode == 401 { throw NativeMembershipError.membershipRequired }
            throw NativeMembershipError.serviceUnavailable
        }
        guard catalog.skins.count <= 250,
              catalog.skins.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 64 && $0.id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil }) else {
            throw NativeMembershipError.invalidSkinResponse
        }

        var result: [(NativeSkin, URL)] = []
        var pending = catalog.skins.makeIterator()
        try await withThrowingTaskGroup(of: (NativeSkin, URL).self) { group in
            for _ in 0..<min(6, catalog.skins.count) {
                if let skin = pending.next() { group.addTask { try await self.download(skin, token: token) } }
            }
            while let item = try await group.next() {
                result.append(item)
                if let skin = pending.next() { group.addTask { try await self.download(skin, token: token) } }
            }
        }
        return result.sorted { $0.0.id.localizedStandardCompare($1.0.id) == .orderedAscending }
    }

    func removeCachedLibrary() {
        guard let folder = try? cacheFolder() else { return }
        try? fileManager.removeItem(at: folder)
    }

    private func download(_ skin: NativeSkin, token: String) async throws -> (NativeSkin, URL) {
        let folder = try cacheFolder()
        let destination = folder.appendingPathComponent("\(skin.id).webp")
        if fileManager.fileExists(atPath: destination.path) {
            if isValidWebP(at: destination) { return (skin, destination) }
            try? fileManager.removeItem(at: destination)
        }

        var request = try authorizedRequest(path: "api/native/skins/\(skin.id)", token: token)
        request.httpMethod = "GET"
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("image/webp") == true else {
            if (response as? HTTPURLResponse)?.statusCode == 401 { throw NativeMembershipError.membershipRequired }
            throw NativeMembershipError.serviceUnavailable
        }
        guard isValidWebP(at: temporaryURL) else { throw NativeMembershipError.invalidSkinResponse }
        try fileManager.moveItem(at: temporaryURL, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return (skin, destination)
    }

    private func isValidWebP(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size > 12, size <= 5 * 1024 * 1024,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count >= 12 else { return false }
        return String(data: data.prefix(4), encoding: .ascii) == "RIFF"
            && String(data: data[8..<12], encoding: .ascii) == "WEBP"
    }

    private func authorizedRequest(path: String, token: String) throws -> URLRequest {
        var request = URLRequest(url: try endpoint(path), timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(try deviceID(), forHTTPHeaderField: "X-Kroma-Device-ID")
        return request
    }

    private func endpoint(_ path: String) throws -> URL {
        try apiBaseURL().appending(path: path)
    }

    private func apiBaseURL() throws -> URL {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "KromaAPIBaseURL") as? String,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeMembershipError.serverNotConfigured }
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw NativeMembershipError.invalidServerConfiguration
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw NativeMembershipError.invalidServerConfiguration
        }
        let currentPath = components.path
        components.path = currentPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let baseURL = components.url else { throw NativeMembershipError.invalidServerConfiguration }
        return baseURL
    }

    private func cacheFolder() throws -> URL {
        guard let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NativeMembershipError.serviceUnavailable
        }
        let folder = root.appendingPathComponent("Kroma/SkinLibrary", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        return folder
    }

    private func readKey(_ account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw NativeMembershipError.keychainUnavailable }
        return value
    }

    private func writeKey(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            for (key, value) in attributes { insert[key] = value }
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw NativeMembershipError.keychainUnavailable }
        } else if status != errSecSuccess {
            throw NativeMembershipError.keychainUnavailable
        }
    }
}
