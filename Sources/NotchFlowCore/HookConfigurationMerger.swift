import Foundation

public enum HookConfigurationMerger {
    public static func removingOwnedHandlers(
        from groups: [[String: Any]],
        commandMarker: String
    ) -> [[String: Any]] {
        groups.compactMap { group in
            var updated = group
            let handlers = (group["hooks"] as? [[String: Any]] ?? []).filter {
                ($0["command"] as? String)?.contains(commandMarker) != true
            }
            guard !handlers.isEmpty else { return nil }
            updated["hooks"] = handlers
            return updated
        }
    }
}
