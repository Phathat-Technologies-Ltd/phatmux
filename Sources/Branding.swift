import Foundation

/// Central product branding for phatmux (fork of phatmux). File names remain `phatmux*` for upstream mergeability.
enum Branding {
    static let appName = "phatmux"
    static let devAppName = "phatmux DEV"
    static let stagingAppName = "phatmux STAGING"
    static let bundleIdBase = "com.phatmux.app"
    static let directoryName = "phatmux"
    static let socketPrefix = "phatmux"
    static let keychainService = "com.phatmux.app.socket-control"
    static let analyticsProduct = "phatmux"
    static let userAgentProduct = "phatmux"
    static let errorDomainBase = "phatmux"
    static let queueLabelBase = "com.phatmux"
    static let cliExecutableName = "phatmux"
    static let themesReloadNotificationName = "com.phatmux.themes.reload-config"
}
