import Combine
import Foundation

final class LauncherViewModel: ObservableObject {
    @Published var query: String = ""
    @Published private(set) var results: [AutojumpEntry] = []
    @Published var selection: Int = 0

    var onSelect: ((String, LaunchModifier?) -> Void)?
    var onDismiss: (() -> Void)?

    private let store: AutojumpStore
    private var cancellables = Set<AnyCancellable>()

    init(store: AutojumpStore) {
        self.store = store
        $query
            .sink { [weak self] newQuery in
                self?.recompute(query: newQuery)
            }
            .store(in: &cancellables)
    }

    func reset() {
        query = ""
        selection = 0
    }

    func moveUp() {
        guard !results.isEmpty else { return }
        selection = max(0, selection - 1)
    }

    func moveDown() {
        guard !results.isEmpty else { return }
        selection = min(results.count - 1, selection + 1)
    }

    func commit(modifier: LaunchModifier? = nil) {
        guard !results.isEmpty, results.indices.contains(selection) else { return }
        onSelect?(results[selection].path, modifier)
    }

    func dismiss() {
        onDismiss?()
    }

    private func recompute(query: String) {
        results = store.search(query: query)
        if selection >= results.count {
            selection = results.isEmpty ? 0 : results.count - 1
        }
    }
}
