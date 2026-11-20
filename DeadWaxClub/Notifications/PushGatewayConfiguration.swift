import Foundation

struct PushGatewayConfiguration: Equatable, Sendable {
    let baseURL: URL
    let applicationID: String

    static var fromBundle: PushGatewayConfiguration? {
        from(bundle: .main)
    }

    static func from(bundle: Bundle) -> PushGatewayConfiguration? {
        from(infoDictionary: bundle.infoDictionary ?? [:])
    }

    static func from(infoDictionary: [String: Any]) -> PushGatewayConfiguration? {
        make(
            rawURL: infoDictionary["PUSH_GATEWAY_URL"] as? String,
            applicationID: infoDictionary["PUSH_GATEWAY_APPLICATION_ID"] as? String
        )
    }

    static func make(rawURL: String?, applicationID: String?) -> PushGatewayConfiguration? {
        guard
            let rawURL = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawURL.isEmpty,
            let baseURL = URL(string: rawURL),
            baseURL.scheme?.lowercased() == "https",
            baseURL.host != nil,
            let applicationID = applicationID?.trimmingCharacters(in: .whitespacesAndNewlines),
            applicationID.range(
                of: #"^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$"#,
                options: .regularExpression
            ) != nil
        else { return nil }

        return PushGatewayConfiguration(baseURL: baseURL, applicationID: applicationID)
    }
}
