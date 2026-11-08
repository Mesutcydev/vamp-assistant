import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let workspaceTabType = "com.beetcode.workspace-tab"

struct WorkspaceDockView: View {
    @Bindable var dock: WorkspaceDock
    var content: (WorkspacePanel) -> AnyView

    var body: some View {
        GeometryReader { geometry in
            if dock.needsFocusMode(in: geometry.size) {
                WorkspaceFocusView(dock: dock, content: content)
            } else {
                WorkspaceDockNodeView(node: dock.root, dock: dock, content: content)
            }
        }
        .background(Theme.workspaceCanvas)
    }
}

private struct WorkspaceFocusView: View {
    @Bindable var dock: WorkspaceDock
    let content: (WorkspacePanel) -> AnyView

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(dock.panels) { panel in
                        Button { dock.select(panel) } label: {
                            Label(panel.title, systemImage: panel.symbol)
                        }
                    }
                } label: {
                    Label(dock.focusedPanel.title, systemImage: dock.focusedPanel.symbol)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Switch workspace pane")
                if dock.focusedPanel != .conversation {
                    Button("Back to conversation") { dock.select(.conversation) }
                        .buttonStyle(.borderless)
                }
                Spacer(minLength: 4)
                Text("Focus layout")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .help("Your split layout returns when the window has enough room.")
                if dock.focusedPanel.canClose {
                    Button { dock.close(dock.focusedPanel) } label: {
                        Image(systemName: "xmark").frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close \(dock.focusedPanel.title)")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Theme.surface)
            Divider()
            content(dock.focusedPanel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
    }
}

private struct WorkspaceDockNodeView: View {
    let node: DockNode
    @Bindable var dock: WorkspaceDock
    let content: (WorkspacePanel) -> AnyView

    var body: some View {
        switch node {
        case .group(let group):
            WorkspaceDockGroupView(group: group, dock: dock, content: content)
                .id(group.id)
        case .split(let id, let axis, let fraction, let first, let second):
            WorkspaceSplitView(
                id: id, axis: axis, fraction: fraction,
                firstMinimum: first.minimumSize, secondMinimum: second.minimumSize,
                onResize: { dock.setFraction($0, splitID: id) },
                first: AnyView(WorkspaceDockNodeView(node: first, dock: dock, content: content)),
                second: AnyView(WorkspaceDockNodeView(node: second, dock: dock, content: content)))
                .id(id)
        }
    }
}

private struct WorkspaceSplitView: View {
    let id: UUID
    let axis: DockAxis
    let fraction: Double
    let firstMinimum: CGSize
    let secondMinimum: CGSize
    let onResize: (Double) -> Void
    let first: AnyView
    let second: AnyView
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geometry in
            let horizontal = axis == .horizontal
            let length = max(1, (horizontal ? geometry.size.width : geometry.size.height) - 5)
            let lower = (horizontal ? firstMinimum.width : firstMinimum.height) / length
            let upper = 1 - (horizontal ? secondMinimum.width : secondMinimum.height) / length
            let visibleFraction = min(upper, max(lower, fraction))
            let firstLength = length * visibleFraction
            if horizontal {
                HStack(spacing: 0) {
                    first.frame(width: firstLength, height: geometry.size.height)
                    divider(length: length, fraction: visibleFraction, lower: lower, upper: upper)
                    second.frame(width: max(0, length - firstLength), height: geometry.size.height)
                }
            } else {
                VStack(spacing: 0) {
                    first.frame(width: geometry.size.width, height: firstLength)
                    divider(length: length, fraction: visibleFraction, lower: lower, upper: upper)
                    second.frame(width: geometry.size.width, height: max(0, length - firstLength))
                }
            }
        }
    }

    private func divider(length: CGFloat, fraction: Double, lower: Double, upper: Double) -> some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: axis == .horizontal ? 5 : nil, height: axis == .vertical ? 5 : nil)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStart == nil { dragStart = fraction }
                        let translation = axis == .horizontal ? value.translation.width : value.translation.height
                        onResize(min(upper, max(lower, (dragStart ?? fraction) + translation / length)))
                    }
                    .onEnded { _ in dragStart = nil })
            .onHover { hovering in
                if hovering {
                    (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                } else { NSCursor.arrow.set() }
            }
            .focusable()
            .accessibilityLabel(axis == .horizontal ? "Resize panels horizontally" : "Resize panels vertically")
            .accessibilityValue("\(Int(fraction * 100)) percent")
            .accessibilityAdjustableAction { direction in
                let change = direction == .increment ? 0.05 : -0.05
                onResize(min(upper, max(lower, fraction + change)))
            }
            .onKeyPress { press in
                if press.key == .leftArrow || press.key == .upArrow {
                    onResize(min(upper, max(lower, fraction - 0.05)))
                    return .handled
                }
                if press.key == .rightArrow || press.key == .downArrow {
                    onResize(min(upper, max(lower, fraction + 0.05)))
                    return .handled
                }
                return .ignored
            }
            .help("Drag to resize. Use arrow keys when focused.")
            .accessibilityIdentifier("dock-split-\(id.uuidString)")
    }
}

