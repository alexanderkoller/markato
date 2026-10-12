// Shared in-process observer/driver for temporary copies of both release apps.
// Does not swizzle methods or substitute any editor/parser/rendering code.
#import <AppKit/AppKit.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <objc/message.h>

static double clockMS(void) { return NSProcessInfo.processInfo.systemUptime * 1000; }
static NSDictionary *env;
static NSDocument *document;
static NSMutableArray<NSDocument *> *closedDocuments;
static NSTextView *editor;
static NSView *web;
static NSString *marker;
static NSString *stage;
static double began, deadline, dispatchCost;
static int editIndex;
static BOOL polling;
static NSString *nonce;
static uint64_t pollIntervalNs;
static double pollIntervalMs;
static int pollCount;
static double lastPollAt, maxPollGap;
static NSString *previousFrame;

static void emit(NSDictionary *record) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    FILE *file = fopen([env[@"BENCH_OUTPUT"] fileSystemRepresentation], "a");
    if (file) { fwrite(data.bytes, 1, data.length, file); fputc('\n', file); fclose(file); }
}

static void fail(NSString *message) {
    emit(@{@"type":@"error", @"stage":stage ?: @"setup", @"message":message});
    exit(2);
}

static void findViews(NSView *view) {
    if (view.hidden) return;
    if ([view isKindOfClass:NSTextView.class] && [(NSTextView *)view isEditable])
        editor = (NSTextView *)view;
    NSString *name=NSStringFromClass(view.class);
    if ([name isEqualToString:@"WKWebView"] || [name isEqualToString:@"WebView"] ||
        [name hasSuffix:@"HTMLPreviewView"]) {
        web = view;
        return;
    }
    for (NSView *child in view.subviews) findViews(child);
}

static NSString *frameSignature(void) {
    if (!web || NSIsEmptyRect(web.bounds)) return @"";
    NSBitmapImageRep *bitmap = [web bitmapImageRepForCachingDisplayInRect:web.bounds];
    if (!bitmap) return @"";
    [web cacheDisplayInRect:web.bounds toBitmapImageRep:bitmap];
    unsigned char *bytes = bitmap.bitmapData;
    NSUInteger length = bitmap.bytesPerRow * bitmap.pixelsHigh;
    if (!bytes || !length) return @"";
    uint64_t hash = 1469598103934665603ULL;
    NSUInteger stride = MAX((NSUInteger)1, length / 16384);
    for (NSUInteger i = 0; i < length; i += stride) {
        hash ^= bytes[i];
        hash *= 1099511628211ULL;
    }
    return [NSString stringWithFormat:@"%016llx", hash];
}

static void readHeading(void (^completion)(NSString *, NSError *)) {
    web = nil;
    findViews(document.windowControllers.firstObject.window.contentView);
    if (!web) { completion(@"", nil); return; }
    completion(frameSignature(), nil);
}

static void poll(void);
static void nextEdit(void);
static void openFixture(NSString *path, BOOL warmup);
static void pollLater(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, pollIntervalNs), dispatch_get_main_queue(), ^{poll();});
}

static void ready(void) {
    double elapsed = clockMS() - began;
    if ([stage isEqualToString:@"warmup"]) {
        if (!closedDocuments) closedDocuments = [NSMutableArray array];
        [closedDocuments addObject:document];
        [document close];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            openFixture(env[@"BENCH_FIXTURE"], NO);
        });
        return;
    }
    emit(@{@"type":@"sample", @"operation":stage, @"elapsedMs":@(elapsed),
           @"dispatchMs":@(dispatchCost), @"editIndex":@(editIndex),
           @"polls":@(pollCount), @"detectionSlackMs":@(pollIntervalMs),
           @"maxPollGapMs":@(maxPollGap),
           @"observedHeading":marker, @"verifiedSource":@([editor.string containsString:marker])});
    if (![editor.string containsString:marker]) fail(@"Preview marker missing from source");
    if ([stage isEqualToString:@"open"]) {
        emit(@{@"type":@"views", @"editorClass":NSStringFromClass(editor.class),
               @"webClass":NSStringFromClass(web.class), @"font":editor.font.fontName ?: @"unknown",
               @"fontSize":@(editor.font.pointSize), @"windowWidth":@(document.windowControllers.firstObject.window.frame.size.width)});
        if ([document respondsToSelector:NSSelectorFromString(@"preferences")]) {
            id preferences = [document valueForKey:@"preferences"];
            NSMutableDictionary *settings = [NSMutableDictionary dictionaryWithObject:@"settings" forKey:@"type"];
            for (NSString *key in @[@"editorBaseFontInfo", @"editorLineSpacing", @"htmlMathJax", @"editorThemeName", @"htmlStyleName"]) {
                if ([preferences respondsToSelector:NSSelectorFromString(key)])
                    settings[key] = [preferences valueForKey:key] ?: NSNull.null;
            }
            emit(settings);
        }
    }
    int editCount = env[@"BENCH_EDITS"] ? [env[@"BENCH_EDITS"] intValue] : 7;
    if (editIndex >= editCount) {
        NSString *timingPath = env[@"BENCH_TIMING_OUTPUT"];
        void (*exportTimings)(const char *) = dlsym(RTLD_DEFAULT, "astra_timing_export");
        if (timingPath && exportTimings) exportTimings(timingPath.fileSystemRepresentation);
        struct task_basic_info info;
        mach_msg_type_number_t count = TASK_BASIC_INFO_COUNT;
        if (task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS)
            emit(@{@"type":@"memory", @"mainProcessRSSBytes":@(info.resident_size)});
        emit(@{@"type":@"complete"});
        // Exit directly: test documents stay private and edits are never saved.
        exit(0);
    }
    double delay = [stage isEqualToString:@"open"]
        ? (env[@"BENCH_FIRST_EDIT_DELAY_MS"] ? [env[@"BENCH_FIRST_EDIT_DELAY_MS"] doubleValue] / 1000.0 : 2.0)
        : (env[@"BENCH_EDIT_DELAY_MS"] ? [env[@"BENCH_EDIT_DELAY_MS"] doubleValue] / 1000.0 : 0.25);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{nextEdit();});
}

