import Foundation
import Observation
import CoreGraphics

enum WorkspacePanel: Hashable, Codable, Identifiable, Sendable {
    case conversation, browser, changes, simulator, diagnostics, context, activity, session
    case specialist(UUID)
    case specialistBrowser(UUID)
    case runChanges(UUID, String)

    var id: String {
        switch self {
        case .conversation: "conversation"
        case .browser: "browser"
        case .changes: "changes"
        case .simulator: "simulator"
        case .diagnostics: "diagnostics"
        case .context: "context"
        case .activity: "activity"
        case .session: "session"
        case .runChanges(let id, _): "run-changes:\(id.uuidString)"
        case .specialist(let id): "specialist:\(id.uuidString)"
        case .specialistBrowser(let id): "browser:\(id.uuidString)"
        }
    }
    var title: String {
        switch self {
        case .conversation: "Conversation"
        case .browser, .specialistBrowser: "Browser"
        case .changes, .runChanges: "Changes"
        case .simulator: "Simulator"
        case .diagnostics: "Diagnostics"
        case .context: "Context"
        case .activity: "Activity"
        case .session: "Session"
        case .specialist: "Specialist work"
        }
    }
    var symbol: String {
        switch self {
        case .conversation: "bubble.left.and.bubble.right"
        case .browser, .specialistBrowser: "globe"
        case .changes, .runChanges: "doc.text.magnifyingglass"
        case .simulator: "iphone"
        case .diagnostics: "waveform.path.ecg"
        case .context: "square.stack.3d.up"
        case .activity, .specialist: "list.bullet.rectangle"
        case .session: "info.circle"
        }
    }
    var canClose: Bool { self != .conversation }
    var needsProject: Bool { self == .changes || self == .simulator || self == .context }
}

enum DockAxis: String, Codable, Sendable { case horizontal, vertical }
enum DockPlacement: String, CaseIterable, Sendable {
    case center, left, right, top, bottom
    var title: String {
        switch self {
        case .center: "As a tab"
        case .left: "Split left"
        case .right: "Split right"
        case .top: "Split above"
        case .bottom: "Split below"
        }
    }
}

struct DockGroup: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var tabs: [WorkspacePanel]
    var selected: WorkspacePanel
}

indirect enum DockNode: Codable, Equatable, Sendable {
    case group(DockGroup)
    case split(id: UUID, axis: DockAxis, fraction: Double, first: DockNode, second: DockNode)

    var groups: [DockGroup] {
        switch self {
        case .group(let group): [group]
        case .split(_, _, _, let first, let second): first.groups + second.groups
        }
    }

    var panels: [WorkspacePanel] { groups.flatMap(\.tabs) }

    var minimumSize: CGSize {
        switch self {
        case .group(let group):
            CGSize(width: group.tabs.contains(.conversation) ? 360 : 320, height: 320)
        case .split(_, let axis, _, let first, let second):
            axis == .horizontal
                ? CGSize(width: first.minimumSize.width + second.minimumSize.width + 5,
                         height: max(first.minimumSize.height, second.minimumSize.height))
                : CGSize(width: max(first.minimumSize.width, second.minimumSize.width),
                         height: first.minimumSize.height + second.minimumSize.height + 5)
        }
    }

    func replacingGroup(_ id: UUID, transform: (DockGroup) -> DockNode) -> DockNode {
        switch self {
        case .group(let group): group.id == id ? transform(group) : self
        case .split(let splitID, let axis, let fraction, let first, let second):
            .split(id: splitID, axis: axis, fraction: fraction,
                   first: first.replacingGroup(id, transform: transform),
                   second: second.replacingGroup(id, transform: transform))
        }
    }

    func removing(_ panel: WorkspacePanel) -> DockNode? {
        switch self {
        case .group(var group):
            group.tabs.removeAll { $0 == panel }
            guard let fallback = group.tabs.first else { return nil }
            if !group.tabs.contains(group.selected) { group.selected = fallback }
            return .group(group)
        case .split(let id, let axis, let fraction, let first, let second):
            let a = first.removing(panel)
            let b = second.removing(panel)
            if let a, let b { return .split(id: id, axis: axis, fraction: fraction, first: a, second: b) }
            return a ?? b
        }
    }

    func settingFraction(_ value: Double, splitID: UUID) -> DockNode {
        switch self {
        case .group: self
        case .split(let id, let axis, let fraction, let first, let second):
            .split(id: id, axis: axis, fraction: id == splitID ? min(0.9, max(0.1, value)) : fraction,
                   first: first.settingFraction(value, splitID: splitID),
                   second: second.settingFraction(value, splitID: splitID))
        }
    }

    /// Decoded UI state is untrusted. Reject duplicate resources, empty groups,
    /// missing conversation panes and unreasonable recursion before rendering.
    func isValid(depth: Int = 0) -> Bool {
        guard depth < 32 else { return false }
        switch self {
        case .group(let group):
            return !group.tabs.isEmpty && group.tabs.contains(group.selected)
                && Set(group.tabs).count == group.tabs.count
        case .split(_, _, let fraction, let first, let second):
            return fraction.isFinite && (0.1...0.9).contains(fraction)
                && first.isValid(depth: depth + 1) && second.isValid(depth: depth + 1)
        }
    }

    var isValidWorkspace: Bool {
        isValid() && panels.filter { $0 == .conversation }.count == 1
            && Set(panels.map(\.id)).count == panels.count
            && Set(groups.map(\.id)).count == groups.count
    }
}

