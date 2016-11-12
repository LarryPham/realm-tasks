////////////////////////////////////////////////////////////////////////////
//
// Copyright 2016 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

// FIXME: This file should be split up.
// swiftlint:disable file_length

import Cartography
import Cocoa
import RealmSwift

private let taskCellIdentifier = "TaskCell"
private let listCellIdentifier = "ListCell"
private let prototypeCellIdentifier = "PrototypeCell"

// FIXME: This type should be split up.
// swiftlint:disable:next type_body_length
final class ListViewController<ListType: ListPresentable>: NSViewController,
NSTableViewDelegate, NSTableViewDataSource, ItemCellViewDelegate, NSGestureRecognizerDelegate where ListType: Object {

    typealias ItemType = ListType.Item

    let list: ListType

    private let tableView = NSTableView()

    private var notificationToken: NotificationToken?

    private let prototypeCell = PrototypeCellView(identifier: prototypeCellIdentifier)

    private var currentlyEditingCellView: ItemCellView?

    private var currentlyMovingRowView: NSTableRowView?
    private var currentlyMovingRowSnapshotView: SnapshotView?

    private var animating = false
    private var needsReloadTableView = true

    private var autoscrollTimer: Timer?

    init(list: ListType) {
        self.list = list

        super.init(nibName: nil, bundle: nil)!
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        notificationToken?.stop()
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        tableView.addTableColumn(NSTableColumn())
        tableView.backgroundColor = .clear
        tableView.headerView = nil
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = .zero

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.drawsBackground = false

        view.addSubview(scrollView)

        constrain(scrollView) { scrollView in
            scrollView.edges == scrollView.superview!.edges
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let notificationCenter = NotificationCenter.default

        // Handle window resizing to update table view rows height
        notificationCenter.addObserver(self, selector: #selector(windowDidResize), name: NSNotification.Name.NSWindowDidResize, object: view.window)
        notificationCenter.addObserver(self, selector: #selector(windowDidResize), name: NSNotification.Name.NSWindowDidEnterFullScreen, object: view.window)
        notificationCenter.addObserver(self, selector: #selector(windowDidResize), name: NSNotification.Name.NSWindowDidExitFullScreen, object: view.window)

        setupNotifications()
        setupGestureRecognizers()

        tableView.delegate = self
        tableView.dataSource = self
    }

    private func setupNotifications() {
        notificationToken = list.items.addNotificationBlock { [unowned self] changes in
            self.needsReloadTableView = true

            if !self.reordering && !self.editing && !self.animating {
                self.reloadTableViewIfNeeded()
            }
        }
    }

    private func reloadTableViewIfNeeded() {
        if needsReloadTableView {
            tableView.reloadData()
            needsReloadTableView = false
        }
    }

    private func setupGestureRecognizers() {
        let pressGestureRecognizer = NSPressGestureRecognizer(target: self, action: #selector(handlePressGestureRecognizer))
        pressGestureRecognizer.minimumPressDuration = 0.2

        let panGestureRecognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePanGestureRecognizer))

        for recognizer in [pressGestureRecognizer, panGestureRecognizer] {
            recognizer.delegate = self
            tableView.addGestureRecognizer(recognizer)
        }
    }

    private dynamic func windowDidResize(notification: NSNotification) {
        updateTableViewHeightOfRows()
    }

    private func updateTableViewHeightOfRows(indexes: IndexSet? = nil) {
        // noteHeightOfRows animates by default, disable this
        NSView.animate(duration: 0) {
            tableView.noteHeightOfRows(withIndexesChanged: indexes ?? IndexSet(integersIn: Range(0...tableView.numberOfRows)))
        }
    }

    // MARK: Actions

    @IBAction func newItem(sender: AnyObject?) {
        endEditingCells()

        try! list.realm?.write {
            list.items.insert(ItemType(), at: 0)
        }

        animating = true
        NSView.animate(animations: {
            NSAnimationContext.current().allowsImplicitAnimation = false // prevents NSTableView autolayout issues
            tableView.insertRows(at: NSIndexSet(index: 0) as IndexSet, withAnimation: .effectGap)
        }) {
            if let newItemCellView = self.tableView.view(atColumn: 0, row: 0, makeIfNecessary: false) as? ItemCellView {
                self.beginEditingCell(cellView: newItemCellView)
                self.tableView.selectRowIndexes(IndexSet(index: 0), byExtendingSelection: false)
            }

            self.animating = false
        }
    }

    override func validateToolbarItem(_ toolbarItem: NSToolbarItem) -> Bool {
        return validateSelector(selector: toolbarItem.action!)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        return validateSelector(selector: menuItem.action!)
    }

    private func validateSelector(selector: Selector) -> Bool {
        switch selector {
        case #selector(newItem):
            return !editing || currentlyEditingCellView?.text.isEmpty == false
        default:
            return true
        }
    }

    // MARK: Reordering

    var reordering: Bool {
        return currentlyMovingRowView != nil
    }

    private func beginReorderingRow(row: Int, screenPoint point: NSPoint) {
        currentlyMovingRowView = tableView.rowView(atRow: row, makeIfNecessary: false)

        if currentlyMovingRowView == nil {
            return
        }

        tableView.enumerateAvailableRowViews { _, row in
            if let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ItemCellView {
                view.isUserInteractionEnabled = false
            }
        }

        currentlyMovingRowSnapshotView = SnapshotView(sourceView: currentlyMovingRowView!)
        currentlyMovingRowView!.alphaValue = 0

        currentlyMovingRowSnapshotView?.frame.origin.y = view.convert(point, from: nil).y - currentlyMovingRowSnapshotView!.frame.height / 2
        view.addSubview(currentlyMovingRowSnapshotView!)

        NSView.animate() {
            let frame = currentlyMovingRowSnapshotView!.frame
            currentlyMovingRowSnapshotView!.frame = frame.insetBy(dx: -frame.width * 0.02, dy: -frame.height * 0.02)
        }
    }

    private func handleReorderingForScreenPoint(point: NSPoint) {
        guard reordering else {
            return
        }

        if let snapshotView = currentlyMovingRowSnapshotView {
            snapshotView.frame.origin.y = snapshotView.superview!.convert(point, from: nil).y - snapshotView.frame.height / 2
        }

        let sourceRow = tableView.row(for: currentlyMovingRowView!)
        let destinationRow: Int

        let pointInTableView = tableView.convert(point, from: nil)

        if pointInTableView.y < tableView.bounds.minY {
            destinationRow = 0
        } else if pointInTableView.y > tableView.bounds.maxY {
            destinationRow = tableView.numberOfRows - 1
        } else {
            destinationRow = tableView.row(at: pointInTableView)
        }

        if canMoveRow(sourceRow: sourceRow, toRow: destinationRow) {
            try! list.realm?.write {
                list.items.move(from: sourceRow, to: destinationRow)
            }

            NSView.animate() {
                // Disable implicit animations because tableView animates reordering via animator proxy
                NSAnimationContext.current().allowsImplicitAnimation = false
                tableView.moveRow(at: sourceRow, to: destinationRow)
            }
        }
    }

    private func canMoveRow(sourceRow: Int, toRow destinationRow: Int) -> Bool {
        guard destinationRow >= 0 && destinationRow != sourceRow else {
            return false
        }

        return !list.items[destinationRow].completed
    }

    private func endReordering() {
        guard reordering else {
            return
        }

        NSView.animate(animations: {
            currentlyMovingRowSnapshotView?.frame = view.convert(currentlyMovingRowView!.frame, from: tableView)
        }) {
            self.currentlyMovingRowView?.alphaValue = 1
            self.currentlyMovingRowView = nil

            self.currentlyMovingRowSnapshotView?.removeFromSuperview()
            self.currentlyMovingRowSnapshotView = nil

            self.tableView.enumerateAvailableRowViews { _, row in
                if let view = self.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ItemCellView {
                    view.isUserInteractionEnabled = true
                }
            }

            self.updateColors()
            self.reloadTableViewIfNeeded()
        }
    }

    private dynamic func handlePressGestureRecognizer(recognizer: NSPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            beginReorderingRow(row: tableView.row(at: recognizer.location(in: tableView)), screenPoint: recognizer.location(in: nil))
        case .ended, .cancelled:
            endReordering()
        default:
            break
        }
    }

    private dynamic func handlePanGestureRecognizer(recognizer: NSPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            startAutoscrolling()
        case .changed:
            handleReorderingForScreenPoint(point: recognizer.location(in: nil))
        case .ended:
            stopAutoscrolling()
        default:
            break
        }
    }

    private func startAutoscrolling() {
        guard autoscrollTimer == nil else {
            return
        }

        autoscrollTimer = Timer.scheduledTimer(timeInterval: 0.01, target: self, selector: #selector(handleAutoscrolling), userInfo: nil, repeats: true)
    }

    private dynamic func handleAutoscrolling() {
        if let event = NSApp.currentEvent {
            if tableView.autoscroll(with: event) {
                handleReorderingForScreenPoint(point: event.locationInWindow)
            }
        }
    }

    private func stopAutoscrolling() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }

    // MARK: Editing

    var editing: Bool {
        return currentlyEditingCellView != nil
    }

    private func beginEditingCell(cellView: ItemCellView) {
        NSView.animate(animations: {
            tableView.scrollRowToVisible(tableView.row(for: cellView))

            tableView.enumerateAvailableRowViews { _, row in
                if let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ItemCellView, view != cellView {
                    view.alphaValue = 0.3
                    view.isUserInteractionEnabled = false
                }
            }
        }) {
            self.view.window?.update()
        }

        cellView.editable = true
        view.window?.makeFirstResponder(cellView.textView)

        currentlyEditingCellView = cellView
    }

    private func endEditingCells() {
        guard editing else {
            return
        }

        view.window?.makeFirstResponder(self)

        NSView.animate(animations: {
            tableView.enumerateAvailableRowViews { _, row in
                if let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ItemCellView {
                    view.alphaValue = 1
                    view.isUserInteractionEnabled = true
                }
            }
        }) {
            self.currentlyEditingCellView = nil
            self.view.window?.update()
            self.reloadTableViewIfNeeded()
        }
    }

    // MARK: NSGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        return gestureRecognizer is NSPanGestureRecognizer
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        guard !editing else {
            return false
        }

        switch gestureRecognizer {
        case is NSPressGestureRecognizer:
            let targetRow = tableView.row(at: gestureRecognizer.location(in: tableView))

            guard targetRow >= 0 else {
                return false
            }

            return !list.items[targetRow].completed
        case is NSPanGestureRecognizer:
            return reordering
        default:
            return true
        }
    }

    // MARK: NSTableViewDataSource

    private func numberOfRowsInTableView(tableView: NSTableView) -> Int {
        return list.items.count
    }

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = list.items[row]

        let cellViewIdentifier: String
        let cellViewType: ItemCellView.Type
        let cellView: ItemCellView

        switch item {
        case is TaskList:
            cellViewIdentifier = listCellIdentifier
            cellViewType = ListCellView.self
        case is Task:
            cellViewIdentifier = taskCellIdentifier
            cellViewType = TaskCellView.self
        default:
            fatalError("Unknown item type")
        }

        if let view = tableView.make(withIdentifier: cellViewIdentifier, owner: self) as? ItemCellView {
            cellView = view
        } else {
            cellView = cellViewType.init(identifier: listCellIdentifier)
        }

        cellView.configure(item: item)
        cellView.backgroundColor = colorForRow(row: row)
        cellView.delegate = self

        return cellView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if let cellView = currentlyEditingCellView {
            prototypeCell.configure(cellView)
        } else {
            prototypeCell.configure(list.items[row])
        }

        return prototypeCell.fittingHeightForConstrainedWidth(width: tableView.bounds.width)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let index = tableView.selectedRow

        guard 0 <= index && index < list.items.count else {
            endEditingCells()
            return
        }

        guard !list.items[index].completed else {
            endEditingCells()
            return
        }

        guard let cellView = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ItemCellView, cellView != currentlyEditingCellView else {
            return
        }

        guard currentlyEditingCellView == nil else {
            endEditingCells()
            return
        }

        if let listCellView = cellView as? ListCellView, !listCellView.acceptsEditing, let list = list.items[index] as? TaskList {
            (parentViewController as? ContainerViewController)?.presentViewControllerForList(list)
        } else {
            beginEditingCell(cellView: cellView)
        }
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        updateColors()
    }

    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        updateColors()
    }

    private func updateColors() {
        tableView.enumerateAvailableRowViews { rowView, row in
            // For some reason tableView.viewAtColumn:row: returns nil while animating, will use view hierarchy instead
            if let cellView = rowView.subviews.first as? ItemCellView {
                NSView.animate() {
                    cellView.backgroundColor = colorForRow(row: row)
                }
            }
        }
    }

    private func colorForRow(row: Int) -> NSColor {
        let colors = ItemType.self is Task.Type ? NSColor.taskColors() : NSColor.listColors()
        let fraction = Double(row) / Double(max(13, list.items.count))

        return colors.gradientColorAtFraction(fraction: fraction)
    }

    // MARK: ItemCellViewDelegate

    func cellView(view: ItemCellView, didComplete complete: Bool) {
        guard let itemAndIndex = findItemForCellView(view: view) else {
            return
        }

        var item = itemAndIndex.0
        let index = itemAndIndex.1
        let destinationIndex: Int

        if complete {
            // move cell to bottom
            destinationIndex = list.items.count - 1
        } else {
            // move cell just above the first completed item
            let completedCount = list.items.filter("completed = true").count
            destinationIndex = list.items.count - completedCount
        }

        dispatch_after(DispatchTime.now(dispatch_time_t(DISPATCH_TIME_NOW), Int64(0.1 * Double(NSEC_PER_SEC))), dispatch_get_main_queue()) {
            try! item.realm?.write {
                item.completed = complete

                if index != destinationIndex {
                    self.list.items.removeAtIndex(index)
                    self.list.items.insert(item, atIndex: destinationIndex)
                }
            }

            self.animating = true
            NSView.animate(duration: 0.3, animations: {
                NSAnimationContext.currentContext().allowsImplicitAnimation = false
                self.tableView.moveRowAtIndex(index, toIndex: destinationIndex)
            }) {
                self.animating = false
                self.reloadTableViewIfNeeded()
            }
        }
    }

    func cellViewDidDelete(view: ItemCellView) {
        guard let (item, index) = findItemForCellView(view: view) else {
            return
        }

        try! list.realm?.write {
            list.realm?.delete(item)
        }

        animating = true
        NSView.animate(animations: {
            NSAnimationContext.current().allowsImplicitAnimation = false
            tableView.removeRowsAtIndexes(IndexSet(index: index), withAnimation: .SlideLeft)
        }) {
            self.animating = false
            self.reloadTableViewIfNeeded()
        }
    }

    func cellViewDidChangeText(view: ItemCellView) {
        if view == currentlyEditingCellView {
            updateTableViewHeightOfRows(indexes: IndexSet(index: tableView.rowForView(view)))
            view.window?.toolbar?.validateVisibleItems()
        }
    }

    func cellViewDidEndEditing(view: ItemCellView) {
        guard let (tmpItem, index) = findItemForCellView(view: view) else {
            return
        }

        if view.text != tmpItem.text || view.text.isEmpty {
            // Workaround for tuple mutability
            var item = tmpItem

            try! item.realm?.write {
                if !view.text.isEmpty {
                    item.text = view.text
                } else {
                    item.realm!.delete(item)

                    dispatch_async(dispatch_get_main_queue()) {
                        self.tableView.removeRowsAtIndexes(NSIndexSet(index: index), withAnimation: .SlideUp)
                    }
                }
            }
        }

        // In case if Return key was pressed we need to reset table view selection
        tableView.selectRowIndexes(IndexSet(), byExtendingSelection: false)
    }

    private func findItemForCellView(view: NSView) -> (item: ItemType, index: Int)? {
        let index = tableView.row(for: view)

        if index < 0 {
            return nil
        }

        return (list.items[index], index)
    }

}

