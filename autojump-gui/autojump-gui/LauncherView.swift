import AppKit
import SwiftUI

struct LauncherView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            inputBar
                .frame(height: 64)
            if !viewModel.results.isEmpty {
                Divider().opacity(0.35)
                resultsList
            }
        }
        .frame(width: 680)
        .frame(maxHeight: 480)
        .onAppear {
            queryFocused = true
        }
    }

    private var inputBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.secondary)
            TextField("Jump to a folder", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .focused($queryFocused)
        }
        .padding(.horizontal, 20)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { index, entry in
                        ResultRow(entry: entry, isSelected: index == viewModel.selection)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.selection = index
                                viewModel.commit()
                            }
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: viewModel.selection) { _, new in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
        }
    }
}

private struct ResultRow: View {
    let entry: AutojumpEntry
    let isSelected: Bool

    var body: some View {
        let url = URL(fileURLWithPath: entry.path)
        HStack(spacing: 12) {
            FolderIcon(path: entry.path)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Text(prettyPath(url))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.28) : Color.clear)
                .padding(.horizontal, 8)
        )
    }

    private func prettyPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

private struct FolderIcon: NSViewRepresentable {
    let path: String

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.image = NSWorkspace.shared.icon(forFile: path)
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.image = NSWorkspace.shared.icon(forFile: path)
    }
}
