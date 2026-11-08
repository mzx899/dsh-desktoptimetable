import AppKit

/// 图钉按钮的**离屏渲染**（自检 / 出图用）。
///
/// 把图钉在两种状态（未固定 / 已固定）各画一张 PNG，
/// 用来肉眼确认「空心」和「实心」只有填充差异、形状和位置完全一致，
/// 也用来给 README 出图。
enum PushPinRenderer {

    /// 渲染一张图钉图（`size` pt 见方，2 倍图）。
    ///
    /// - Parameters:
    ///   - pinned: true = 已固定（实心）；false = 未固定（空心）。
    ///   - background: 底色（毛玻璃卡片那种深色）。
    static func render(pinned: Bool, size: CGFloat = 20,
                       scale: CGFloat = 2,
                       background: NSColor = NSColor(srgbRed: 0.10, green: 0.11,
                                                    blue: 0.14, alpha: 1)) -> NSImage? {
        let pixels = Int(size * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.scaleBy(x: scale, y: scale)

        background.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()

        let button = PushPinButton(frame: NSRect(x: 0, y: 0, width: size, height: size))
        button.isPinned = pinned
        // 悬停底色别影响截图 —— 这里只画「常态」外观。
        button.layer?.backgroundColor = nil
        button.displayIgnoringOpacity(button.bounds, in: ctx)

        NSGraphicsContext.restoreGraphicsState()
        return NSImage(data: rep.representation(using: .png, properties: [:]) ?? Data())
    }

    /// 把两种状态并排画成一张对照图（左边未固定，右边已固定）。
    static func renderComparison(background: NSColor = NSColor(srgbRed: 0.10, green: 0.11,
                                                                blue: 0.14, alpha: 1)) -> NSImage? {
        let cell: CGFloat = 28
        let gap: CGFloat = 8
        let scale: CGFloat = 4
        let width = cell * 2 + gap
        let height = cell
        let pixelsW = Int(width * scale), pixelsH = Int(height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixelsW, pixelsHigh: pixelsH,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.scaleBy(x: scale, y: scale)
        background.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        for (index, pinned) in [false, true].enumerated() {
            let button = PushPinButton(frame: NSRect(x: 0, y: 0, width: cell, height: cell))
            button.isPinned = pinned
            button.layer?.backgroundColor = nil
            // 手动平移上下文 —— `displayIgnoringOpacity` 不会按视图 origin 自己偏移。
            ctx.cgContext.saveGState()
            ctx.cgContext.translateBy(x: CGFloat(index) * (cell + gap), y: 0)
            button.displayIgnoringOpacity(button.bounds, in: ctx)
            ctx.cgContext.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        return NSImage(data: rep.representation(using: .png, properties: [:]) ?? Data())
    }
}
