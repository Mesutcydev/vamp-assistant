import SwiftUI

/// A plan drawn as the list of steps it is — the Mac half of the phone's
/// `RemoteTaskListView`, sharing its parser rules so the same plan reads the
/// same way on both screens.
///
/// A plan arrived as a paragraph in a well: the model wrote five numbered
/// steps and the window printed them as prose, so you approved a wall of text.
struct PlanTaskList: View {
    let title: String
    let items: [PlanTaskItem]

    private var done: Int { items.filter { $0.state == .done }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.9)
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 8)
                Text("\(done) of \(items.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.bottom, 8)

            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(height: 1)
                        .padding(.leading, 26)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    marker(for: item)
                        .frame(width: 16, alignment: .leading)
                    Text(item.text)
                        .font(.callout)
                        .foregroundStyle(item.state == .done ? Theme.textTertiary : Theme.textPrimary)
                        .strikethrough(item.state == .done, color: Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder private func marker(for item: PlanTaskItem) -> some View {
        switch item.state {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
        case .active:
            // The step in flight is the only one carrying the accent.
            Circle()
                .fill(Theme.accentText)
                .frame(width: 7, height: 7)
        case .pending:
            Circle()
                .strokeBorder(Theme.textTertiary, lineWidth: 1.2)
                .frame(width: 7, height: 7)
        }
    }
}

struct PlanTaskItem: Equatable {
    enum State: Equatable { case pending, active, done }
    let text: String
    var state: State = .pending
}

/// Reads a plan out of what the model wrote. Conservative on purpose: most of
/// the lines have to be list items before a block is called a plan, so prose
/// that happens to open with a dash stays prose.
enum PlanTaskParser {
    static func parse(_ text: String) -> [PlanTaskItem]? {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }

        var items: [PlanTaskItem] = []
        for line in lines {
            guard let item = item(from: line) else { continue }
            items.append(item)
        }
        guard items.count >= 2,
              Double(items.count) / Double(lines.count) >= 0.6 else { return nil }

        if let index = items.firstIndex(where: { $0.state == .pending }),
           items.contains(where: { $0.state == .done }) {
            items[index].state = .active
        }
        return items
    }

    private static func item(from line: String) -> PlanTaskItem? {
        var body = line
        guard let bullet = body.range(of: #"^([-*•]|\d+[.)])\s+"#, options: .regularExpression) else {
            return nil
        }
        body.removeSubrange(bullet)

        var state = PlanTaskItem.State.pending
        let lowered = body.lowercased()
        if lowered.hasPrefix("[x]") {
            state = .done
            body = String(body.dropFirst(3))
        } else if body.hasPrefix("[ ]") {
            body = String(body.dropFirst(3))
        }

        let text = body.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : PlanTaskItem(text: text, state: state)
    }
}
