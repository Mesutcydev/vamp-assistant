import AppKit
import SwiftUI

/// Compact document bar for the active conversation. It is a separate view so
/// streaming transcript updates do not rebuild toolbar/menu structure.
struct ChatHeaderView: View {
    let title: String
    let phaseLabel: String
    let phaseTint: Color
    let canReview: Bool
    let onHome: () -> Void
    let onNewChat: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .accessibilityHidden(true)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accentText)
                .frame(width: 24, height: 24)
                .background(
                    Theme.wash(Theme.accent),
                    in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Button(action: onHome) {
                    Image(systemName: "house")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .lfHoverLift()
                .help("Back to home")
                .accessibilityLabel("Back to home")

                Button(action: onNewChat) {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                .buttonStyle(LFCapsuleButtonStyle())
                .lfHoverLift()
                .help("Start a new chat")
            }
            ChatHeaderActions(canReview: canReview)
            ChatPhaseBadge(label: phaseLabel, tint: phaseTint)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(Theme.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline.opacity(0.7)).frame(height: 1)
        }
    }

}

struct ChatHeaderActions: View {
    let canReview: Bool

    var body: some View {
        HStack(spacing: 7) {
            Button {
                post(.openRemoteAccess)
            } label: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .fixedSize()
            .lfHoverLift()
            .help("Control this chat from iPhone or iPad")
            .accessibilityLabel("Start remote control for this chat")

            Button {
                post(.gitDiff)
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .fixedSize()
            .lfHoverLift()
            .help("Review changed files")
            .accessibilityLabel("Review changed files")
            .disabled(!canReview)

            InstrumentMenu(menuWidth: 260) {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Theme.surfaceInset, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
            } options: {
                InstrumentMenuRow(title: "Browser", systemImage: "safari", action: { post(.toggleBrowserPanel) })
                InstrumentMenuRow(title: "Simulator", systemImage: "iphone", action: { post(.toggleSimulatorPanel) })
                InstrumentMenuRow(title: "Diagnostics", systemImage: "stethoscope", action: { post(.toggleDiagnosticsPanel) })
                InstrumentMenuRow(title: "Git status", systemImage: "circle.dashed",
                                  isDisabled: !canReview, action: { post(.gitStatus) })
                InstrumentMenuRow(title: "Review changes", systemImage: "doc.text.magnifyingglass",
                                  isDisabled: !canReview, action: { post(.gitDiff) })
                InstrumentMenuRow(title: "Undo last checkpoint", systemImage: "arrow.uturn.backward",
                                  isDisabled: !canReview, action: { post(.undoCheckpoint) })
                InstrumentMenuRow(title: "Export as Markdown…", systemImage: "doc.text", action: { post(.exportChatMarkdown) })
                InstrumentMenuRow(title: "Export as JSON…", systemImage: "curlybraces.square", action: { post(.exportChatJSON) })
                InstrumentMenuRow(title: "Export task bundle…", systemImage: "shippingbox", action: { post(.exportTaskBundle) })
            }
            .fixedSize()
            .lfHoverLift()
            .help("More workspace actions")
            .accessibilityLabel("More workspace actions")
        }
    }

    private func post(_ notification: Notification.Name) {
        NotificationCenter.default.post(name: notification, object: nil)
    }
}

struct ChatPhaseBadge: View {
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 24)
        .background(Theme.wash(tint), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Chat phase")
        .accessibilityValue(label)
    }
}

/// User message: short prompts are a right-aligned bubble (reference-client
/// pattern); long or multiline messages become a full-width left-aligned
/// card. The fill is the raised inset surface with a quiet hairline — a
/// calm dark bubble, never an accent wash.
struct UserBubble: View {
    let item: AgentSessionController.TranscriptItem

    private static func isLongForm(_ text: String) -> Bool {
        text.contains("\n") || text.count > 280
    }

