import Foundation
import MarkdownCore
import Testing

private func requireEndpointRoundTrip(_ source:String,_ range:NSRange,
                                      comment:MarkdownComment) throws {
    let exact=(source as NSString).substring(with:range)
    let encoded=MarkdownComments.serialize(comment)
    if let start=comment.anchor.startExact,let end=comment.anchor.endExact {
        let selected=exact as NSString
        let first=selected.range(of:start)
        let last=selected.range(of:end,options:.backwards)
        #expect(first.location==0)
        #expect(NSMaxRange(last)==selected.length)
        let interiorAfterStart=NSRange(location:NSMaxRange(first),
            length:max(0,selected.length-NSMaxRange(first)))
        let interiorBeforeEnd=NSRange(location:0,length:max(0,last.location))
        #expect(selected.range(of:start,range:interiorAfterStart).location==NSNotFound)
        #expect(selected.range(of:end,range:interiorBeforeEnd).location==NSNotFound)
        #expect(encoded.contains(" ... "))
    }
    let insertion=MarkdownComments.insertion(for:comment,in:source,at:NSMaxRange(range))
    let document=(source as NSString).replacingCharacters(
        in:NSRange(location:NSMaxRange(range),length:0),with:insertion)
    let parsed=try #require(MarkdownComments.records(in:document).first)
    #expect(parsed.anchorRange==range)
    #expect(parsed.comment.anchor.exact==exact)
    #expect(parsed.comment.body==comment.body)
}

@Test func compactEndpointsEndAndBeginOnWholeUnicodeWords() throws {
    let selected="Opening außergewöhnlicherweise continues through **Markdown punctuation**, "
        + String(repeating:"middle material ",count:8)
        + "before abschließend unmistakably."
    let source="Before.\n\n\(selected)\n\nAfter."
    let range=(source as NSString).range(of:selected)
    let comment=MarkdownComments.comment(in:source,selection:range,body:"Whole words",author:"")
    let start=try #require(comment.anchor.startExact)
    let end=try #require(comment.anchor.endExact)
    #expect(start=="Opening außergewöhnlicherweise")
    #expect(end=="abschließend unmistakably.")
    try requireEndpointRoundTrip(source,range,comment:comment)
}

@Test func compactEndpointsKeepMarkdownDelimitersButNeverCutTheirWords() throws {
    let selected="**Remarkable opening phrase** introduces [linked material](https://example.test), "
        + String(repeating:"ordinary middle words ",count:7)
        + "and finishes with `distinctive closing phrase`."
    let source="\(selected)\n"
    let range=(source as NSString).range(of:selected)
    let comment=MarkdownComments.comment(in:source,selection:range,body:"Markup",author:"")
    let start=try #require(comment.anchor.startExact)
    let end=try #require(comment.anchor.endExact)
    #expect(start.hasPrefix("**Remarkable"))
    #expect(!start.hasSuffix("open") && !start.hasSuffix("phra"))
    #expect(end=="closing phrase`.")
    try requireEndpointRoundTrip(source,range,comment:comment)
}

@Test func unboundedIdentifierFallsBackInsteadOfCuttingAWord() {
    let giant=String(repeating:"a",count:140)
    let selected="\(giant) middle \(giant)"
    let comment=MarkdownComments.comment(in:selected,
        selection:NSRange(location:0,length:selected.utf16.count),body:"No fragments",author:"")
    #expect(comment.anchor.startExact==nil)
    #expect(comment.anchor.endExact==nil)
    #expect(MarkdownComments.serialize(comment).contains(selected))
}

@Test func endpointPairsSurviveRepeatedSurroundingPassagesAndInternalDecoys() throws {
    let opening="Opening phrase shared by several passages"
    let closing="closing phrase shared by several passages."
    let decoy="\(opening). A short unrelated passage has the \(closing)"
    let selected="""
    \(opening), followed by target-only αβγ text and **Markdown**.

    The interior repeats short fragments: Opening phrase; closing phrase; 😀; and a quoted "endpoint".

    A target-only final paragraph ends with the \(closing)
    """
    let source=decoy+"\n\n"+decoy+"\n\n"+selected+"\n\n"+decoy
    let range=(source as NSString).range(of:selected)
    let comment=MarkdownComments.comment(in:source,selection:range,body:"Target passage",author:"")
    try requireEndpointRoundTrip(source,range,comment:comment)
}

@Test func endpointPairsHandleUnicodeCRLFMarkupEscapesAndLiteralEllipsis() throws {
    let selected="Start 🧑🏽‍💻 e\u{301} **bold** \\\"quoted\" -- literal … marker\r\n\r\n"
        + String(repeating:"middle 🧮 `code` -\\- text \r\n",count:8)
        + "Finish 🇩🇪 with [a link](https://example.test/a?b=1)."
    let source="Prefix decoy Finish 🇩🇪.\r\n\r\n\(selected)\r\n\r\nSuffix"
    let range=(source as NSString).range(of:selected)
    let comment=MarkdownComments.comment(in:source,selection:range,
        body:"Body with a--b, -->, \\, and …",author:"")
    try requireEndpointRoundTrip(source,range,comment:comment)
}

