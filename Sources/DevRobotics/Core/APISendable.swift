import Foundation

// API only reads host/token from SettingsStore on demand; allow using it from async contexts
// (Swift 6 strict concurrency) without annotating the original types.
extension API: @unchecked Sendable {}
extension SettingsStore: @unchecked Sendable {}
