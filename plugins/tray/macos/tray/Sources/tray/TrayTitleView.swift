import AppKit

final class TrayTitleView: NSView {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    static let width = ceil(("8888 MB/s" as NSString).size(withAttributes: [.font: font]).width)

    private var lines: [NSAttributedString] = [] {
        didSet { needsDisplay = true }
    }

    private var titleWidth: CGFloat = TrayTitleView.width

    private let attributes: [NSAttributedString.Key: Any] = [
        .font: TrayTitleView.font,
        .foregroundColor: NSColor.labelColor,
    ]

    override var isFlipped: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: titleWidth, height: NSView.noIntrinsicMetric)
    }

    func setTitle(_ title: String) -> Bool {
        let wasHidden = isHidden
        let previousWidth = titleWidth

        lines = title.isEmpty
            ? []
            : title.components(separatedBy: "\n").map {
                NSAttributedString(string: $0, attributes: attributes)
            }
        let textWidth = lines.map { ceil($0.size().width) }.max() ?? 0
        titleWidth = max(TrayTitleView.width, textWidth)
        isHidden = title.isEmpty

        let widthChanged = titleWidth != previousWidth
        if widthChanged {
            invalidateIntrinsicContentSize()
        }
        return wasHidden != isHidden || widthChanged
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !lines.isEmpty else {
            return
        }
        let lineHeight = lines.map { $0.size().height }.max() ?? 0
        let lineStep = min(lineHeight, bounds.height / CGFloat(lines.count))
        let blockHeight = lineHeight + lineStep * CGFloat(lines.count - 1)
        let scale = window?.backingScaleFactor ?? 2
        var y = (bounds.height - blockHeight) / 2
        for line in lines {
            let x = bounds.width - line.size().width
            line.draw(at: NSPoint(x: x, y: (y * scale).rounded() / scale))
            y += lineStep
        }
    }
}
