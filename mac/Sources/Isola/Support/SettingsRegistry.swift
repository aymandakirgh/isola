import SwiftUI

/// Feature modules contribute their own settings pages; the Settings module lays
/// them out in the sidebar in `order`, under their `group` (e.g. "notifications").
@MainActor
enum SettingsRegistry {
    struct Section: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let order: Int
        var group: String?
        let view: () -> AnyView
    }

    private(set) static var sections: [Section] = []

    static func add<V: View>(_ id: String, title: String, symbol: String, order: Int, group: String? = nil, @ViewBuilder view: @escaping () -> V) {
        sections.removeAll { $0.id == id }
        sections.append(Section(id: id, title: title, symbol: symbol, order: order, group: group, view: { AnyView(view()) }))
        sections.sort { $0.order < $1.order }
    }
}