    var body: some View {
        if case .user(let text) = item.kind {
            if Self.isLongForm(text) {
                HStack {
                    Text(text)
                        .font(AppFont.chatUserBody)
                        .lineSpacing(2)
                        .tracking(-0.1)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous)
                            .strokeBorder(Theme.hairline.opacity(0.55), lineWidth: 0.75))
                        .frame(maxWidth: ContentColumn.maxWidth * 0.7, alignment: .leading)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            } else {
                HStack {
                    Spacer()
                    Text(text)
                        .font(AppFont.chatUserBody)
                        .lineSpacing(2)
                        .tracking(-0.1)
                        .foregroundStyle(Color.white.opacity(0.92))
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Instrument.darkInsert.opacity(0.92),
                                    in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
                        .frame(maxWidth: ContentColumn.maxWidth * 0.7, alignment: .trailing)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// Assistant output: plain full-column prose with block-aware markdown —
/// lists, headings, and code blocks read like an answer. No avatar or
/// bubble: the reference client keeps assistant text bare.
struct AssistantMessage: View {
    let item: AgentSessionController.TranscriptItem

    var body: some View {
        if case .assistant(let text) = item.kind {
            VStack(alignment: .leading, spacing: 12) {
                MarkdownText(text: text)
                AnswerFooterRow(text: text, metrics: item.answerMetrics)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }
}

/// Quiet, standard answer actions. The useful generation details stay close
/// to the response, while copy feedback is visible without a toast or modal.
struct AnswerFooterRow: View {
    let text: String
    let metrics: AnswerMetrics?
    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 9) {
            if let metrics {
                AnswerMetadataRow(metrics: metrics)
            }
            if metrics != nil {
                Text("·")
                    .foregroundStyle(Theme.hairline)
                    .accessibilityHidden(true)
            }
            Button(action: copyAnswer) {
                Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
                    .foregroundStyle(didCopy ? Theme.success : Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Copy answer")
            .accessibilityLabel(didCopy ? "Answer copied" : "Copy answer")
        }
        .frame(minHeight: 18)
    }

    private func copyAnswer() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }
}

/// Neutral identity slot used until the final Vamp icon pass.
struct AssistantAvatar: View {
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: "sparkles")
            .font(.app(size: size * 0.46, weight: .semibold))
            .foregroundStyle(Theme.rose)
            .frame(width: size, height: size)
            .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .shadow(color: Theme.accent.opacity(0.35), radius: 6, y: 2)
            .accessibilityHidden(true)
    }
}

/// Codex-style block markdown. SwiftUI's single `Text(AttributedString)`
/// flattens paragraph presentation intent, so every semantic block gets its
/// own layout row: real paragraph rhythm, properly indented lists, distinct
/// headings, quotes, and horizontally scrollable code.
struct MarkdownText: View {
    let text: String

    var body: some View {
        let displayText = AssistantAnswerFormatter.formattedForDisplay(text)
        let blocks = MarkdownDocumentParser.blocks(from: displayText)

        VStack(alignment: .leading, spacing: 16) {
            ForEach(blocks) { block in
                MarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AnswerMetadataRow: View {
    let metrics: AnswerMetrics

    var body: some View {
        HStack(spacing: 7) {
            Label(tokenLabel, systemImage: "text.word.spacing")
            if let speed = metrics.tokensPerSecond {
                separator
                Label(String(format: "%.1f tok/s", speed), systemImage: "speedometer")
            }
            separator
            Label(durationLabel, systemImage: "clock")
        }
        .font(.caption2)
        .foregroundStyle(Theme.textTertiary)
        .monospacedDigit()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var tokenLabel: String {
        (metrics.tokenCountIsEstimated ? "≈" : "")
            + metrics.outputTokens.formatted()
            + " tokens"
    }

    private var durationLabel: String {
        if metrics.elapsedSeconds < 60 {
            return String(format: "%.1fs", metrics.elapsedSeconds)
        }
        let minutes = Int(metrics.elapsedSeconds) / 60
        let seconds = Int(metrics.elapsedSeconds) % 60
        return "\(minutes)m \(seconds)s"
    }

    private var accessibilitySummary: String {
        var parts = [tokenLabel]
        if let speed = metrics.tokensPerSecond {
            parts.append(String(format: "%.1f tokens per second", speed))
        }
        parts.append("\(durationLabel) elapsed")
        return parts.joined(separator: ", ")
    }

    private var separator: some View {
        Text("·")
            .foregroundStyle(Theme.hairline)
            .accessibilityHidden(true)
    }
}

struct MarkdownBlock: Identifiable, Equatable {
    enum Content: Equatable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case bullets([String])
        case numbers([String])
        case quote(String)
        case code(language: String?, text: String)
        case table(headers: [String], rows: [[String]])
        case divider
    }

    let id: Int
    let content: Content
}

enum MarkdownDocumentParser {
    static func blocks(from source: String) -> [MarkdownBlock] {
        var contents: [MarkdownBlock.Content] = []
        var paragraph: [String] = []
        var listItems: [String] = []
        var listIsNumbered = false
        var codeLines: [String] = []
        var codeLanguage: String?
        var insideCode = false
        var tableHeaders: [String]?
        var tableRows: [[String]] = []

        func tableCells(_ line: String) -> [String] {
            var body = line.trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("|") { body.removeFirst() }
            if body.hasSuffix("|") { body.removeLast() }
            return body.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }

        func isTableSeparator(_ line: String) -> Bool {
            let cells = tableCells(line)
            return cells.count >= 2 && cells.allSatisfy { cell in
                let stripped = cell.replacingOccurrences(of: ":", with: "")
                return stripped.count >= 3 && stripped.allSatisfy { $0 == "-" }
            }
        }

        func flushTable() {
            guard let headers = tableHeaders else { return }
            contents.append(.table(headers: headers, rows: tableRows))
            tableHeaders = nil
            tableRows.removeAll(keepingCapacity: true)
        }

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            contents.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll(keepingCapacity: true)
        }

        func flushList() {
            guard !listItems.isEmpty else { return }
            contents.append(listIsNumbered ? .numbers(listItems) : .bullets(listItems))
            listItems.removeAll(keepingCapacity: true)
        }

        func flushProse() {
            flushTable()
            flushParagraph()
            flushList()
        }

        for rawLine in source.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if insideCode {
                if line.hasPrefix("```") {
                    contents.append(.code(
                        language: codeLanguage,
                        text: codeLines.joined(separator: "\n")))
                    codeLines.removeAll(keepingCapacity: true)
                    codeLanguage = nil
                    insideCode = false
                } else {
                    codeLines.append(rawLine)
                }
                continue
            }

            if line.hasPrefix("```") {
                flushProse()
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                codeLanguage = language.isEmpty ? nil : language
                insideCode = true
            } else if isTableSeparator(line), let header = paragraph.last,
                      header.contains("|") {
                paragraph.removeLast()
                flushParagraph()
                flushList()
                tableHeaders = tableCells(header)
            } else if tableHeaders != nil, line.contains("|") {
                tableRows.append(tableCells(line))
            } else if line.isEmpty {
                flushProse()
            } else if isDivider(line) {
                flushProse()
                contents.append(.divider)
            } else if let heading = heading(in: line) {
                flushProse()
                contents.append(.heading(level: heading.level, text: heading.text))
            } else if isStandaloneLabel(line) {
                flushProse()
                contents.append(.heading(level: 3, text: String(line.dropLast())))
            } else if let item = bulletItem(in: line) {
                flushParagraph()
                if !listItems.isEmpty, listIsNumbered { flushList() }
                listIsNumbered = false
                listItems.append(item)
            } else if let item = numberedItem(in: line) {
                flushParagraph()
                if !listItems.isEmpty, !listIsNumbered { flushList() }
                listIsNumbered = true
                listItems.append(item)
            } else if line.hasPrefix(">") {
                flushProse()
                contents.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                flushList()
                paragraph.append(line)
            }
        }

        if insideCode {
            contents.append(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
        } else {
            flushProse()
        }

        if contents.isEmpty, !source.isEmpty { contents = [.paragraph(source)] }
        return contents.enumerated().map { MarkdownBlock(id: $0.offset, content: $0.element) }
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count), line.dropFirst(hashes.count).first == " " else {
            return nil
        }
        return (
            hashes.count,
            String(line.dropFirst(hashes.count + 1)).trimmingCharacters(in: .whitespaces))
    }

    private static func isStandaloneLabel(_ line: String) -> Bool {
        line.hasSuffix(":") && line.count <= 48 && !line.dropLast().contains(where: { ".!?".contains($0) })
    }

    private static func isDivider(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        let compact = line.filter { !$0.isWhitespace }
        guard let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func bulletItem(in line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    private static func numberedItem(in line: String) -> String? {
        guard let period = line.firstIndex(of: "."),
              Int(line[..<period]) != nil else { return nil }
        let remainder = line[line.index(after: period)...]
        guard remainder.first == " " else { return nil }
        return String(remainder.dropFirst())
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block.content {
        case .paragraph(let text):
            inline(text)
                .font(AppFont.chatBody)
                .lineSpacing(4)
                .tracking(-0.1)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            inline(text)
                .font(headingFont(level))
                .fixedSize(horizontal: false, vertical: true)

        case .bullets(let items):
            list(items: items, numbered: false)

        case .numbers(let items):
            list(items: items, numbered: true)

        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Theme.hairline)
                    .frame(width: 2)
                inline(text)
                    .font(AppFont.chatBody)
                    .lineSpacing(5)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 6) {
                if let language {
                    Text(language)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(verbatim: text)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                }
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1))

        case .table(let headers, let rows):
            ScrollView(.horizontal, showsIndicators: true) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(headers.indices, id: \.self) { index in
                            tableCell(headers[index], emphasized: true)
                        }
                    }
                    ForEach(rows.indices, id: \.self) { rowIndex in
                        GridRow {
                            ForEach(headers.indices, id: \.self) { columnIndex in
                                tableCell(rows[rowIndex].indices.contains(columnIndex)
                                    ? rows[rowIndex][columnIndex] : "", emphasized: false)
                            }
                        }
                    }
                }
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1))
            }

        case .divider:
            Divider()
                .overlay(Theme.hairline.opacity(0.75))
                .padding(.vertical, 2)
        }
    }

    private func tableCell(_ source: String, emphasized: Bool) -> some View {
        inline(source)
            .font(.appProse(size: 13.5 * CGFloat(Theme.currentTextSize.scale),
                          weight: emphasized ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minWidth: 120, alignment: .leading)
            .background(emphasized ? Theme.surfaceInset.opacity(0.72) : Color.clear)
            .overlay(alignment: .trailing) {
                Rectangle().fill(Theme.hairline.opacity(0.7)).frame(width: 1)
            }
    }

    private func inline(_ source: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed).foregroundStyle(Theme.textPrimary)
        }
        return Text(source).foregroundStyle(Theme.textPrimary)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .appProse(size: 22 * CGFloat(Theme.currentTextSize.scale), weight: .bold)
        case 2: AppFont.chatHeading
        default: .appProse(size: 16 * CGFloat(Theme.currentTextSize.scale), weight: .semibold)
        }
    }

    private func list(items: [String], numbered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(numbered ? "\(index + 1)." : "•")
                        .font(.appProse(size: 16 * CGFloat(Theme.currentTextSize.scale),
                                      weight: numbered ? .regular : .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 20, alignment: .trailing)
                    inline(item)
                        .font(AppFont.chatBody)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Checkpoint + notice lines: quiet, centered, never shouting.
struct MetaRow: View {
    let item: AgentSessionController.TranscriptItem

    var body: some View {
        switch item.kind {
        case .checkpoint(let checkpoint):
            Label("Checkpoint saved — \(checkpoint.summary)", systemImage: "camera.fill")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        case .notice(let text):
            if text.hasPrefix("Codex plan\n") {
                PlanSnapshotCard(text: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        default:
            EmptyView()
        }
    }
}

/// One compact work log for a consecutive agent run. Cursor/Codex-style
/// activity grouping keeps reasoning and tool plumbing available for trust
/// and debugging without letting it compete with the final answer.
struct AgentActivityCard: View {
    let items: [AgentSessionController.TranscriptItem]
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasFailure: Bool {
        items.contains { if case .toolResult(_, _, let failed, _) = $0.kind { return failed }; return false }
    }

    /// Result status keyed by invocation id, so each call row carries its
    /// own outcome without duplicating the result row beneath it.
    private var failedResultIDs: Set<UUID> {
        Set(items.compactMap { item in
            if case .toolResult(let id, _, let failed, _) = item.kind, failed { return id }
            return nil
        })
    }

    /// One compact presentation row per event. Raw arguments, results, and
    /// reasoning stay behind the Details disclosure (ActivityRow below).
    private struct ActivityEntry: Identifiable {
        let id: UUID
        let icon: String
        let verb: String
        let summary: String
        let failed: Bool
    }

    private var compactEntries: [ActivityEntry] {
        var entries: [ActivityEntry] = []
        for item in items {
            switch item.kind {
            case .toolCall(let invocation):
                entries.append(ActivityEntry(
                    id: item.id,
                    icon: Self.icon(for: invocation.name),
                    verb: Self.verb(for: invocation.name),
                    summary: invocation.summary,
                    failed: failedResultIDs.contains(invocation.id)))
            case .reasoning(let text):
                // Consecutive reasoning events are one reading unit: merge
                // them into a single row instead of stacking repeated
                // fragments. The stored transcript is never mutated.
                if let last = entries.last, last.verb == "think" {
                    continue
                }
                entries.append(ActivityEntry(
                    id: item.id,
                    icon: "brain.head.profile",
                    verb: "think",
                    summary: Self.reasoningPreview(text),
                    failed: false))
            case .toolResult(_, _, let failed, _):
                // The call row already carries the outcome; a failed result
                // with no visible call still deserves its own row.
                if failed {
                    entries.append(ActivityEntry(
                        id: item.id,
                        icon: "exclamationmark.triangle",
                        verb: "result",
                        summary: "Failed",
                        failed: true))
                }
            default:
                break
            }
        }
        return entries
    }

    /// Plain-language preview for the compact reasoning row: markdown
    /// emphasis markers, backticks, and heading hashes never belong in a
    /// one-line summary. Collapses whitespace and keeps the first sentence.
    static func reasoningPreview(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Fenced blocks collapse to a pointer — never dump code into a row.
        if let range = text.range(of: "```") {
            text = String(text[..<range.lowerBound])
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                text = "Worked through code"
            }
        }
        text = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
        // Strip heading hashes at line starts, then flatten newlines so the
        // one-line row shows a single flowing sentence.
        text = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " #*")) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if let firstSentence = text.range(of: ". ") {
            text = String(text[..<firstSentence.lowerBound]) + "."
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Reasoning summary" : trimmed
    }

    private static func verb(for name: String) -> String {
        switch name {
        case "read_file", "list_directory", "search", "find_files", "glob":
            name == "search" ? "grep" : "read"
        case "write_file", "move_file", "apply_patch":
            "edit"
        case "run_command":
            "run"
        case "build_diagnostics":
            "build"
        case "sim_build_run":
            "build"
        case "macos_build_run":
            "build"
        case "apple_ship":
            "ship"
        case "task":
            "delegate"
        default:
            name.replacingOccurrences(of: "_", with: " ")
        }
    }

    private static func icon(for name: String) -> String {
        switch name {
        case "search": "magnifyingglass"
        case "read_file", "list_directory", "find_files", "glob": "doc.text"
        case "write_file", "move_file", "apply_patch": "pencil"
        case "run_command": "terminal"
        case "build_diagnostics", "sim_build_run", "macos_build_run": "hammer"
        case "apple_ship": "shippingbox"
        case "task": "person.crop.circle"
        default: "wrench.and.screwdriver"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Capsule()
                .fill(hasFailure ? Theme.negative.opacity(0.7) : Instrument.seam.opacity(0.6))
                .frame(width: 2)
                .padding(.leading, 2)
                .padding(.top, 7)
                .padding(.bottom, 7)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(compactEntries) { entry in
                    compactRow(entry)
                }

                Button {
                    if reduceMotion {
                        expanded.toggle()
                    } else {
                        withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
                    }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text(expanded ? "Hide details" : "Details")
                            .font(.app(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: 27, alignment: .leading)
                .padding(.leading, 14)
                .help(expanded ? "Hide reasoning and tool output" : "Show reasoning and tool output")

                if expanded {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(items) { item in
                            ActivityRow(item: item)
                        }
                    }
                    .padding(.leading, 14)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent activity")
    }

    private func compactRow(_ entry: ActivityEntry) -> some View {
        HStack(spacing: 9) {
            Image(systemName: entry.failed ? "exclamationmark.circle.fill" : entry.icon)
                .accessibilityHidden(true)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(entry.failed ? Theme.negative : Theme.textTertiary)
                .frame(width: 16, height: 16)
            Text(entry.verb)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
            Text(entry.summary)
                .font(.app(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 27)
        .padding(.leading, 14)
        .contentShape(Rectangle())
    }
}

/// One event inside the activity disclosure. Prose uses the system face;
/// only commands and raw output use SF Mono.
struct ActivityRow: View {
    let item: AgentSessionController.TranscriptItem
    @State private var outputExpanded = false

    var body: some View {
        switch item.kind {
        case .toolCall(let invocation):
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .accessibilityHidden(true)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                Text(invocation.name)
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(Theme.textPrimary)
                Text(invocation.summary)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .toolResult(_, let output, let failed, let toolName):
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    outputExpanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .accessibilityHidden(true)
                            .foregroundStyle(failed ? Theme.danger : Theme.success)
                        Text(resultButtonTitle(
                            expanded: outputExpanded,
                            failed: failed,
                            toolName: toolName))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .buttonStyle(.borderless)

                if outputExpanded {
                    if toolName == "build_diagnostics" {
                        DiagnosticsCard(rawOutput: output)
                    } else if toolName == "apple_ship" {
                        ShipResultCard(output: output, failed: failed)
                    } else {
                        ScrollView {
                            Text(output)
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 280)
                        .padding(8)
                        .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    }
                }
            }
        case .reasoning(let text):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .accessibilityHidden(true)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.accentText)
                    .frame(width: 14, height: 18)
                Group {
                    if let attributed = try? AttributedString(
                        markdown: text,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                        Text(attributed)
                    } else {
                        Text(text)
                    }
                }
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)
        default:
            EmptyView()
        }
    }

    private func resultButtonTitle(
        expanded: Bool,
        failed: Bool,
        toolName: String?
    ) -> LocalizedStringKey {
        if expanded { return "Hide output" }
        if failed { return "Show failure" }
        switch toolName {
        case "apple_ship": return "Release prepared"
        case "task" where outputContainsIsolatedMerge: return "Isolated result merged"
        default: return "Show output"
        }
    }

    private var outputContainsIsolatedMerge: Bool {
        if case .toolResult(_, let output, _, _) = item.kind {
            return output.contains("Isolated worktree:")
        }
        return false
    }
}

struct ShipResultCard: View {
    let output: String
    let failed: Bool

    private var artifact: String? { value(after: "Artifact:") }
    private var report: String? { value(after: "Report:") }
    private var installedDevice: String? { value(after: "Installed:") }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: failed ? "shippingbox.and.arrow.backward.fill" : "shippingbox.fill")
                    .foregroundStyle(failed ? Theme.danger : Theme.success)
                VStack(alignment: .leading, spacing: 2) {
                    Text(failed ? "Release needs attention" : "Release artifact ready")
                        .font(.callout.weight(.semibold))
                    if let artifact {
                        Text(URL(fileURLWithPath: artifact).lastPathComponent)
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let installedDevice {
                        Label("Installed on \(installedDevice)", systemImage: "iphone.gen3.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.success)
                    }
                }
                Spacer()
            }
            HStack(spacing: Spacing.sm) {
                if let artifact {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            URL(fileURLWithPath: artifact),
                        ])
                    } label: {
                        Label("Reveal artifact", systemImage: "folder")
                    }
                    .buttonStyle(LFCapsuleButtonStyle())
                }
                if let report {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: report))
                    } label: {
                        Label("Open Ship Report", systemImage: "doc.text")
                    }
                    .buttonStyle(LFCapsuleButtonStyle())
                }
            }
            Text(output)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
        }
        .padding(Spacing.sm)
        .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }

    private func value(after prefix: String) -> String? {
        output.split(separator: "\n")
            .map(String.init)
            .first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Parsed compiler diagnostics with breadcrumb navigation: an error timeline
/// on top, then groups by file with per-diagnostic location chips.
struct DiagnosticsCard: View {
    let rawOutput: String

    private var diagnostics: [Diagnostic] {
        DiagnosticParser.parse(rawOutput)
    }

    var body: some View {
        let all = diagnostics
        let errors = all.filter { $0.severity == .error }
        let grouped = Dictionary(grouping: all, by: \.file)

        VStack(alignment: .leading, spacing: 8) {
            if all.isEmpty {
                Text(rawOutput)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } else {
                // Breadcrumb trail: file → line → severity for the first
                // error, plus the full error timeline.
                if let first = errors.first {
                    HStack(spacing: 6) {
                        Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                            .foregroundStyle(Theme.danger)
                        Text(first.file)
                            .font(.caption.monospaced().bold())
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                        Text(location(first))
                            .font(.caption2.monospaced())
                        Spacer()
                        Text("\(errors.count) error\(errors.count == 1 ? "" : "s")")
                            .font(.caption2.bold())
                            .foregroundStyle(Theme.danger)
                    }
                    .padding(6)
                    .background(Theme.wash(Theme.danger), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                }

                ForEach(grouped.keys.sorted(), id: \.self) { file in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file)
                            .font(.caption.monospaced().bold())
                        ForEach(diagnostics.filter { $0.file == file }) { diagnostic in
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(severityLabel(diagnostic.severity))
                                    .font(.caption2.monospaced().bold())
                                    .foregroundStyle(severityColor(diagnostic.severity))
                                Text(location(diagnostic))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(Theme.textTertiary)
                                Text(diagnostic.message)
                                    .font(.caption)
                            }
                        }
                    }
                    .padding(6)
                    .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                }
                HStack {
                    Text("\(errors.count) errors, \(all.filter { $0.severity == .warning }.count) warnings, \(all.filter { $0.severity == .note }.count) notes")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("Raw output")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func severityLabel(_ severity: Diagnostic.Severity) -> String {
        switch severity {
        case .error: return "error"
        case .warning: return "warning"
        case .note: return "note"
        }
    }

    private func severityColor(_ severity: Diagnostic.Severity) -> Color {
        switch severity {
        case .error: return Theme.danger
        case .warning: return Theme.warning
        case .note: return Theme.textSecondary
        }
    }

    private func location(_ diagnostic: Diagnostic) -> String {
        [diagnostic.line.map(String.init) ?? "?", diagnostic.column.map(String.init) ?? "?"].joined(separator: ":")
    }
}

/// Shared chrome for the transcript's interactive cards (approval, question,
/// plan): a tinted icon tile + semibold title + optional monospaced detail
/// chip — the same header language as Settings and the Model Manager.
private extension View {
    /// Raised surface + hairline + a 3-pt leading bar in the card's semantic
    /// tint. Quieter and more native than a full tint wash, and every
    /// interactive card shares the exact same silhouette.
    func lfTranscriptCard(_ tint: Color, radius: CGFloat = Radius.md) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(Theme.surface.opacity(0.72), in: shape)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tint)
                    .frame(width: 3)
                    .padding(.vertical, 10)
                    .padding(.leading, 6)
                    .allowsHitTesting(false)
            }
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
            .shadow(color: Theme.cardShadow.opacity(0.35), radius: 8, y: 2)
    }
}

