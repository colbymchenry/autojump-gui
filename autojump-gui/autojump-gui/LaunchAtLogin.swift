import Foundation
import ServiceManagement

@MainActor
enum LaunchAtLogin {
    static let promptedKey = "LaunchAtLoginPrompted"

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var hasPrompted: Bool {
        UserDefaults.standard.bool(forKey: promptedKey)
    }

    static func markPrompted() {
        UserDefaults.standard.set(true, forKey: promptedKey)
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Result<Void, Error> {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
