// In-process observer for a private, ad-hoc-signed MarkViewer copy.
// It does not replace or swizzle MarkViewer's editor, parser, or renderer.
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <mach/mach.h>

static NSDictionary<NSString *, NSString *> *environment;
static WKWebView *webView;
static NSString *stage;
static NSString *marker;
static NSString *nonce;
static NSString *previousFrame;
static double began;
static double deadline;
static double dispatchCost;
static int editIndex;
static BOOL polling;
static uint64_t operationGeneration;

static double clockMS(void) {
    return NSProcessInfo.processInfo.systemUptime * 1000.0;
}

static void emit(NSDictionary *record) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    FILE *file = fopen(environment[@"BENCH_OUTPUT"].fileSystemRepresentation, "a");
    if (!file) return;
    fwrite(data.bytes, 1, data.length, file);
    fputc('\n', file);
    fclose(file);
}

static void fail(NSString *message) {
    emit(@{@"type": @"error", @"stage": stage ?: @"setup", @"message": message});
    exit(2);
}

static void armTimeout(void) {
    uint64_t generation = ++operationGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC),
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            if (operationGeneration != generation) return;
            emit(@{@"type": @"error", @"stage": stage ?: @"setup",
                   @"message": @"Timed out after 60 seconds awaiting a visibly painted H1"});
            _exit(2);
        });
}

static WKWebView *findWebView(NSView *view) {
    if ([view isKindOfClass:WKWebView.class]) return (WKWebView *)view;
    for (NSView *child in view.subviews) {
        WKWebView *found = findWebView(child);
        if (found) return found;
    }
    return nil;
}

static BOOL locateWebView(void) {
    if (webView) return YES;
    for (NSWindow *window in NSApp.windows) {
        webView = findWebView(window.contentView);
        if (!webView) continue;
        [window setContentSize:NSMakeSize(1120, 760)];
        [window setFrameOrigin:NSMakePoint(-10000, 0)];
        [window orderBack:nil];
        [window.contentView layoutSubtreeIfNeeded];
        return YES;
    }
    return NO;
}

static NSString *frameSignature(void) {
    if (!webView || NSIsEmptyRect(webView.bounds)) return @"";
    NSBitmapImageRep *bitmap = [webView bitmapImageRepForCachingDisplayInRect:webView.bounds];
    if (!bitmap) return @"";
    [webView cacheDisplayInRect:webView.bounds toBitmapImageRep:bitmap];
    unsigned char *bytes = bitmap.bitmapData;
    NSUInteger length = bitmap.bytesPerRow * bitmap.pixelsHigh;
    if (!bytes || !length) return @"";
    uint64_t hash = 1469598103934665603ULL;
    NSUInteger stride = MAX((NSUInteger)1, length / 16384);
    for (NSUInteger index = 0; index < length; index += stride) {
        hash ^= bytes[index];
        hash *= 1099511628211ULL;
    }
    return [NSString stringWithFormat:@"%016llx", hash];
}

static void poll(void);

static void pollLater(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ poll(); });
}

static void nextEdit(void);

static void recordReady(NSString *heading) {
    operationGeneration++;
    double elapsed = clockMS() - began;
    emit(@{
        @"type": @"sample",
        @"operation": stage,
        @"elapsedMs": @(elapsed),
        @"dispatchMs": @(dispatchCost),
        @"editIndex": @(editIndex),
        @"observedHeading": heading
    });

    NSInteger requestedEdits = [environment[@"BENCH_EDITS"] integerValue];
    if (editIndex >= requestedEdits) {
        struct task_basic_info info;
        mach_msg_type_number_t count = TASK_BASIC_INFO_COUNT;
        if (task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
            emit(@{@"type": @"memory", @"mainProcessRSSBytes": @(info.resident_size)});
        }
        emit(@{@"type": @"complete"});
        exit(0);
    }

    double delay = [stage isEqualToString:@"open"] ? 2.0 : 0.25;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        nextEdit();
    });
}