struct TranscriptCardHeader: View {
    let title: String
    let systemImage: String
    let tint: Color
    var detail: String? = nil

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: systemImage)
                .font(.app(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Theme.washStrong(tint),
                            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            if let detail {
                Text(detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.surfaceInset, in: Capsule())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }
}

/// Reference-export card header: one small glyph, one 13.5pt semibold title,
/// no icon chip. Used by the plan, approval, and question cards.
struct TranscriptCardTitle: View {
    let title: String
    let systemImage: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            Text(title)
                .font(.app(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail {
                Text(detail)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }
}

/// 28pt-high, 8pt-radius card action. The filled tone is the deliberate
/// choice (Allow); the default tone is the quiet outline beside it.
struct CompactActionButtonStyle: ButtonStyle {
    var filled: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.app(size: 12.5, weight: filled ? .semibold : .medium))
            .foregroundStyle(filled ? Color.white : Instrument.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 28)
            .background(
                filled
                    ? AnyShapeStyle(Instrument.darkInsert)
                    : AnyShapeStyle(LinearGradient(
                        colors: [Instrument.silverTop, Instrument.silverLow],
                        startPoint: .top, endPoint: .bottom)),
                in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(filled ? Color.white.opacity(0.12) : Instrument.seam,
                              lineWidth: 0.75))
            .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : (isEnabled ? 1 : 0.45))
    }
}

