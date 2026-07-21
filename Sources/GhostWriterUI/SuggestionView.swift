import GhostWriterCore
import SwiftUI

public struct SuggestionView: View {
    public enum State: Equatable {
        case working
        case ready(WordDiffBox)
        case failed(String)
    }

    /// `WordDiff` isn't Equatable across its whole shape; box it for SwiftUI.
    public struct WordDiffBox: Equatable {
        public let ops: [WordDiff.Op]
        public let replacement: String
        public init(ops: [WordDiff.Op], replacement: String) {
            self.ops = ops
            self.replacement = replacement
        }
    }

    let state: State
    let onAccept: () -> Void
    let onDismiss: () -> Void

    public init(state: State, onAccept: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.state = state
        self.onAccept = onAccept
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch state {
            case .working:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Rewriting…").foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)

            case let .ready(box):
                diffText(box.ops)
                    .textSelection(.enabled)
                footer

            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    keyHint("esc", "Dismiss")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 460, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }

    private func diffText(_ ops: [WordDiff.Op]) -> some View {
        ops.reduce(Text("")) { acc, op in
            switch op {
            case let .equal(s):
                acc + Text(s).foregroundStyle(.primary)
            case let .insert(s):
                acc + Text(s).foregroundStyle(.green).fontWeight(.medium)
            case let .delete(s):
                acc + Text(s).foregroundStyle(.red).strikethrough()
            }
        }
        .font(.system(size: 13))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()
            keyHint("esc", "Dismiss")
            keyHint("tab", "Accept")
        }
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
