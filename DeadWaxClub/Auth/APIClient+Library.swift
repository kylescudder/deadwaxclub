import Foundation

extension APIClient {
    func library<T: Decodable>(_ action: String, _ values: [String: String] = [:]) async throws -> T {
        let data = try await json("api/library/\(action)", values: values)
        return try JSONDecoder().decode(T.self, from: data)
    }

}
