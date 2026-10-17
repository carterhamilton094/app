import Foundation
import Security

// Only the opaque backend session is stored on the device. Strava secrets stay on the server.
enum SessionStore {
    static let service = "com.runways.session"
    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String?) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
        if let value {
            var item = query
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}
struct API {
    let base: URL
    let token: String
    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        parts.queryItems = query
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 180
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let failure = try? JSONDecoder().decode(APIFailure.self, from: data)
            throw NSError(domain: "Runways", code: 1, userInfo: [NSLocalizedDescriptionKey: failure?.error ?? "The request failed. Please try again."])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private struct APIFailure: Decodable { let error: String }