@MainActor
@Observable
final class WorkspaceDock {
    let dragIdentity = UUID()
    private(set) var root: DockNode
    private(set) var focusedPanel: WorkspacePanel = .conversation
    var dropGroupID: UUID?
    var dropPlacement: DockPlacement = .center
    private let defaults: UserDefaults?
    private var storageKey: String?
    private var saveTask: Task<Void, Never>?

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        root = Self.emptyLayout()
    }

    private static func emptyLayout() -> DockNode {
        .group(DockGroup(tabs: [.conversation], selected: .conversation))
    }

    func bind(windowID: String, workspace: String) {
        let key = "workspace-layout.v1.\(windowID).\(workspace)"
        guard key != storageKey else { return }
        flush()
        storageKey = key
        if let data = defaults?.data(forKey: key),
           let layout = try? JSONDecoder().decode(DockNode.self, from: data),
           layout.isValidWorkspace {
            root = layout
        } else {
            root = Self.emptyLayout()
        }
        focusedPanel = .conversation
        dropGroupID = nil
    }

    var panels: [WorkspacePanel] { root.panels }
    func group(containing panel: WorkspacePanel) -> DockGroup? {
        root.groups.first { $0.tabs.contains(panel) }
    }
    func contains(_ panel: WorkspacePanel) -> Bool { panels.contains(panel) }
    func needsFocusMode(in size: CGSize) -> Bool {
        size.width < root.minimumSize.width || size.height < root.minimumSize.height
    }

    func select(_ panel: WorkspacePanel) {
        guard let group = group(containing: panel) else { return }
        root = root.replacingGroup(group.id) { current in
            var selected = current
            selected.selected = panel
            return .group(selected)
        }
        focusedPanel = panel
        scheduleSave()
    }

    func open(_ panel: WorkspacePanel, activate: Bool = true) {
        if let existing = panels.first(where: { $0.id == panel.id }) { if activate { select(existing) }; return }
        if let target = root.groups.first(where: { !$0.tabs.contains(.conversation) }) {
            root = root.replacingGroup(target.id) { group in
                var result = group
                result.tabs.append(panel)
                result.selected = panel
                return .group(result)
            }
        } else {
            root = .split(id: UUID(), axis: .horizontal, fraction: 0.6,
                          first: root,
                          second: .group(DockGroup(tabs: [panel], selected: panel)))
        }
        if activate { focusedPanel = panel }
        scheduleSave()
    }

    func close(_ panel: WorkspacePanel) {
        guard panel.canClose, let next = root.removing(panel) else { return }
        root = next
        if focusedPanel == panel { focusedPanel = .conversation }
        scheduleSave()
    }

    @discardableResult
    func move(_ panel: WorkspacePanel, to groupID: UUID, placement: DockPlacement) -> Bool {
        guard let source = group(containing: panel),
              root.groups.contains(where: { $0.id == groupID }) else { return false }
        if source.id == groupID {
            if placement == .center { select(panel); return true }
            if source.tabs.count == 1 { return false }
        }
        guard let remaining = root.removing(panel),
              remaining.groups.contains(where: { $0.id == groupID }) else { return false }
        let next = remaining.replacingGroup(groupID) { group in
            if placement == .center {
                var result = group
                result.tabs.append(panel)
                result.selected = panel
                return .group(result)
            }
            let new = DockNode.group(DockGroup(tabs: [panel], selected: panel))
            let old = DockNode.group(group)
            let leading = placement == .left || placement == .top
            return .split(id: UUID(),
                          axis: placement == .left || placement == .right ? .horizontal : .vertical,
                          fraction: 0.5, first: leading ? new : old, second: leading ? old : new)
        }
        guard next.isValidWorkspace else { return false }
        root = next
        focusedPanel = panel
        dropGroupID = nil
        scheduleSave()
        return true
    }

    func setFraction(_ fraction: Double, splitID: UUID) {
        guard fraction.isFinite else { return }
        root = root.settingFraction(fraction, splitID: splitID)
        scheduleSave()
    }

    func reset() {
        let tools = panels.filter(\.canClose)
        let conversation = Self.emptyLayout()
        if let first = tools.first {
            root = .split(id: UUID(), axis: .horizontal, fraction: 0.6, first: conversation,
                          second: .group(DockGroup(tabs: tools, selected: first)))
        } else { root = conversation }
        focusedPanel = .conversation
        scheduleSave()
    }

    func flush() {
        saveTask?.cancel()
        guard let storageKey, let data = try? JSONEncoder().encode(root) else { return }
        defaults?.set(data, forKey: storageKey)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}