static void poll(void) {
    double now = clockMS();
    if (lastPollAt > 0) maxPollGap = MAX(maxPollGap, now - lastPollAt);
    lastPollAt = now;
    if (now > deadline) fail(@"Timed out awaiting visible heading marker");
    if (!web || !editor) {
        findViews(document.windowControllers.firstObject.window.contentView);
        if (!web || !editor) {
            pollLater();
            return;
        }
    }
    pollCount++;
    if (polling) return;
    polling = YES;
    readHeading(^(NSString *heading, NSError *error) {
        polling = NO;
        if (heading.length && ![heading isEqualToString:previousFrame]) {
            previousFrame = heading;
            ready();
        }
        else pollLater();
    });
}

static void nextEdit(void) {
    editIndex++;
    marker = [NSString stringWithFormat:@"E%@%02d", nonce, editIndex];
    stage = @"edit";
    [document.windowControllers.firstObject.window makeFirstResponder:editor];
    if (![editor.string hasPrefix:@"# "]) fail(@"Editor no longer shows document beginning");
    if ([editor.string containsString:marker]) fail(@"Edit marker already exists in source before insertion");
    previousFrame = frameSignature();
    [editor setSelectedRange:NSMakeRange(2, 0)];
    began = clockMS(); deadline = began + 60000; pollCount = 0; lastPollAt = 0; maxPollGap = 0;
    [editor insertText:[marker stringByAppendingString:@" "] replacementRange:NSMakeRange(2, 0)];
    dispatchCost = clockMS() - began;
    poll();
}

static void openFixture(NSString *path, BOOL warmup) {
    editor = nil; web = nil; polling = NO;
    stage = warmup ? @"warmup" : @"open";
    marker = warmup ? @"BENCH_WARMUP" : @"BENCH_START";
    began = clockMS(); deadline = began + 60000; pollCount = 0; lastPollAt = 0; maxPollGap = 0;
    if (!warmup && env[@"BENCH_TIMING_OUTPUT"]) {
        void (*startTimings)(void) = dlsym(RTLD_DEFAULT, "astra_timing_start");
        if (startTimings) startTimings();
    }
    [[NSDocumentController sharedDocumentController] openDocumentWithContentsOfURL:[NSURL fileURLWithPath:path]
        display:YES completionHandler:^(NSDocument *doc, BOOL alreadyOpen, NSError *error) {
        if (error || !doc) fail(error.localizedDescription ?: @"Missing document");
        document = doc;
        NSWindow *window = doc.windowControllers.firstObject.window;
        [window setContentSize:NSMakeSize(1120, 760)];
        [window setFrameOrigin:NSMakePoint(-10000, 0)];
        [window orderBack:nil];
        [window.contentView layoutSubtreeIfNeeded];
        findViews(window.contentView);
        previousFrame = frameSignature();
        dispatchCost = clockMS() - began;
        poll();
    }];
}

__attribute__((constructor)) static void installProbe(void) {
    @autoreleasepool {
        env = NSProcessInfo.processInfo.environment;
        if (!env[@"BENCH_OUTPUT"] || ![NSBundle.mainBundle.bundleIdentifier isEqualToString:env[@"BENCH_APP_ID"]]) return;
        double pollMicros = env[@"BENCH_POLL_INTERVAL_US"] ? [env[@"BENCH_POLL_INTERVAL_US"] doubleValue] : 1000;
        if (pollMicros < 100) pollMicros = 100;
        pollIntervalNs = (uint64_t)(pollMicros * NSEC_PER_USEC);
        pollIntervalMs = pollMicros / 1000;
        nonce = [[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] substringToIndex:8];
        // MacDown normally imports the installed legacy app's user preferences.
        // Skip that import in this private suite so the controlled run uses defaults.
        [NSUserDefaults.standardUserDefaults setVolatileDomain:@{
            @"MPDidMigrateFromLegacyBundleIdentifier":@YES,
            @"SUEnableAutomaticChecks":@NO,
            @"NSQuitAlwaysKeepsWindows":@NO,
            @"ApplePersistenceIgnoreState":@YES
        } forName:NSArgumentDomain];
        // These register-only defaults avoid persistent preferences and restored documents.
        [NSUserDefaults.standardUserDefaults registerDefaults:@{@"NSQuitAlwaysKeepsWindows":@NO}];
        [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            emit(@{@"type":@"metadata", @"bundle":NSBundle.mainBundle.bundleIdentifier,
                   @"version":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"development",
                   @"os":NSProcessInfo.processInfo.operatingSystemVersionString,
                   @"fixture":env[@"BENCH_FIXTURE"], @"pollIntervalMs":@(pollIntervalMs),
                   @"edits":env[@"BENCH_EDITS"] ?: @"7",
                   @"editDelayMs":env[@"BENCH_EDIT_DELAY_MS"] ?: @"250",
                   @"windowMode":@"offscreen"});
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (!closedDocuments) closedDocuments = [NSMutableArray array];
                [closedDocuments addObjectsFromArray:[NSDocumentController sharedDocumentController].documents.copy];
                for (NSDocument *doc in [NSDocumentController sharedDocumentController].documents.copy) [doc close];
                openFixture(env[@"BENCH_WARMUP"], YES);
            });
        }];
    }
}
