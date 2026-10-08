#if DEBUG
import Foundation
import Testing
@testable import MarkdownCore

@Test func diagnosticsAreOptInBoundedAndIgnoreOldSessions() throws {
    let diagnostics=TimingDiagnostics(capacity:3)
    #expect(diagnostics.begin("disabled")==nil)
    var evaluated=false
    func values()->[String:Double] {evaluated=true;return [:]}
    diagnostics.end(nil,values:values())
    #expect(evaluated==false)
    diagnostics.start(sampleMainQueue:false)
    let old=diagnostics.begin("old")
    diagnostics.stop();diagnostics.start(sampleMainQueue:false)
    diagnostics.end(old)
    for i in 0..<5 {let token=diagnostics.begin("event\(i)");diagnostics.end(token,values:["position":Double(i)])}
    diagnostics.stop()
    let snapshot=diagnostics.snapshot()
    #expect(snapshot.events.map{$0.name}==["event2","event3","event4"])
    #expect(snapshot.dropped==2)
    #expect(snapshot.recording==false)
    let before=snapshot.events.count
    diagnostics.reported("disabled",milliseconds:50)
    #expect(diagnostics.snapshot().events.count==before)
    let object=try JSONSerialization.jsonObject(with:snapshot.json(metadata:["fixture":"test"])) as! [String:Any]
    #expect(object["schemaVersion"] as? Int==1)
    #expect((object["summary"] as? [String:Any])?.count==3)
    #expect((object["events"] as? [[String:Any]])?.count==3)
}
@Test func reportedWebDurationsHaveDistinctClockSemantics() {
    let diagnostics=TimingDiagnostics();diagnostics.start(sampleMainQueue:false)
    diagnostics.reported("web.dom.layout",milliseconds:2.5,values:["mounted":12])
    diagnostics.reported("invalid",milliseconds: .nan)
    let events=diagnostics.snapshot().events
    #expect(events.count==1)
    #expect(events.first?.measurement=="reported-duration")
    #expect(events.first?.durationMs==2.5)
}

#endif