@Test func endpointPairsRecomputeWhenOldEndpointsAreCopiedIntoTheInterior() throws {
    var selected="Unique opening boundary identifies this selection. "
        + String(repeating:"ordinary middle words ",count:10)
        + "Unique closing boundary identifies its end."
    var source="Before.\n\n\(selected)\n\nAfter."
    var range=(source as NSString).range(of:selected)
    var comment=MarkdownComments.comment(in:source,selection:range,body:"Collision",author:"")
    let oldStart=try #require(comment.anchor.startExact)
    let oldEnd=try #require(comment.anchor.endExact)
    let insertion=" \(oldStart) interior collision \(oldEnd) "
    let middle=range.location+range.length/2
    source=(source as NSString).replacingCharacters(in:NSRange(location:middle,length:0),with:insertion)
    range.length += insertion.utf16.count
    selected=(source as NSString).substring(with:range)
    comment=MarkdownComments.updateAnchor(of:comment,to:range,in:source)
    #expect(comment.anchor.exact==selected)
    #expect(comment.anchor.startExact != oldStart || comment.anchor.endExact != oldEnd
        || !MarkdownComments.serialize(comment).contains(" ... "))
    try requireEndpointRoundTrip(source,range,comment:comment)
}

@Test func endpointPairsTrackBoundaryReplacementDeletionAndWholeAnchorReplacement() throws {
    let originals=[
        "Changed opening "+String(repeating:"middle text ",count:10)+"stable closing.",
        "stable opening "+String(repeating:"middle text ",count:10)+"changed closing.",
        "Both boundaries changed "+String(repeating:"new middle 😀 ",count:10)+"and this is the new end.",
    ]
    for (index,selected) in originals.enumerated() {
        let source="Earlier copy changed opening stable closing.\n\n\(selected)\n\nLater text."
        let range=(source as NSString).range(of:selected)
        var stale=MarkdownComments.comment(in:source,selection:range,body:"Edit \(index)",author:"")
        stale.anchor.startExact="obsolete start"
        stale.anchor.endExact="obsolete end"
        let updated=MarkdownComments.updateAnchor(of:stale,to:range,in:source)
        #expect(updated.anchor.startExact != "obsolete start")
        #expect(updated.anchor.endExact != "obsolete end")
        try requireEndpointRoundTrip(source,range,comment:updated)
    }
}

@Test func endpointPairsRemainResolvableAcrossLongDeterministicEditSequence() throws {
    let selected="Sequence opening zero "+String(repeating:"repeatable middle material ",count:14)
        + "sequence closing zero."
    var source="Earlier sequence opening zero decoy.\n\n\(selected)\n\nFollowing text."
    var range=(source as NSString).range(of:selected)
    var comment=MarkdownComments.comment(in:source,selection:range,body:"Sequence",author:"")
    var state:UInt64=0xC0FFEE
    func random(_ upper:Int)->Int {
        state=state &* 6364136223846793005 &+ 1442695040888963407
        return upper==0 ? 0:Int((state >> 32) % UInt64(upper))
    }
    let insertions=["😀"," **bold** ","\r\nbridge\r\n"," … "," \\\\ -- ","alpha"]
    for step in 0..<240 {
        let local=random(max(1,range.length))
        let location=range.location+min(local,max(0,range.length-1))
        let removable=min(random(4),NSMaxRange(range)-location)
        let replacement=insertions[random(insertions.count)]+String(step%10)
        let edit=SourceEdit(range:NSRange(location:location,length:removable),
            insertedLength:replacement.utf16.count)
        source=(source as NSString).replacingCharacters(in:edit.range,with:replacement)
        range=MarkdownComments.transformedAnchorRange(range,through:edit)
        comment=MarkdownComments.updateAnchor(of:comment,to:range,in:source)
        #expect(comment.anchor.exact==(source as NSString).substring(with:range))
        if step%8==0 || step==239 {
            try requireEndpointRoundTrip(source,range,comment:comment)
        }
    }
}

@Test func liveAnchorRefreshIgnoresItsOwnSerializedEndpointCopies() throws {
    let selected="Live refresh opening "+String(repeating:"substantial anchor material ",count:12)
        + "live refresh closing."
    let source="Before.\n\n\(selected)"
    let range=(source as NSString).range(of:selected)
    let initial=MarkdownComments.comment(in:source,selection:range,body:"Readable body",author:"")
    let document=source+MarkdownComments.insertion(for:initial,in:source,at:NSMaxRange(range))
    let parsed=try #require(MarkdownComments.records(in:document).first)
    let recordStart=parsed.recordRange.location
    let context=NSRange(location:range.location,length:recordStart-range.location)
    let refreshed=MarkdownComments.updateAnchor(of:parsed.comment,to:range,in:document,
        selectorContext:context)
    #expect(refreshed.anchor.startExact != nil)
    #expect(refreshed.anchor.endExact != nil)
    #expect(MarkdownComments.serialize(refreshed).contains(" ... "))
}

