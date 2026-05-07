import Combine
import Foundation

final class LauncherViewModel: ObservableObject {
    @Published var query: String = "" {
        didSet { recompute() }
    }
    @Published private(set) var results: [AutojumpEntry] = []
    @Published var selection: Int = 0

    var onSelect: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    private let store: AutojumpStore

    init(store: AutojumpStore) {
        self.store = store
    }

    func reset() {
        query = ""
        selection = 0
        recompute()
    }

    func moveUp() {
        guard !results.isEmpty else { return }
        selection = max(0, selection - 1)
    }

    func moveDown() {
        guard !results.isEmpty else { return }
        selection = min(results.count - 1, selection + 1)
    }

    func commit() {
        guard !results.isEmpty, results.indices.contains(selection) else { return }
        onSelect?(results[selection].path)
    }

    func dismiss() {
        onDismiss?()
    }

    private func recompute() {
        results = store.search(query: query)
        if selection >= results.count {
            selection = results.isEmpty ? 0 : results.count - 1
        }
    }
}
