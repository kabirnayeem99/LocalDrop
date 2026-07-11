import Foundation
import ServiceManagement

protocol LoginItemManaging: Sendable {
    func register() throws
    func unregister() throws
    var isRegistered: Bool { get }
}

struct SMAppServiceLoginItemManager: LoginItemManaging {
    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