struct ApprovalCard: View {
    let request: ApprovalRequest
    let onDecision: (Bool, Bool) -> Void

    /// Which "Always approve" scope this request belongs to — commands and
    /// edits widen different policy lanes, so the button says exactly what
    /// it will enable. Reads never ask, so they never appear here.
    private var isCommand: Bool {
        request.invocation.name == "run_command"
            || request.invocation.name == "build_diagnostics"
            || request.invocation.name == "apple_ship"
    }

    /// Reference-client header: file edits read as "Edit <path>" with a
    /// pencil; everything else keeps the approval title.
    private var isDiffPreview: Bool {
        if case .diff = request.preview { return true }
        return false
    }

    private var approvalTitle: String {
        if case .diff(_, let path) = request.preview { return "Edit \(path)" }
        return "Approval required"
    }

    private var approvalIcon: String {
        isDiffPreview ? "pencil" : "hand.raised.fill"
    }

    private var isComputer: Bool {
        request.invocation.name.hasPrefix("computer_")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            TranscriptCardTitle(
                title: approvalTitle,
                systemImage: approvalIcon,
                detail: isDiffPreview ? nil : request.invocation.name)

            Rectangle()
                .fill(Instrument.seam.opacity(0.45))
                .frame(height: 0.75)

            switch request.preview {
            case .command(let command):
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Command preview")
                        .font(.app(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text(command)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .lineSpacing(3)
                        .padding(Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surfaceInset.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(Theme.hairline.opacity(0.8), lineWidth: 0.75))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            case .diff(let diff, _):
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    DiffPreview(diff: diff)
                }
            case .none:
                Text(request.invocation.summary)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surfaceInset.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Rectangle()
                    .fill(Instrument.seam.opacity(0.45))
                    .frame(height: 0.75)
                ViewThatFits(in: .horizontal) {
                    approvalButtonRow
                    approvalButtonColumn
                }
                if request.invocation.name == "run_command" {
                    Text("This command runs in the workspace only after you approve it.")
                        .font(.app(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // Silver instrument chassis with an attached action strip.
        .instrumentFaceplate(radius: Radius.card, shadow: false)
    }

    private var approvalButtonRow: some View {
        HStack(spacing: Spacing.sm) {
            approveButton
            alwaysAllowButton
            declineButton
        }
    }

    private var approvalButtonColumn: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                approveButton
                alwaysAllowButton
            }
            declineButton
        }
    }

    private var approveButton: some View {
        // Approve is deliberate: Command-Return never fires while typing.
        Button {
            onDecision(true, false)
        } label: {
            Text("Allow")
        }
        .keyboardShortcut(KeyEquivalent.return, modifiers: .command)
        .buttonStyle(CompactActionButtonStyle(filled: true))
    }

    private var alwaysAllowButton: some View {
        Button {
            onDecision(true, true)
        } label: {
            Text(isComputer ? "Allow computer actions this run"
                    : (isCommand ? "Always allow safe commands" : "Allow for this chat"),
                  )
        }
        .buttonStyle(CompactActionButtonStyle())
        .help(isComputer
            ? "Approve this and later computer actions for this run; target restoration and verification remain active"
            : (isCommand
                ? "Approve this and auto-approve policy-safe commands for this run and future runs"
                : "Approve this and auto-approve file edits for this chat"))
    }

    private var declineButton: some View {
        Button("Reject") { onDecision(false, false) }
            .buttonStyle(CompactActionButtonStyle())
    }
}

struct DiffPreview: View {
    let diff: DiffEngine.Result
    @State private var split = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.xs) {
                Text("+\(diff.addedCount)")
                    .foregroundStyle(Theme.positive)
                Text("−\(diff.removedCount)")
                    .foregroundStyle(Theme.negative)
                Spacer()
                InstrumentSegmentedControl(
                    selection: $split,
                    options: [("Split", true), ("Unified", false)])
                .frame(width: 150)
                .accessibilityLabel("Diff layout")
            }
            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 5)
            Divider().overlay(Theme.hairline)
            ScrollView {
                if split {
                    sideBySide
                } else {
                    Text(diff.unified)
                        .font(.system(size: 12, design: .monospaced))
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(Spacing.sm)
                }
            }
            .frame(maxHeight: 320)
        }
        .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .foregroundStyle(diff.isEmpty ? Theme.textSecondary : Theme.textPrimary)
    }

    private var sideBySide: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(diff.sideBySide) { row in
                HStack(alignment: .top, spacing: 0) {
                    diffCell(row.left, kind: row.leftKind)
                    Divider().overlay(Theme.hairline)
                    diffCell(row.right, kind: row.rightKind)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func diffCell(_ text: String?, kind: DiffEngine.LineKind?) -> some View {
        Text(text ?? " ")
            .font(.system(size: 12, design: .monospaced))
            .lineSpacing(3)
            .foregroundStyle(diffColor(kind))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 1)
            .background(diffFill(kind))
            .textSelection(.enabled)
    }

    private func diffColor(_ kind: DiffEngine.LineKind?) -> Color {
        switch kind {
        case .added: Theme.positive
        case .removed: Theme.negative
        default: Theme.textPrimary
        }
    }

    private func diffFill(_ kind: DiffEngine.LineKind?) -> Color {
        switch kind {
        case .added: Theme.positive.opacity(0.10)
        case .removed: Theme.negative.opacity(0.10)
        default: Color.clear
        }
    }
}

