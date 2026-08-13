import Foundation
import ServiceManagement

enum LaunchAtLoginHelper {
    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Launch at login error: \(error.localizedDescription)")
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
