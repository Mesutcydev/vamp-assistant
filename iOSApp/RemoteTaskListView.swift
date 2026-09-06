import SwiftUI

/// A plan, drawn as the list of steps it is.
///
/// Plans arrived as a paragraph: the model wrote five numbered steps, the
/// phone printed them as one run of prose in an approval card, and you
/// approved a wall of text. A plan is a list — of things that have not
/// happened yet, one that may be happening now, and ones that are done — so
/// it is drawn as one, and the header says how far along it is.
struct RemoteTaskListView: View {
    let title: String
    let items: [RemoteTaskItem]
    @Environment(\.remoteAppearance) private var appearance

    private var done: Int { items.filter { $0.state == .done }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.9)
                    .foregroundStyle(.primary.opacity(0.55))
                Spacer(minLength: 8)
                Text("\(done) of \(items.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.primary.opacity(0.45))
            }
            .padding(.bottom, 8)

            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(RemoteSurface.separator(appearance))
                        .frame(height: 0.75)
                        .padding(.leading, 28)
                }
                RemoteTaskRow(item: item)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(done) of \(items.count) done")
    }
}

private struct RemoteTaskRow: View {
    let item: RemoteTaskItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            marker
                .frame(width: 18, alignment: .leading)
            Text(item.text)
                .font(.subheadline)
                .foregroundStyle(foreground)
                .strikethrough(item.state == .done, color: .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 9)
    }

    @ViewBuilder private var marker: some View {
        switch item.state {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
        case .active:
            // The step in flight is the only one with the accent on it.
            Circle()
                .fill(BeetTheme.accentBright)
                .frame(width: 7, height: 7)
                .padding(.leading, 2)
        case .pending:
            Circle()
                .strokeBorder(.tertiary, lineWidth: 1.2)
                .frame(width: 7, height: 7)
                .padding(.leading, 2)
        }
    }

    private var foreground: some ShapeStyle {
        switch item.state {
        case .done: AnyShapeStyle(HierarchicalShapeStyle.secondary)
        case .active: AnyShapeStyle(HierarchicalShapeStyle.primary)
        case .pending: AnyShapeStyle(Color.primary.opacity(0.78))
        }
    }
}

struct RemoteTaskItem: Equatable {
    enum State: Equatable { case pending, active, done }
    let text: String
    var state: State = .pending
}

/// Reads a plan out of what the model wrote.
///
/// Deliberately conservative: it only claims a block of text is a plan when
/// most of its lines are list items, so ordinary prose that happens to open
/// with a dash is still prose.
enum RemoteTaskListParser {
    static func parse(_ text: String) -> [RemoteTaskItem]? {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }

        var items: [RemoteTaskItem] = []
        var listLines = 0
        for line in lines {
            guard let item = item(from: line) else { continue }
            listLines += 1
            items.append(item)
        }
        guard items.count >= 2,
              Double(listLines) / Double(lines.count) >= 0.6 else { return nil }

        // Nothing marks the step in flight, so the first unfinished one is it —
        // which is what a reader assumes anyway.
        if let index = items.firstIndex(where: { $0.state == .pending }),
           items.contains(where: { $0.state == .done }) {
            items[index].state = .active
        }
        return items
    }

    /// The strict door, for the transcript: a message only becomes a task list
    /// when it actually writes checkboxes. Plenty of good answers are bulleted
    /// without being a plan, and turning those into checklists would be the
    /// client inventing state the model never claimed.
    static func checklist(_ text: String) -> [RemoteTaskItem]? {
        guard text.contains("[ ]") || text.lowercased().contains("[x]") else { return nil }
        return parse(text)
    }

    private static func item(from line: String) -> RemoteTaskItem? {
        var body = line
        var state = RemoteTaskItem.State.pending

        if let match = body.range(of: #"^([-*•]|\d+[.)])\s+"#, options: .regularExpression) {
            body.removeSubrange(match)
        } else {
            return nil
        }

        let lowered = body.lowercased()
        if lowered.hasPrefix("[x] ") || lowered.hasPrefix("[x]") {
            state = .done
            body = String(body.dropFirst(3))
        } else if body.hasPrefix("[ ] ") || body.hasPrefix("[ ]") {
            body = String(body.dropFirst(3))
        }

        let text = body.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : RemoteTaskItem(text: text, state: state)
    }
}