struct QuestionCard: View {
    let question: String
    var choices: [String] = []
    let onAnswer: (String) -> Void

    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            TranscriptCardTitle(
                title: "The agent has a question",
                systemImage: "questionmark.circle")
            Text(question)
                .font(AppFont.chatBody)
                .lineSpacing(4)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
            if !choices.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ForEach(choices, id: \.self) { choice in
                        Button(choice) { onAnswer(choice) }
                            .buttonStyle(CompactActionButtonStyle(filled: true))
                    }
                }
            }
            HStack(spacing: Spacing.sm) {
                TextField("Your answer…", text: $answer)
                    .vampField()
                    .onSubmit {
                        guard !answer.isEmpty else { return }
                        onAnswer(answer)
                        answer = ""
                    }
                Button("Send") {
                    guard !answer.isEmpty else { return }
                    onAnswer(answer)
                    answer = ""
                }
                .buttonStyle(CompactActionButtonStyle(filled: true))
                .disabled(answer.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .padding(.leading, Spacing.sm)
        .lfTranscriptCard(Theme.info, radius: Radius.card)
    }
}

/// The live plan card: one card per run, replaced in place by every plan
/// snapshot. Counts derive from the actual task statuses.
struct LivePlanCard: View {
    let tasks: [AgentSessionController.PlanEntry]

