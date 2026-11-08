import AppKit

/// 课表管理面板（独立窗口）。
///
/// 列出所有课表，当前项打勾，可以新建 / 切换 / 重命名 / 删除 / 导入。
///
/// 设置面板里也放一个「课表」卡片（见 `SettingsWindowController`），
/// 两边共用这个控制器的逻辑。
final class TimetableManagerController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    // MARK: - 依赖与回调

    private let store: TimetableStore
    /// 切换课表后刷新桌面卡片。
    var onSwitch: ((Timetable) -> Void)?
    /// 课表集合变了（新增 / 删除 / 重命名 / 切换）—— 无论切换到哪一份都要通知。
    ///
    /// 以前只有 `onSwitch`，而删除逻辑是
    /// `if let nextID = next, let t = try? store.load(nextID) { onSwitch?(t) }` ——
    /// 删掉**最后一份**课表时 `next == nil`，回调不触发，
    /// 于是 `AppDelegate` 不 `reloadData` / `refreshCard` / 刷新设置面板 / 重建菜单栏：
    /// 桌面卡片继续显示已删课表的课程，右键菜单和菜单栏也是旧数据。
    var onTimetablesChanged: (() -> Void)?
    /// 导入课表。
    var onImport: (() -> Void)?

    // MARK: - UI

    private var window: NSWindow!
    private var tableView: NSTableView!
    private var infoLabel: NSTextField!

    init(store: TimetableStore) {
        self.store = store
        super.init()
    }

    // MARK: - 数据

    private var metas: [TimetableMeta] { store.allMetas() }
    private var activeID: String? { store.activeID }

    // MARK: - 展示

    func show() {
        if window == nil { buildWindow() }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "课表管理"
        w.delegate = self
        w.isReleasedWhenClosed = false
        // 与设置面板同层：这两个窗是从设置面板里点出来的，必须压在面板上面
        w.level = .floating
        w.minSize = NSSize(width: 400, height: 320)
        // 摆在**课表窗口当前中心**（以前是屏幕正中间，课表拖走后弹窗离得很远）
        HUDWindow.centerOnScreen(w)
        window = w

        let root = NSView(frame: w.contentView!.bounds)
        w.contentView = root

        // ---- 列表 ----
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let tv = NSTableView()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("t"))
        col.title = "课表"
        col.width = 260
        tv.addTableColumn(col)
        tv.dataSource = self
        tv.delegate = self
        tv.headerView = nil
        tv.rowHeight = 26
        scroll.documentView = tv
        tableView = tv

        // ---- 信息 ----
        infoLabel = NSTextField(labelWithString: "")
        infoLabel.font = .systemFont(ofSize: 12)
        infoLabel.textColor = .secondaryLabelColor

        // ---- 按钮 ----
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let newBtn = NSButton(title: "新建…", target: self, action: #selector(newTapped))
        let renameBtn = NSButton(title: "重命名…", target: self, action: #selector(renameTapped))
        let deleteBtn = NSButton(title: "删除…", target: self, action: #selector(deleteTapped))
        let importBtn = NSButton(title: "导入课表…", target: self, action: #selector(importTapped))
        for b in [newBtn, renameBtn, deleteBtn, importBtn] {
            buttons.addArrangedSubview(b)
        }

        for v in [scroll, infoLabel, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            infoLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            infoLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            infoLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            buttons.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
    }

    private func refresh() {
        tableView.reloadData()
        let count = metas.count
        infoLabel.stringValue = count == 0
            ? "还没有课表。"
            : "共 \(count) 份课表。双击列表里的课表可以切换。"
    }

    // MARK: - 表格

    func numberOfRows(in tableView: NSTableView) -> Int { metas.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < metas.count else { return nil }
        let meta = metas[row]
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: meta.name)
        text.font = .systemFont(ofSize: 13, weight: meta.id == activeID ? .semibold : .regular)
        text.textColor = meta.id == activeID ? .controlAccentColor : .labelColor
        cell.addSubview(text)
        cell.textField = text
        text.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// 双击才切换（单击只选中）—— 避免误触。
    func tableView(_ tableView: NSTableView, doubleClickedRow row: Int) {
        switchTo(row: row)
    }

    // MARK: - 动作

    /// 切换到第 row 份课表。
    func switchTo(row: Int) {
        guard row >= 0, row < metas.count else { return }
        let meta = metas[row]
        guard meta.id != activeID else { return }
        do {
            try store.setActive(meta.id)
            if let t = try? store.load(meta.id) {
                onSwitch?(t)
            }
            refresh()
        } catch {
            presentError("切换失败：\(error.localizedDescription)")
        }
    }

    /// 切换到指定 ID 的课表。
    @discardableResult
    func switchTo(id: String) -> Bool {
        guard let idx = metas.firstIndex(where: { $0.id == id }) else { return false }
        switchTo(row: idx)
        return true
    }

    @objc private func newTapped() {
        // 新建 → 复用 `TimetableNameDialog`（自建 HUD 输入窗）。
        guard let result = TimetableNameDialog.run(
            title: "新建课表",
            message: "创建一份空课表，之后可以导入课表内容。",
            name: "新课表",
            subtitle: "",
            confirmTitle: "创建",
            showsSubtitle: false) else { return }

        var name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "新课表" }
        // 重名自动加后缀
        let existing = Set(metas.map { $0.name })
        if existing.contains(name) {
            var i = 2
            while existing.contains("\(name) \(i)") { i += 1 }
            name = "\(name) \(i)"
        }

        do {
            let t = try store.create(name: name)
            try store.setActive(t.id)
            onSwitch?(t)
            refresh()
        } catch {
            presentError("新建失败：\(error.localizedDescription)")
        }
    }

    @objc private func renameTapped() {
        let row = tableView.selectedRow
        guard row >= 0, row < metas.count else { return }
        let meta = metas[row]

        // 重命名 → 复用 `TimetableNameDialog`（名称 + 副标题）。
        guard let result = TimetableNameDialog.run(
            title: "重命名课表",
            message: "只改名字和副标题，不影响课程数据。",
            name: meta.name,
            subtitle: meta.subtitle,
            confirmTitle: "保存") else { return }

        var name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = meta.name }
        let subtitle = result.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try store.rename(id: meta.id, name: name, subtitle: subtitle)
            // 当前课表改名 → 卡片标题跟着变
            if meta.id == activeID, let t = try? store.load(meta.id) {
                onSwitch?(t)
            }
            refresh()
        } catch {
            presentError("重命名失败：\(error.localizedDescription)")
        }
    }

    @objc private func deleteTapped() {
        let row = tableView.selectedRow
        guard row >= 0, row < metas.count else { return }
        let meta = metas[row]
        let isActive = meta.id == activeID
        let others = metas.filter { $0.id != meta.id }

        // 还有其他课表 → 提示并说明会切到哪一份。
        // 「切到哪一份」必须问 store 本身（`nextActiveIDAfterDeleting`），
        // 因为 `delete()` 实际切到的是索引里的第一份，
        // 而 `others[0]` 是按更新时间倒序的第一份 —— 两者常常不是同一份，
        // 提示会报错课表名字。
        let nextID = store.nextActiveIDAfterDeleting(id: meta.id)
        let nextName = nextID.flatMap { id in metas.first { $0.id == id }?.name }

        let message: String
        if others.isEmpty {
            message = "这是最后一份课表。删除后进入空课表状态。"
        } else if isActive, let nextName {
            message = "这是当前课表。删除后会切换到「\(nextName)」。"
        } else {
            message = "删除后无法恢复。"
        }

        // 删除课表 → 危险样式（红色主操作 + 默认焦点给「取消」）。
        let outcome = AlertDialogController.show(.init(
            severity: .destructive,
            title: "删除课表「\(meta.name)」？",
            message: message + "\n\n删除前会备份整个课表目录。",
            confirmTitle: "删除",
            cancelTitle: "取消"))
        guard case .confirmed = outcome else { return }

        do {
            let next = try store.delete(id: meta.id)
            if let nextID = next, let t = try? store.load(nextID) {
                onSwitch?(t)
            }
            refresh()
            // **不管有没有切到下一份，都要通知上层**：
            // 删掉最后一份时 `next == nil`，但卡片 / 设置面板 / 菜单栏
            // 必须进入「空课表」状态，不能继续显示已删课表的课程。
            onTimetablesChanged?()
        } catch {
            presentError("删除失败：\(error.localizedDescription)")
        }
    }

    @objc private func importTapped() {
        onImport?()
    }

    private func presentError(_ message: String) {
        AlertDialogController.show(.init(
            severity: .warning,
            title: "操作失败",
            message: message,
            confirmTitle: "好",
            showsCancel: false))
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { true }
}