// MARK: Private Classes

private final class PrototypeCellView: ItemCellView {

    private var widthConstraint: NSLayoutConstraint?

    func configure(cellView: ItemCellView) {
        text = cellView.text
    }

    func fittingHeightForConstrainedWidth(width: CGFloat) -> CGFloat {
        if let widthConstraint = widthConstraint {
            widthConstraint.constant = width
        } else {
            widthConstraint = NSLayoutConstraint(item: self, attribute: .width, relatedBy: .equal, toItem: nil,
                                                 attribute: .notAnAttribute, multiplier: 1, constant: width)
            addConstraint(widthConstraint!)
        }

        layoutSubtreeIfNeeded()

        // NSTextField's content size must be recalculated after cell size is changed
        textView.invalidateIntrinsicContentSize()
        layoutSubtreeIfNeeded()

        return fittingSize.height
    }

}

private final class SnapshotView: NSView {

    init(sourceView: NSView) {
        super.init(frame: sourceView.frame)

        let imageRepresentation = sourceView.bitmapImageRepForCachingDisplay(in: sourceView.bounds)!
        sourceView.cacheDisplay(in: sourceView.bounds, to: imageRepresentation)

        let snapshotImage = NSImage(size: sourceView.bounds.size)
        snapshotImage.addRepresentation(imageRepresentation)

        wantsLayer = true
        shadow = NSShadow() // Workaround to activate layer-backed shadow

        layer?.contents = snapshotImage
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 5
        layer?.shadowOffset = CGSize(width: -5, height: 0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

}