    var body: some View {
        PlanCardBody(
            total: tasks.count,
            completed: tasks.filter(\.isComplete).count,
            rows: tasks.map { task in
                PlanCardBody.Row(
                    text: task.step,
                    complete: task.isComplete,
                    inProgress: task.isInProgress)
            })
    }
}

/// A finished run's persisted plan, reconstructed from the transcript
/// notice ("Codex plan\n<status>: <step>\n…") so restored sessions keep the
/// plan the run ended with.
struct PlanSnapshotCard: View {
    let text: String

    private struct ParsedRow {
        let text: String
        let complete: Bool
        let inProgress: Bool
    }

    private var rows: [ParsedRow] {
        guard let payload = text.split(separator: "\n", maxSplits: 1).last else { return [] }
        return payload.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let status = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            return ParsedRow(
                text: String(parts[1].trimmingCharacters(in: .whitespaces)),
                complete: status == "completed",
                inProgress: status == "in_progress" || status == "inprogress" || status == "running")
        }
    }

    var body: some View {
        PlanCardBody(
            total: rows.count,
            completed: rows.filter(\.complete).count,
            rows: rows.map { PlanCardBody.Row(text: $0.text, complete: $0.complete, inProgress: $0.inProgress) })
    }
}

/// Shared plan-card presentation: 14pt radius, hairline outline, compact
/// PLAN · n OF total header, 29pt task rows.
struct PlanCardBody: View {
    struct Row: Identifiable {
        var id: String { text }
        let text: String
        let complete: Bool
        let inProgress: Bool
    }

