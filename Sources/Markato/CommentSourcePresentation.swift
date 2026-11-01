import AppKit

@MainActor enum CommentSourcePreferences {
    static var defaults=UserDefaults.standard
    static let key="ShowCommentSource"
    static let didChange=Notification.Name("MarkatoCommentSourceVisibilityChanged")
    static var isShown:Bool {
        get {defaults.bool(forKey:key)}
        set {
            guard newValue != isShown else{return}
            defaults.set(newValue,forKey:key)
            NotificationCenter.default.post(name:didChange,object:nil)
        }
    }
}

/// Keep source coordinates intact while removing metadata from glyph layout.
/// Zero-advance control glyphs suppress both text and paragraph breaks,
/// including records at the very beginning of a document.
@MainActor final class CommentSourcePresentation:NSObject,@preconcurrency NSLayoutManagerDelegate {
    var hiddenRanges=[NSRange]()

    func hiddenRange(at offset:Int)->NSRange? {
        var low=0,high=hiddenRanges.count
        while low<high {
            let middle=(low+high)/2
            if NSMaxRange(hiddenRanges[middle])<=offset {low=middle+1}else{high=middle}
        }
        guard low<hiddenRanges.count,NSLocationInRange(offset,hiddenRanges[low]) else{return nil}
        return hiddenRanges[low]
    }

    func layoutManager(_ manager:NSLayoutManager,shouldUse action:NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt index:Int)->NSLayoutManager.ControlCharacterAction {
        hiddenRange(at:index) == nil ? action:.zeroAdvancement
    }

    func layoutManager(_ manager:NSLayoutManager,shouldGenerateGlyphs glyphs:UnsafePointer<CGGlyph>,
                       properties props:UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes indices:UnsafePointer<Int>,font:NSFont,forGlyphRange range:NSRange)->Int {
        guard !hiddenRanges.isEmpty,range.length>0 else{return 0}
        var properties=Array(UnsafeBufferPointer(start:props,count:range.length)),changed=false
        for index in 0..<range.length where hiddenRange(at:indices[index]) != nil {
            properties[index] = .controlCharacter;changed=true
        }
        guard changed else{return 0}
        manager.setGlyphs(glyphs,properties:properties,characterIndexes:indices,font:font,forGlyphRange:range)
        return range.length
    }
}