private struct WorkspaceDockGroupView: View {
    let group: DockGroup
    @Bindable var dock: WorkspaceDock
    let content: (WorkspacePanel) -> AnyView

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(group.tabs) { panel in
                            tab(panel)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .scrollIndicators(.hidden)
                .frame(height: 36)
                .background(Theme.surface)
                Divider()
                content(group.selected)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .overlay {
                if dock.dropGroupID == group.id {
                    dropIndicator(in: geometry.size)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [workspaceTabType],
                    delegate: WorkspaceTabDropDelegate(groupID: group.id, size: geometry.size, dock: dock))
        }
    }

    private func tab(_ panel: WorkspacePanel) -> some View {
        HStack(spacing: 0) {
            Button { dock.select(panel) } label: {
                Label(panel.title, systemImage: panel.symbol)
                    .font(.system(size: 12, weight: group.selected == panel ? .semibold : .regular))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(panel.title) pane")
            .accessibilityAddTraits(group.selected == panel ? .isSelected : [])
            if panel.canClose {
                Button { dock.close(panel) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(panel.title)")
            }
        }
        .foregroundStyle(group.selected == panel ? Theme.textPrimary : Theme.textSecondary)
        .background(group.selected == panel ? Theme.surfaceInset : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottom) {
            if group.selected == panel {
                Rectangle().fill(Theme.accent).frame(height: 2).padding(.horizontal, 8)
            }
        }
        .onDrag {
            let provider = NSItemProvider()
            let data = Data("\(dock.dragIdentity.uuidString)\n\(panel.id)".utf8)
            provider.registerDataRepresentation(forTypeIdentifier: workspaceTabType, visibility: .ownProcess) { completion in
                completion(data, nil)
                return nil
            }
            return provider
        }
        .contextMenu {
            ForEach(DockPlacement.allCases.filter { $0 != .center }, id: \.rawValue) { placement in
                Button(placement.title) { _ = dock.move(panel, to: group.id, placement: placement) }
                    .disabled(group.tabs.count < 2)
            }
            Menu("Move to group") {
                ForEach(dock.root.groups.filter { $0.id != group.id }) { target in
                    Button(target.selected.title) { _ = dock.move(panel, to: target.id, placement: .center) }
                }
            }
            if panel.canClose, let conversation = dock.group(containing: .conversation) {
                Divider()
                Button("Dock beside conversation") { _ = dock.move(panel, to: conversation.id, placement: .right) }
                Button("Dock below conversation") { _ = dock.move(panel, to: conversation.id, placement: .bottom) }
                Divider()
                Button("Close pane") { dock.close(panel) }
            }
            Button("Reset layout") { dock.reset() }
        }
    }

    private func dropIndicator(in size: CGSize) -> some View {
        let edge = dock.dropPlacement
        let horizontal = edge == .left || edge == .right
        let vertical = edge == .top || edge == .bottom
        return RoundedRectangle(cornerRadius: 8)
            .fill(Theme.accent.opacity(0.12))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent, lineWidth: 2))
            .padding(4)
            .frame(width: horizontal ? size.width / 2 : size.width,
                   height: vertical ? size.height / 2 : size.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: edge == .left ? .leading : edge == .right ? .trailing
                   : edge == .top ? .top : edge == .bottom ? .bottom : .center)
    }
}

private struct WorkspaceTabDropDelegate: DropDelegate {
    let groupID: UUID
    let size: CGSize
    let dock: WorkspaceDock

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [workspaceTabType]) }
    func dropEntered(info: DropInfo) { update(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) {
        if dock.dropGroupID == groupID { dock.dropGroupID = nil }
    }
    func performDrop(info: DropInfo) -> Bool {
        let placement = position(info.location)
        dock.dropGroupID = nil
        guard let provider = info.itemProviders(for: [workspaceTabType]).first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: workspaceTabType) { data, _ in
            guard let data, let payload = String(data: data, encoding: .utf8) else { return }
            let parts = payload.split(separator: "\n", maxSplits: 1).map(String.init)
            Task { @MainActor in
                guard parts.count == 2, parts[0] == dock.dragIdentity.uuidString,
                      let panel = dock.panels.first(where: { $0.id == parts[1] }) else { return }
                _ = dock.move(panel, to: groupID, placement: placement)
            }
        }
        return true
    }
    private func update(_ info: DropInfo) {
        dock.dropGroupID = groupID
        dock.dropPlacement = position(info.location)
    }
    private func position(_ point: CGPoint) -> DockPlacement {
        let x = point.x / max(1, size.width)
        let y = point.y / max(1, size.height)
        if y < 0.2 { return .top }
        if y > 0.8 { return .bottom }
        if x < 0.22 { return .left }
        if x > 0.78 { return .right }
        return .center
    }
}