    let total: Int
    let completed: Int
    let rows: [Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PLAN · \(completed) OF \(total)")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        planIcon(row)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(row.inProgress ? Theme.accentText : Theme.textTertiary)
                            .frame(width: 14)
                        Text(row.text)
                            .font(.app(size: 13.5))
                            .foregroundStyle(row.complete ? Theme.textTertiary : Theme.textPrimary)
                            .strikethrough(row.complete)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 29, alignment: .top)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Silver instrument module: engraved seam, machined face, no shadow.
        .instrumentFaceplate(radius: Radius.card, shadow: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Plan: \(completed) of \(total) tasks complete")
    }

    @ViewBuilder
    private func planIcon(_ row: Row) -> some View {
        if row.complete {
            Image(systemName: "checkmark")
        } else if row.inProgress {
            Image(systemName: "circle.dotted")
        } else {
            Image(systemName: "square")
        }
    }
}

struct CompletionSnapshot: Equatable {
    let actionCount: Int
    let changedFileCount: Int
    let checksPassed: Int
    let checksFailed: Int
    let artifact: String?
    let report: String?

    static func make(
        transcript: [AgentSessionController.TranscriptItem]
    ) -> CompletionSnapshot {
        let start = transcript.lastIndex { item in
            if case .user = item.kind { return true }
            return false
        }.map { transcript.index(after: $0) } ?? transcript.startIndex
        let items = transcript[start...]
        var actions = 0
        var files = Set<String>()
        var passed = 0
        var failed = 0
        var artifact: String?
        var report: String?

        for item in items {
            switch item.kind {
            case .toolCall(let invocation):
                actions += 1
                let arguments = TolerantJSON.value(from: invocation.argumentsJSON)?.objectValue
                switch invocation.name {
                case "write_file", "apply_patch":
                    if let path = arguments?["path"]?.stringValue { files.insert(path) }
                case "move_file":
                    if let path = arguments?["from"]?.stringValue { files.insert(path) }
                    if let path = arguments?["to"]?.stringValue { files.insert(path) }
                default:
                    break
                }
            case .toolResult(_, let output, let didFail, let toolName):
                guard let toolName else { continue }
                if Self.isCheckTool(toolName) {
                    if didFail { failed += 1 } else { passed += 1 }
                }
                if toolName == "apple_ship" {
                    artifact = Self.value(after: "Artifact:", in: output) ?? artifact
                    report = Self.value(after: "Report:", in: output) ?? report
                }
            default:
                break
            }
        }

        return CompletionSnapshot(
            actionCount: actions,
            changedFileCount: files.count,
            checksPassed: passed,
            checksFailed: failed,
            artifact: artifact,
            report: report)
    }

    private static func isCheckTool(_ name: String) -> Bool {
        ["build_diagnostics", "sim_build_run", "macos_build_run", "apple_ship"]
            .contains(name)
    }

    private static func value(after prefix: String, in output: String) -> String? {
        output.split(separator: "\n")
            .map(String.init)
            .first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct FinishBanner: View {
    let reason: AgentFinish
    let summary: CompletionSnapshot
    let onNewChat: () -> Void
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            content
            Spacer(minLength: 0)
        }
    }

