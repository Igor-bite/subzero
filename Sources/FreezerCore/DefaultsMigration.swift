import Foundation

/// Carries user defaults over from bundle identifiers the app shipped under before.
public enum DefaultsMigration {
    /// Older identifiers, newest first: values from a newer one win.
    public static let legacyDomains = [
        "app.freezer.Freezer",
        "app.karing.Karing",
    ]

    static let doneKey = "legacyDefaultsMigrated"

    /// Copies keys missing in `target` from the legacy domains, once.
    /// - Parameter read: Returns a domain's stored values; injectable for tests.
    public static func run(
        into target: UserDefaults = .standard,
        from domains: [String] = legacyDomains,
        read: (String) -> [String: Any]? = { UserDefaults.standard.persistentDomain(forName: $0) }
    ) {
        guard !target.bool(forKey: doneKey) else { return }
        for domain in domains {
            guard let values = read(domain) else { continue }
            for (key, value) in values where target.object(forKey: key) == nil {
                target.set(value, forKey: key)
            }
        }
        target.set(true, forKey: doneKey)
    }
}
