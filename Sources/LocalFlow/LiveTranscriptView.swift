import AppKit
import SwiftUI

/// TextKit lays out the new tail before scrolling. No lazy SwiftUI row estimates,
/// delayed scroll animation, or four-line clipping during a long recording.
struct LiveTranscriptView: NSViewRepresentable {
    var stable: String
    var draft: String = ""
    var fontSize: CGFloat = 15
    func makeNSView(context: Context) -> TranscriptScrollView {
        let scroll = TranscriptScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        let text = NSTextView(frame: .zero)
        text.isEditable = false; text.isSelectable = true; text.drawsBackground = false
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.textContainerInset = NSSize(width: 0, height: 2)
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: TranscriptScrollView, context: Context) {
        scroll.apply(stable: stable, draft: draft, fontSize: fontSize)
    }
}
final class TranscriptScrollView: NSScrollView {
    var lastText = ""
    var confirmedCount = 0
    var followTail = false
    func apply(stable: String, draft: String, fontSize: CGFloat) {
        guard let text = documentView as? NSTextView, let storage = text.textStorage else { return }
        let confirmed = stable + (stable.isEmpty || draft.isEmpty ? "" : " ")
        let value = confirmed + draft
        guard self.lastText != value || self.confirmedCount != confirmed.utf16.count else { return }
        let old = storage.string
        var prefix = zip(old.utf16, value.utf16).prefix { $0 == $1 }.count
        if prefix > 0 && prefix < value.utf16.count {
            let previous = Array(value.utf16)[prefix - 1]
            if (0xD800...0xDBFF).contains(previous) { prefix -= 1 }
        }
        // NSString ranges deliberately use UTF-16, including emoji and Cyrillic.
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: prefix, length: old.utf16.count - prefix), with: (value as NSString).substring(from: prefix))
        storage.setAttributes([.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.labelColor], range: NSRange(location: 0, length: storage.length))
        if !draft.isEmpty { storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: confirmed.utf16.count, length: draft.utf16.count)) }
        storage.endEditing()
        self.lastText = value; self.confirmedCount = confirmed.utf16.count
        self.followTail = true; self.needsLayout = true
    }
    override func layout() {
        super.layout()
        guard let text = documentView as? NSTextView, let container = text.textContainer, let manager = text.layoutManager else { return }
        container.containerSize = NSSize(width: contentSize.width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        text.setFrameSize(NSSize(width: contentSize.width, height: max(contentSize.height, manager.usedRect(for: container).height + 4)))
        if followTail { followTail = false; text.scrollRangeToVisible(NSRange(location: text.string.utf16.count, length: 0)) }
    }
}