    /// Simple outcomes render as a tinted status pill; an engine error gets
    /// a rounded wash card so its detail message stays legible.
    @ViewBuilder
    private var content: some View {
        switch reason {
        case .completed:
            completionCard
        case .maxTurnsReached:
            pill("Reached the turn limit", systemImage: "exclamationmark.triangle.fill", tint: Theme.warning)
        case .declined:
            pill("Stopped — action declined", systemImage: "hand.raised.fill", tint: Theme.warning)
        case .cancelled:
            pill("Stopped", systemImage: "stop.fill", tint: Theme.textSecondary)
        case .engineError(let message):
            HStack(alignment: .top, spacing: Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
                    .foregroundStyle(Theme.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Error")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.danger)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let onDismiss {
                    Button("Dismiss", action: onDismiss)
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityHint("Hides this error. You can change models or send another message.")
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .frame(maxWidth: 520, alignment: .leading)
            .background(Theme.wash(Theme.danger), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Theme.washBorder(Theme.danger), lineWidth: 1))
        }
    }

    private var completionCard: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(completionTitle)
                    .font(.appMono(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.md) { completionMetrics }
                    VStack(alignment: .leading, spacing: Spacing.xs) { completionMetrics }
                }

                if summary.artifact != nil || summary.report != nil {
                    HStack(spacing: Spacing.sm) {
                        if let artifact = summary.artifact {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([
                                    URL(fileURLWithPath: artifact),
                                ])
                            } label: {
                                Label("Reveal artifact", systemImage: "folder")
                            }
                            .buttonStyle(LFCapsuleButtonStyle())
                        }
                        if let report = summary.report {
                            Button {
                                NSWorkspace.shared.open(URL(fileURLWithPath: report))
                            } label: {
                                Label("Open Ship Report", systemImage: "doc.text")
                            }
                            .buttonStyle(LFCapsuleButtonStyle())
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Button(action: onNewChat) {
                Label("New chat", systemImage: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, Spacing.xs)
            .frame(height: 28)
            .accessibilityHint("Clears this conversation and starts a new chat")
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 4)
        .frame(maxWidth: 560, alignment: .leading)
    }

    @ViewBuilder
    private var completionMetrics: some View {
        if summary.actionCount > 0 {
            metric(
                "\(summary.actionCount) action\(summary.actionCount == 1 ? "" : "s")",
                icon: "bolt")
        }
        if summary.changedFileCount > 0 {
            metric(
                "\(summary.changedFileCount) file\(summary.changedFileCount == 1 ? "" : "s") changed",
                icon: "doc.badge.ellipsis")
        }
        if summary.checksPassed > 0 {
            metric(
                "\(summary.checksPassed) check\(summary.checksPassed == 1 ? "" : "s") passed",
                icon: "checkmark.circle")
        }
        if summary.checksFailed > 0 {
            metric(
                "\(summary.checksFailed) check\(summary.checksFailed == 1 ? "" : "s") failed",
                icon: "xmark.circle",
                tint: Theme.danger)
        }
        if summary.artifact != nil {
            metric("Release packaged", icon: "shippingbox")
        }
    }

    private var completionTitle: LocalizedStringKey {
        if summary.artifact != nil { return "Release ready" }
        if summary.changedFileCount > 0 { return "Changes ready for review" }
        return "Task complete"
    }

    private func metric(
        _ title: LocalizedStringKey,
        icon: String,
        tint: Color = Theme.textSecondary
    ) -> some View {
        Label(title, systemImage: icon)
            .font(.caption)
            .foregroundStyle(tint)
    }

    private func pill(_ title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.callout.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 6)
            .background(Theme.wash(tint), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.washBorder(tint), lineWidth: 1))
    }
}
/// Live streaming assistant output: avatar-led (same identity as finished
/// messages), inline markdown, and a pulsing accent caret while generating.
/// Reduce Motion: the caret renders solid instead of pulsing.
///
/// The model/controller may publish around twenty text updates per second.
/// `StreamingMarkdownText` narrows that invalidation boundary and limits the
/// expensive full-document repair + Markdown parse to ten frames per second;
/// the final assistant row still renders immediately with `MarkdownText`.
struct StreamingCard: View {
    let text: String

    @State private var caretVisible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            StreamingMarkdownText(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Caret: a brand-gradient bar, pulsing while generating
            // (solid under Reduce Motion).
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Theme.accentGradient)
                .frame(width: 3, height: 16)
                .opacity(caretVisible ? 1 : 0.25)
        }
        .textSelection(.enabled)
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.45)) {
                    caretVisible.toggle()
                }
                try? await Task.sleep(for: .milliseconds(450))
            }
        }
    }
}

/// High-frequency streaming boundary with a narrow String input. `latestText`
/// follows every controller update, while `renderedText` advances on a fixed
/// cadence so unchanged Markdown subtrees are skipped by SwiftUI diffing.
private struct StreamingMarkdownText: View {
    let text: String

    @State private var latestText = ""
    @State private var renderedText = ""

    var body: some View {
        MarkdownText(text: renderedText)
            .onAppear {
                latestText = text
                renderedText = text
            }
            .onChange(of: text) { _, newValue in
                latestText = newValue
            }
            .task {
                while !Task.isCancelled {
                    if renderedText != latestText {
                        renderedText = latestText
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
    }
}

/// Shown while the model works but has produced no visible prose yet
/// (reasoning blocks, tool-call wire format): a proper animated indicator
/// instead of raw filler ("thinking thinking…") or half-streamed JSON.
/// Reduce Motion: static text, no pulse.
struct ReasoningIndicator: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text("Working…")
                .font(.callout)
        }
        .foregroundStyle(Theme.textSecondary)
        .accessibilityLabel("The model is working")
    }
}

/// Live activity is a slim native status capsule, not a second answer card.
/// The complete trace remains available in the finished activity disclosure.
struct LiveReasoningCard: View {
    let text: String
    let phase: AgentPhase

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 6, height: 6)
                .opacity(pulse ? 0.45 : 1)
            Text(phaseLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(progressExcerpt)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 30)
        .background(Theme.surface.opacity(0.82), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline.opacity(0.75), lineWidth: 1))
        .frame(maxWidth: 620, alignment: .leading)
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.7)) { pulse.toggle() }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(phaseLabel): \(progressExcerpt)")
    }

    private var progressExcerpt: String {
        let normalized = text
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .last ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > 260 else { return normalized }
        return "…" + String(normalized.suffix(259))
    }

    private var phaseLabel: String {
        switch phase {
        case .planning: "Planning"
        case .verifying: "Verifying"
        case .awaitingApproval: "Preparing an action"
        case .awaitingQuestion: "Thinking through a question"
        default: "Working through the task"
        }
    }
}
/// Plan-mode card: the agent's proposed plan with Approve / Revise.
struct PlanCard: View {
    let plan: String
    let onDecision: (String?) -> Void
    @State private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            TranscriptCardTitle(
                title: "Plan — approve before any tool runs",
                systemImage: "list.bullet.clipboard")
            Text(plan)
                .font(AppFont.chatBody)
                .foregroundStyle(Theme.textPrimary)
                .padding(Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineSpacing(4)
                .background(Theme.surfaceInset.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .textSelection(.enabled)
            HStack(spacing: Spacing.sm) {
                // Command-Return only: Return must submit revision feedback,
                // never accidentally approve and execute.
                Button("Approve & Execute ⌘↩") { onDecision(nil) }
                    .keyboardShortcut(KeyEquivalent.return, modifiers: .command)
                    .buttonStyle(CompactActionButtonStyle(filled: true))
                TextField("Revise: feedback…", text: $feedback)
                    .vampField()
                    .onSubmit {
                        guard !feedback.isEmpty else { return }
                        onDecision(feedback)
                    }
                Button("Revise") {
                    guard !feedback.isEmpty else { return }
                    onDecision(feedback)
                }
                .buttonStyle(CompactActionButtonStyle())
                .disabled(feedback.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .padding(.leading, Spacing.sm)
        .lfTranscriptCard(Theme.accent, radius: Radius.card)
    }
}
