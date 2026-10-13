import Foundation
import Testing
@testable import MarkdownCore

private func edit(_ command:MarkdownEditingCommand,_ source:String,_ selection:NSRange,
                  newline:String="\n") throws->(String,NSRange,String) {
    let change=try #require(MarkdownEditing.edit(command,in:source as NSString,
        selection:selection,newline:newline))
    let result=(source as NSString).replacingCharacters(in:change.range,with:change.replacement)
    return (result,change.selection,change.undoName)
}

@Test func inlineStylesWrapInsertAndToggle() throws {
    var result=try edit(.bold,"word",NSRange(location:0,length:4))
    #expect(result.0=="**word**" && result.1==NSRange(location:2,length:4))
    result=try edit(.bold,result.0,result.1)
    #expect(result.0=="word" && result.1==NSRange(location:0,length:4))
    result=try edit(.italic,"",NSRange(location:0,length:0))
    #expect(result.0=="**" && result.1==NSRange(location:1,length:0))
    result=try edit(.strikethrough,"old",NSRange(location:0,length:3))
    #expect(result.0=="~~old~~" && result.2=="Strikethrough")
}

@Test func inlineCodeChoosesAFenceLongerThanItsContent() throws {
    let result=try edit(.inlineCode,"a `tick`",NSRange(location:0,length:8))
    #expect(result.0=="``a `tick```" && result.1==NSRange(location:2,length:8))
}

@Test func linkUsesDestinationAndPreservesLabelSelectionSemantics() throws {
    var result=try edit(.link(destination:"https://example.com/a b"),"Open",NSRange(location:0,length:4))
    #expect(result.0=="[Open](<https://example.com/a b>)")
    #expect((result.0 as NSString).substring(with:result.1)=="<https://example.com/a b>")
    result=try edit(.link(destination:"https://example.com"),"",NSRange(location:0,length:0))
    #expect(result.0=="[](https://example.com)" && result.1==NSRange(location:1,length:0))
}

@Test func headingsAndLinePrefixesOperateOnWholeLines() throws {
    var result=try edit(.heading(2),"first\nsecond\n",NSRange(location:2,length:8))
    #expect(result.0=="## first\n## second\n")
    result=try edit(.paragraph,result.0,NSRange(location:0,length:(result.0 as NSString).length))
    #expect(result.0=="first\nsecond\n")
    result=try edit(.bulletedList,"one\ntwo\n",NSRange(location:0,length:7))
    #expect(result.0=="- one\n- two\n")
    result=try edit(.bulletedList,result.0,NSRange(location:0,length:(result.0 as NSString).length))
    #expect(result.0=="one\ntwo\n")
}

@Test func structuralInsertionsCreateStandaloneBlocksAndHonorCRLF() throws {
    var result=try edit(.table,"before\r\nafter",NSRange(location:6,length:0),newline:"\r\n")
    #expect(result.0=="before\r\n\r\n| Column 1 | Column 2 | Column 3 |\r\n| --- | --- | --- |\r\n|  |  |  |\r\n|  |  |  |\r\n\r\nafter")
    #expect((result.0 as NSString).substring(with:result.1)=="Column 1")
    result=try edit(.codeBlock,"code",NSRange(location:0,length:4))
    #expect(result.0=="```\ncode\n```")
    #expect((result.0 as NSString).substring(with:result.1)=="code")
}

@Test func imageUsesSelectionAsAltText() throws {
    let result=try edit(.image(source:"images/my photo.png"),"Photo",NSRange(location:0,length:5))
    #expect(result.0=="![Photo](<images/my photo.png>)")
    #expect((result.0 as NSString).substring(with:result.1)=="Photo")
}
