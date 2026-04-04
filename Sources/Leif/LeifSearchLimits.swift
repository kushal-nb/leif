import Foundation

/// Caps for user-typed search strings so filtering / diff highlighting can’t wedge the UI.
enum LeifSearchLimits {
    static let listFilter = 256
    static let diffFind = 256
}

extension String {
    func leifClampedSearch(maxLength: Int = LeifSearchLimits.listFilter) -> String {
        guard count > maxLength else { return self }
        return String(prefix(maxLength))
    }
}
