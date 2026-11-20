import Foundation

@MainActor
enum AuthAppConfiguration {
    static let callbackScheme = "deadwaxclub"
    static let keychainService = "com.deadwaxclub.app.auth"
    static let initialDisplayNamePath = "api/library/set_initial_display_name"
    static let bootstrapFailureState: AuthClient.State = .unknown
}
