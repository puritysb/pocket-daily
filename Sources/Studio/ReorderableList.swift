import SwiftUI

/// The row being dragged. One value is shared by every reorderable list in the
/// editor, so starting a drag always replaces the record of an earlier one (a
/// drag dropped outside a list never reports back) and a row dragged from one
/// list never reorders another.
struct ReorderDrag: Equatable {
    let list: String
    let id: String
}

extension Array where Element: Equatable {
    /// Moves `element` to `target`'s place, as dragging it over `target` shows it.
    mutating func move(_ element: Element, over target: Element) {
        guard element != target, let from = firstIndex(of: element), let to = firstIndex(of: target) else { return }
        move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    /// Moves the element at `index` one place earlier (`offset` -1) or later (+1).
    mutating func shift(at index: Int, by offset: Int) {
        let target = index + offset
        guard indices.contains(index), indices.contains(target) else { return }
        swapAt(index, target)
    }
}

extension View {
    /// Makes this row draggable within `list` and reorders `order` live as the
    /// dragged row passes over it.
    func reorderable(list: String, id: String, order: [String], drag: Binding<ReorderDrag?>,
                     move: @escaping (_ dragged: String, _ target: String) -> Void) -> some View {
        onDrag {
            drag.wrappedValue = ReorderDrag(list: list, id: id)
            return NSItemProvider(object: id as NSString)
        }
        .onDrop(of: [.text], delegate: ReorderDropDelegate(list: list, target: id, order: order,
                                                           drag: drag, move: move))
    }
}

private struct ReorderDropDelegate: DropDelegate {
    let list: String
    let target: String
    let order: [String]
    @Binding var drag: ReorderDrag?
    let move: (String, String) -> Void

    private var dragged: String? {
        guard let drag, drag.list == list, order.contains(drag.id), order.contains(target) else { return nil }
        return drag.id
    }

    func validateDrop(info: DropInfo) -> Bool { dragged != nil }

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != target else { return }
        withAnimation(.snappy(duration: 0.2)) { move(dragged, target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: dragged == nil ? .forbidden : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        drag = nil
        return true
    }
}

/// A screen's modules. The ones switched on come first, in the order the reader
/// shows them, and are dragged into place by their row; the rest follow,
/// switched off. At least one stays on and at most `limit` can be. Move Up and
/// Move Down are also offered in each row's context menu and to assistive
/// technologies. `accessory` sits before a row's switch and `expansion` below
/// it (for example, a module's own settings).
struct ModuleList<Item: Hashable & CaseIterable & RawRepresentable, Accessory: View, Expansion: View>: View
where Item.AllCases: RandomAccessCollection, Item.RawValue == String {
    @Binding var selection: [Item]
    /// Items this reader accepts; others are not offered.
    var available: Set<Item>? = nil
    var limit: Int? = nil
    /// False when the list sits inside another framed block.
    var framed = true
    let identifier: String
    @Binding var drag: ReorderDrag?
    let title: (Item) -> String
    let detail: (Item) -> String?
    @ViewBuilder let accessory: (Item) -> Accessory
    @ViewBuilder let expansion: (Item) -> Expansion

    private var rows: [Item] {
        selection + Item.allCases.filter { !selection.contains($0) && available?.contains($0) != false }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows, id: \.self) { item in
                VStack(alignment: .leading, spacing: 0) {
                    header(item)
                    expansion(item)
                }
                if item != rows.last { Divider().padding(.leading, 10) }
            }
        }
        .background(framed ? PocketPalette.panel : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(framed ? PocketPalette.line : .clear) }
    }

    @ViewBuilder private func header(_ item: Item) -> some View {
        let index = selection.firstIndex(of: item)
        let row = HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .opacity(index == nil ? 0 : 1)
                .accessibilityHidden(true)
            Text(title(item))
                .foregroundStyle(index == nil ? .secondary : .primary)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            accessory(item)
            Toggle(title(item), isOn: isOn(item))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!canToggle(item, on: index != nil))
                .accessibilityHint(detail(item) ?? "")
                .accessibilityActions {
                    if let index, index > 0 { Button("Move up") { selection.shift(at: index, by: -1) } }
                    if let index, index + 1 < selection.count { Button("Move down") { selection.shift(at: index, by: 1) } }
                }
                .accessibilityIdentifier("\(identifier)-\(item.rawValue)")
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .help(detail(item) ?? "")
        .contextMenu {
            if let index {
                Button("Move Up") { selection.shift(at: index, by: -1) }.disabled(index == 0)
                Button("Move Down") { selection.shift(at: index, by: 1) }.disabled(index + 1 >= selection.count)
            }
        }
        if index != nil {
            row.reorderable(list: identifier, id: item.rawValue, order: selection.map(\.rawValue), drag: $drag) {
                dragged, target in
                guard let dragged = Item(rawValue: dragged), let target = Item(rawValue: target) else { return }
                selection.move(dragged, over: target)
            }
        } else {
            row
        }
    }

    private func isOn(_ item: Item) -> Binding<Bool> {
        Binding(get: { selection.contains(item) }, set: { on in
            if on, !selection.contains(item), limit.map({ selection.count < $0 }) ?? true { selection.append(item) }
            if !on, selection.count > 1 { selection.removeAll { $0 == item } }
        })
    }

    private func canToggle(_ item: Item, on: Bool) -> Bool {
        on ? selection.count > 1 : limit.map { selection.count < $0 } ?? true
    }
}
