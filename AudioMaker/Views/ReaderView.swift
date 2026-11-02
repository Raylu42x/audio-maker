import AppKit
import SwiftUI

/// Follow-along text. An NSTextView (fast with whole books) that highlights the sentence being read,
/// keeps it centered, underlines bookmarked sentences, and reports clicks on sentences.
struct ReaderView: NSViewRepresentable {
    let docID: String
    let sentences: [Sentence]?
    let plainText: String
    let current: Int?
    let bookmarked: Set<Int>
    @Binding var follow: Bool
    var onTap: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ReaderScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.onUserScroll = { [weak coordinator = context.coordinator] in coordinator?.userScrolled() }

        let tv = ClickTextView(usingTextLayoutManager: false)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 40, height: 28)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.layoutManager?.allowsNonContiguousLayout = true
        tv.onClick = { [weak coordinator = context.coordinator] index in coordinator?.clicked(index) }
        scroll.documentView = tv
        context.coordinator.textView = tv
        context.coordinator.scrollView = scroll
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        let signature = "\(docID)|\(sentences?.count ?? -1)|\(plainText.count)"
        if c.signature != signature {
            c.signature = signature
            c.load(sentences: sentences, plain: plainText)
        }
        if c.bookmarked != bookmarked { c.applyBookmarks(bookmarked) }
        if c.current != current || (follow && !c.wasFollowing) { c.applyCurrent(current, scroll: follow) }
        c.wasFollowing = follow
    }

    final class Coordinator {
        var parent: ReaderView?
        weak var textView: ClickTextView?
        weak var scrollView: NSScrollView?
        var signature = ""
        var ranges: [NSRange] = []
        var current: Int?
        var bookmarked: Set<Int> = []
        var wasFollowing = true
        private var autoScrollUntil = Date.distantPast

        func load(sentences: [Sentence]?, plain: String) {
            guard let tv = textView else { return }
            let body = NSMutableParagraphStyle()
            body.lineHeightMultiple = 1.35
            body.paragraphSpacing = 14
            body.maximumLineHeight = 0
            let font = NSFont(name: "New York", size: 18) ?? NSFont(name: "Iowan Old Style", size: 18) ?? .systemFont(ofSize: 17)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: body]
            let out = NSMutableString()
            ranges = []
            if let sentences {
                var para = sentences.first?.p ?? 0
                for s in sentences {
                    if s.p != para { out.append("\n"); para = s.p }
                    else if out.length > 0 { out.append(" ") }
                    ranges.append(NSRange(location: out.length, length: (s.t as NSString).length))
                    out.append(s.t)
                }
            } else {
                out.append(plain.replacingOccurrences(of: "\n\n", with: "\n"))
            }
            tv.textStorage?.setAttributedString(NSAttributedString(string: out as String, attributes: attrs))
            current = nil
            bookmarked = []
            tv.scroll(.zero)
        }

        func applyCurrent(_ index: Int?, scroll: Bool) {
            guard let tv = textView, let lm = tv.layoutManager else { return }
            if let old = current, old < ranges.count { lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: ranges[old]) }
            current = index
            guard let index, index < ranges.count else { return }
            lm.addTemporaryAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.22), forCharacterRange: ranges[index])
            if scroll { center(ranges[index]) }
        }

        func applyBookmarks(_ set: Set<Int>) {
            guard let lm = textView?.layoutManager else { return }
            for i in bookmarked where i < ranges.count {
                lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: ranges[i])
                lm.removeTemporaryAttribute(.underlineColor, forCharacterRange: ranges[i])
            }
            bookmarked = set
            for i in set where i < ranges.count {
                lm.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue, .underlineColor: NSColor.controlAccentColor],
                                          forCharacterRange: ranges[i])
            }
        }

        private func center(_ range: NSRange) {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer, let clip = scrollView?.contentView else { return }
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            rect.origin.y += tv.textContainerInset.height
            let maxY = max(0, tv.frame.height - clip.bounds.height)
            let y = min(maxY, max(0, rect.midY - clip.bounds.height / 2))
            guard abs(clip.bounds.origin.y - y) > 4 else { return }
            autoScrollUntil = Date().addingTimeInterval(0.6)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                clip.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
            }
            scrollView?.reflectScrolledClipView(clip)
        }

        func userScrolled() {
            guard Date() > autoScrollUntil, parent?.current != nil, parent?.follow == true else { return }
            DispatchQueue.main.async { self.parent?.follow = false }
        }

        func clicked(_ charIndex: Int) {
            guard !ranges.isEmpty else { return }
            // Last sentence starting at or before the click.
            var lo = 0, hi = ranges.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if ranges[mid].location <= charIndex { lo = mid } else { hi = mid - 1 }
            }
            parent?.onTap(lo)
        }
    }
}

final class ReaderScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?
    override func scrollWheel(with event: NSEvent) {
        onUserScroll?()
        super.scrollWheel(with: event)
    }
}

final class ClickTextView: NSTextView {
    var onClick: ((Int) -> Void)?
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)  // runs the selection-tracking loop until mouse up
        guard selectedRange().length == 0 else { return }  // a drag selected text: don't jump
        let p = convert(event.locationInWindow, from: nil)
        onClick?(characterIndexForInsertion(at: p))
    }
}