@Test func completeEndpointPairInsertedInGapForcesUnambiguousExactSelector() throws {
    let selected="Gap collision opening "+String(repeating:"middle material ",count:12)
        + "gap collision closing."
    let source="Before.\n\n\(selected)"
    let range=(source as NSString).range(of:selected)
    let initial=MarkdownComments.comment(in:source,selection:range,body:"Gap collision",author:"")
    var document=source+MarkdownComments.insertion(for:initial,in:source,at:NSMaxRange(range))
    let original=try #require(MarkdownComments.records(in:document).first)
    let intruder="\n\(selected.prefix(96)) unrelated intervening text \(selected.suffix(96))\n"
    document=(document as NSString).replacingCharacters(
        in:NSRange(location:NSMaxRange(range),length:0),with:intruder)
    let shiftedRecord=NSRange(location:original.recordRange.location+intruder.utf16.count,
        length:original.recordRange.length)
    let context=NSRange(location:range.location,length:shiftedRecord.location-range.location)
    let refreshed=MarkdownComments.updateAnchor(of:original.comment,to:range,in:document,
        selectorContext:context)
    #expect(refreshed.anchor.startExact==nil)
    #expect(refreshed.anchor.endExact==nil)
    #expect(!MarkdownComments.serialize(refreshed).contains(" ... "))

    let replacement=MarkdownComments.serialize(refreshed)
    document=(document as NSString).replacingCharacters(in:shiftedRecord,with:replacement)
    let reopened=try #require(MarkdownComments.records(in:document).first)
    #expect(reopened.anchorRange==range)
    #expect(reopened.comment.anchor.exact==selected)
    #expect(reopened.comment.body=="Gap collision")
}

@Test func shortEndpointCollisionLengthensEndpointsAndStaysCompact() throws {
    let selected="Adaptive opening "+String(repeating:"substantial middle words ",count:14)
        + "adaptive closing."
    let source="Before.\n\n\(selected)"
    let range=(source as NSString).range(of:selected)
    let initial=MarkdownComments.comment(in:source,selection:range,body:"Adaptive",author:"")
    let oldStart=try #require(initial.anchor.startExact)
    let oldEnd=try #require(initial.anchor.endExact)
    var document=source+MarkdownComments.insertion(for:initial,in:source,at:NSMaxRange(range))
    let original=try #require(MarkdownComments.records(in:document).first)
    let intruder="\n\(oldStart) collision \(oldEnd)\n"
    document=(document as NSString).replacingCharacters(
        in:NSRange(location:NSMaxRange(range),length:0),with:intruder)
    let recordStart=original.recordRange.location+intruder.utf16.count
    let context=NSRange(location:range.location,length:recordStart-range.location)
    let refreshed=MarkdownComments.updateAnchor(of:original.comment,to:range,in:document,
        selectorContext:context)
    let newStart=try #require(refreshed.anchor.startExact)
    let newEnd=try #require(refreshed.anchor.endExact)
    #expect(newStart != oldStart)
    #expect(newEnd != oldEnd)
    #expect(newStart.count>oldStart.count)
    #expect(newEnd.count>oldEnd.count)
    #expect(MarkdownComments.serialize(refreshed).contains(" ... "))
}

@Test func isolatedEndpointFragmentsInGapDoNotNeedlesslyExpandSelector() throws {
    let selected="Fragment safety opening "+String(repeating:"long anchor content ",count:10)
        + "fragment safety closing."
    let source="Before.\n\n\(selected)"
    let range=(source as NSString).range(of:selected)
    for endpoint in [0,1] {
        let initial=MarkdownComments.comment(in:source,selection:range,body:"Fragment",author:"")
        let fragment=try #require(endpoint==0 ? initial.anchor.startExact:initial.anchor.endExact)
        var document=source+MarkdownComments.insertion(for:initial,in:source,at:NSMaxRange(range))
        let original=try #require(MarkdownComments.records(in:document).first)
        let insertion="\n\(fragment)\n"
        document=(document as NSString).replacingCharacters(
            in:NSRange(location:NSMaxRange(range),length:0),with:insertion)
        let recordStart=original.recordRange.location+insertion.utf16.count
        let context=NSRange(location:range.location,length:recordStart-range.location)
        let refreshed=MarkdownComments.updateAnchor(of:original.comment,to:range,in:document,
            selectorContext:context)
        #expect(refreshed.anchor.startExact != nil)
        #expect(refreshed.anchor.endExact != nil)
        #expect(MarkdownComments.serialize(refreshed).contains(" ... "))
    }
}
