import AppKit

/// 课程详情（点击课表格子弹出）。
final class CourseDetailView: NSView {

    private let course: Course

    init(course: Course) {
        self.course = course
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var fittingSize: NSSize {
        NSSize(width: 400, height: 278)
    }

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            // 顶部让开红绿灯（内容视图铺满窗口后，红绿灯浮在这一层左上角）
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 46),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -18),
        ])

        // 标题行：色点 + 课程名 + 代码
        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.backgroundColor = TimetablePalette.accent(for: course).cgColor
        dot.layer?.cornerRadius = 4.5
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 9),
            dot.heightAnchor.constraint(equalToConstant: 9),
        ])

        let nameLabel = NSTextField(labelWithString: course.name)
        nameLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        nameLabel.lineBreakMode = .byWordWrapping
        nameLabel.maximumNumberOfLines = 2

        let codeLabel = NSTextField(labelWithString: "课程代码 \(course.code.isEmpty ? "—" : course.code)")
        codeLabel.font = .systemFont(ofSize: 10.5)
        codeLabel.textColor = .secondaryLabelColor

        let titleStack = NSStackView(views: [nameLabel, codeLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3

        let titleRow = NSStackView(views: [dot, titleStack])
        titleRow.orientation = .horizontal
        titleRow.alignment = .top
        titleRow.spacing = 9
        stack.addArrangedSubview(titleRow)
        titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // 详情行
        let timeRange = "\(Schedule.dayNames[course.day - 1])　第 \(course.block * 2 + 1)–\(course.block * 2 + 2) 节　\(Schedule.timeRange(block: course.block))"
        for (k, v) in [("上课时间", timeRange),
                       ("任课教师", course.teacher.isEmpty ? "—" : course.teacher),
                       ("上课地点", course.loc.isEmpty ? "—" : course.loc),
                       ("上课周次", "第 \(course.weeksLabel) 周")] {
            stack.addArrangedSubview(makeRow(key: k, value: v))
        }

        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func makeRow(key: String, value: String) -> NSView {
        let k = NSTextField(labelWithString: key)
        k.font = .systemFont(ofSize: 11)
        k.textColor = .secondaryLabelColor
        k.translatesAutoresizingMaskIntoConstraints = false
        k.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let v = NSTextField(wrappingLabelWithString: value)
        v.font = .systemFont(ofSize: 12)

        let row = NSStackView(views: [k, v])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        return row
    }
}
