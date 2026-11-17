import Foundation
import ServiceManagement

public enum LaunchAtLoginHelper {
    public static func setEnabled(_ enabled: Bool) {
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

    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