static void openTarget(void) {
    NSString *path = environment[@"BENCH_FIXTURE"];
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    NSWorkspaceOpenConfiguration *configuration = NSWorkspaceOpenConfiguration.configuration;
    configuration.activates = NO;
    configuration.createsNewApplicationInstance = NO;
    previousFrame = frameSignature();
    stage = @"open";
    marker = @"BENCH_START";
    began = clockMS();
    deadline = began + 60000.0;
    armTimeout();
    [NSWorkspace.sharedWorkspace openURLs:@[fileURL]
        withApplicationAtURL:NSBundle.mainBundle.bundleURL
        configuration:configuration
        completionHandler:^(NSRunningApplication *application, NSError *error) {
            dispatchCost = clockMS() - began;
            if (error) fail(error.localizedDescription);
        }];
    poll();
}

static void poll(void) {
    if (polling) return;
    if (clockMS() > deadline) fail(@"Timed out awaiting a visibly painted H1");
    if (!locateWebView()) {
        pollLater();
        return;
    }

    polling = YES;
    NSString *script = @"(()=>{const h=document.querySelector('.ProseMirror h1');if(!h)return {heading:'',visible:false};const r=h.getBoundingClientRect();return {heading:h.innerText||'',visible:r.width>0&&r.height>0&&r.bottom>0&&r.top<innerHeight};})()";
    [webView evaluateJavaScript:script completionHandler:^(id value, NSError *error) {
        polling = NO;
        if (error) {
            pollLater();
            return;
        }
        NSDictionary *state = [value isKindOfClass:NSDictionary.class] ? value : @{};
        NSString *heading = state[@"heading"] ?: @"";
        BOOL visible = [state[@"visible"] boolValue];
        if ([stage isEqualToString:@"warmup"] && visible && [heading containsString:@"BENCH_WARMUP"]) {
            stage = @"warmup-wait";
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ openTarget(); });
            return;
        }
        BOOL markerPresent = [heading containsString:marker ?: @""];
        if (([stage isEqualToString:@"open"] || [stage isEqualToString:@"edit"]) && visible && markerPresent) {
            NSString *currentFrame = frameSignature();
            if (currentFrame.length && ![currentFrame isEqualToString:previousFrame]) {
                previousFrame = currentFrame;
                recordReady(heading);
                return;
            }
        }
        pollLater();
    }];
}

static void nextEdit(void) {
    editIndex++;
    marker = [NSString stringWithFormat:@"E%@%02d", nonce, editIndex];
    previousFrame = frameSignature();
    stage = @"edit";
    began = clockMS();
    deadline = began + 60000.0;
    armTimeout();
    NSString *script = [NSString stringWithFormat:
        @"(()=>{const h=document.querySelector('.ProseMirror h1');if(!h||!h.firstChild)throw new Error('missing H1');h.focus();const r=document.createRange();r.setStart(h.firstChild,0);r.collapse(true);const s=getSelection();s.removeAllRanges();s.addRange(r);if(!document.execCommand('insertText',false,'%@ '))throw new Error('insertText failed');return h.innerText;})()",
        marker];
    [webView evaluateJavaScript:script completionHandler:^(id value, NSError *error) {
        dispatchCost = clockMS() - began;
        if (error) fail(error.localizedDescription);
        poll();
    }];
}

__attribute__((constructor)) static void installProbe(void) {
    @autoreleasepool {
        environment = NSProcessInfo.processInfo.environment;
        if (!environment[@"BENCH_OUTPUT"] || !environment[@"BENCH_FIXTURE"]) return;
        nonce = [[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] substringToIndex:8];
        [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
                [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
                emit(@{
                    @"type": @"metadata",
                    @"bundle": NSBundle.mainBundle.bundleIdentifier ?: @"unknown",
                    @"version": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
                    @"os": NSProcessInfo.processInfo.operatingSystemVersionString,
                    @"fixture": environment[@"BENCH_FIXTURE"],
                    @"window": @"1120x760 offscreen",
                    @"endpoint": @"visible H1 plus changed WebKit frame"
                });
                stage = @"warmup";
                marker = @"BENCH_WARMUP";
                began = clockMS();
                deadline = began + 60000.0;
                armTimeout();
                poll();
            }];
    }
}
