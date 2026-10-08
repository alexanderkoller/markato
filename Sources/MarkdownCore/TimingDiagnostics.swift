#if DEBUG
import Foundation

/// Opt-in, bounded in-memory recording. No logging or file I/O occurs on scroll callbacks.
public final class TimingDiagnostics: @unchecked Sendable {
    public static let shared=TimingDiagnostics()
    public struct Interval:Sendable {
        fileprivate let name:String,start:UInt64,session:UInt64
    }
    public struct Event:Codable,Sendable {
        public let name:String,startMs:Double,durationMs:Double,thread:String,measurement:String
        public let values:[String:Double]
    }
    public struct Snapshot:Sendable {
        public let events:[Event],dropped:Int,started:Date,elapsedMs:Double
        public let recording:Bool
        public func json(metadata:[String:String]=[:]) throws -> Data {
            struct Summary:Codable {let count:Int,totalMs:Double,medianMs:Double,p95Ms:Double,maxMs:Double}
            struct Report:Codable {
                let schemaVersion:Int,started:Date,elapsedMs:Double,recording:Bool,droppedEvents:Int
                let metadata:[String:String],notes:[String],summary:[String:Summary],events:[Event]
            }
            var summary=[String:Summary]()
            for (name,items) in Dictionary(grouping:events,by:{$0.name}) {
                let times=items.map{$0.durationMs}.sorted()
                summary[name]=Summary(count:times.count,totalMs:times.reduce(0,+),medianMs:times[times.count/2],p95Ms:times[min(times.count-1,Int(Double(times.count)*0.95))],maxMs:times.last ?? 0)
            }
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(Report(schemaVersion:1,started:started,elapsedMs:elapsedMs,recording:recording,droppedEvents:dropped,metadata:metadata,notes:[
                "Native intervals use monotonic uptime. Nested intervals overlap; totals must not be added across categories.",
                "Durations are elapsed time, not CPU time; asynchronous image preparation includes I/O waits. Only completed intervals are retained.",
                "WebKit reported-duration events are timestamped at native receipt, not at their JavaScript execution start. JavaScript clock resolution may be about 1 ms.",
                "Clip movement, DOM layout, JavaScript callbacks and requestAnimationFrame do not measure actual displayed-frame presentation.",
                "main.queue.wait samples dispatch delay about ten times per second; it is not a frame-rate measurement.",
                "Only the most recent events are retained when the bounded recorder fills. No document text or file paths are included."
            ],summary:summary,events:events.sorted{$0.startMs<$1.startMs}))
        }
    }
    private let lock=NSLock()
    private let capacity:Int
    private var storage=[Event]()
    private var next=0,total=0
    private var session:UInt64=0
    private var started=Date(),epoch:UInt64=0,stopped:UInt64=0
    private var enabled=false
    private var timer:DispatchSourceTimer?
    public init(capacity:Int=20000) {self.capacity=max(1,capacity);storage.reserveCapacity(self.capacity)}
    public var isRecording:Bool {lock.lock();defer{lock.unlock()};return enabled}
    public var hasEvents:Bool {lock.lock();defer{lock.unlock()};return !storage.isEmpty}
    public func start(sampleMainQueue:Bool=true) {
        lock.lock();timer?.cancel();timer=nil;session &+= 1;storage.removeAll(keepingCapacity:true)
        next=0;total=0;started=Date();epoch=DispatchTime.now().uptimeNanoseconds;stopped=epoch;enabled=true
        if sampleMainQueue {
            let timer=DispatchSource.makeTimerSource(queue:DispatchQueue.global(qos:.utility))
            timer.schedule(deadline:.now()+0.1,repeating:0.1,leeway:.milliseconds(2))
            timer.setEventHandler { [weak self] in
                guard let self,let interval=self.begin("main.queue.wait") else{return}
                DispatchQueue.main.async {self.end(interval)}
            }
            self.timer=timer;timer.resume()
        }
        lock.unlock()
    }
    public func stop() {lock.lock();enabled=false;stopped=DispatchTime.now().uptimeNanoseconds;timer?.cancel();timer=nil;lock.unlock()}
    public func begin(_ name:String)->Interval? {
        lock.lock();defer{lock.unlock()};guard enabled else{return nil}
        return Interval(name:name,start:DispatchTime.now().uptimeNanoseconds,session:session)
    }
    public func end(_ interval:Interval?,values:@autoclosure ()->[String:Double]=[:]) {
        guard let interval else{return};let now=DispatchTime.now().uptimeNanoseconds
        lock.lock();defer{lock.unlock()};guard enabled,session==interval.session else{return}
        append(Event(name:interval.name,startMs:Double(interval.start-epoch)/1e6,durationMs:Double(now-interval.start)/1e6,thread:Thread.isMainThread ? "main":"worker",measurement:"native-interval",values:values()))
    }
    public func reported(_ name:String,milliseconds:Double,values:[String:Double]=[:]) {
        guard milliseconds.isFinite,milliseconds>=0 else{return}
        lock.lock();defer{lock.unlock()};guard enabled else{return}
        append(Event(name:name,startMs:Double(DispatchTime.now().uptimeNanoseconds-epoch)/1e6,durationMs:milliseconds,thread:"web",measurement:"reported-duration",values:values))
    }
    private func append(_ event:Event) {
        total += 1
        if storage.count<capacity {storage.append(event)} else {storage[next]=event;next=(next+1)%capacity}
    }
    public func snapshot()->Snapshot {
        lock.lock();defer{lock.unlock()}
        let events=storage.count==capacity ? Array(storage[next...])+Array(storage[..<next]):storage
        let end=enabled ? DispatchTime.now().uptimeNanoseconds:stopped
        return Snapshot(events:events,dropped:max(0,total-capacity),started:started,elapsedMs:epoch==0 ? 0:Double(end-epoch)/1e6,recording:enabled)
    }
}

#endif
