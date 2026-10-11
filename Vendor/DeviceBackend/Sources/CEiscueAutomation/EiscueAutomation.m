// SPDX-License-Identifier: GPL-3.0-only
// Independently implemented against runtime-checked SDK method signatures.
// No TouchSynthesis source is incorporated. No Swift callback crosses queues.
#import "EiscueAutomation.h"
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#include <string.h>

#if TARGET_OS_IOS && !TARGET_OS_SIMULATOR
static BOOL validTextBytes(const uint8_t *utf8, size_t length) {
    if (!utf8 || length == 0 || length > 8192) return NO;
    for (size_t i = 0; i < length;) {
        uint8_t first = utf8[i++];
        if (first == 0) return NO;
        if (first < 0x80) continue;
        size_t continuation;
        uint32_t scalar;
        if (first >= 0xc2 && first <= 0xdf) { continuation = 1; scalar = first & 0x1f; }
        else if (first >= 0xe0 && first <= 0xef) { continuation = 2; scalar = first & 0x0f; }
        else if (first >= 0xf0 && first <= 0xf4) { continuation = 3; scalar = first & 0x07; }
        else return NO;
        if (continuation > length - i) return NO;
        for (size_t j = 0; j < continuation; j++) {
            uint8_t next = utf8[i++];
            if ((next & 0xc0) != 0x80) return NO;
            scalar = (scalar << 6) | (next & 0x3f);
        }
        if ((continuation == 1 && scalar < 0x80) ||
            (continuation == 2 && scalar < 0x800) ||
            (continuation == 3 && scalar < 0x10000) ||
            (scalar >= 0xd800 && scalar <= 0xdfff) || scalar > 0x10ffff) return NO;
    }
    return YES;
}

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <math.h>

@interface EiscueOwnedAutomation : NSObject
@property uint64_t lease;
@property eiscue_automation_state status;
@property(strong) id session;
@property(strong) NSXPCConnection *pendingConnection;
@property(strong) NSString *previousVariant;
@property(strong) NSString *previousIdentifier;
@property BOOL ownsEnvironment;
@property BOOL cleanupFailed;
@property(strong) id screens;
@property(strong) NSMutableArray<id> *observers;
@property BOOL closed;
@property BOOL eventPending;
@property uint64_t queryGeneration;
@property NSUInteger queryRetries;
@property BOOL geometryDirty;
@end
@implementation EiscueOwnedAutomation
@end

static EiscueOwnedAutomation *current;
static uint64_t nextLease = 1;
static const char *ownerKey = "org.eiscue.owned.automation";
static Class runnerClass;
static IMP originalOrientationCallback;

static BOOL signature(id object, NSString *name, const char *encoding) {
    SEL selector = NSSelectorFromString(name);
    Method method = object_isClass(object) ? class_getClassMethod(object, selector)
                                           : class_getInstanceMethod([object class], selector);
    return method && strcmp(method_getTypeEncoding(method), encoding) == 0;
}
static BOOL live(EiscueOwnedAutomation *owner) {
    return owner && !owner.closed && owner.status.phase != EISCUE_AUTOMATION_FAILED && owner.status.phase != EISCUE_AUTOMATION_STOPPED;
}
static void fail(EiscueOwnedAutomation *owner, uint32_t error) {
    @synchronized(owner) {
        if (!live(owner)) return;
        eiscue_automation_state state = owner.status;
        state.phase = EISCUE_AUTOMATION_FAILED; state.error = error;
        owner.status = state;
    }
}
static void invalidateGeometry(EiscueOwnedAutomation *owner) {
    @synchronized(owner) {
        if (!live(owner)) return;
        eiscue_automation_state state = owner.status;
        state.revision++; owner.status = state; owner.geometryDirty = YES;
    }
}
static void orientationChanged(id receiver, SEL selector, NSInteger orientation) {
    EiscueOwnedAutomation *owner = objc_getAssociatedObject(receiver, ownerKey);
    if (owner) invalidateGeometry(owner);
    ((void (*)(id, SEL, NSInteger))originalOrientationCallback)(receiver, selector, orientation);
}
static BOOL loadFrameworks(void) {
    if (NSClassFromString(@"XCTRunnerDaemonSession") && NSClassFromString(@"XCPointerEventPath")) return YES;
    for (NSString *prefix in @[@"/System/Developer/Library", @"/Developer/Library"]) {
        // Load dependencies by their developer-image paths before their @rpath
        // consumers. A normal App has no test Runner framework search path.
        for (NSString *relative in @[@"PrivateFrameworks/DTXConnectionServices.framework/DTXConnectionServices",
                                    @"PrivateFrameworks/XCTestSupport.framework/XCTestSupport",
                                    @"PrivateFrameworks/XCTAutomationSupport.framework/XCTAutomationSupport",
                                    @"PrivateFrameworks/XCTestCore.framework/XCTestCore",
                                    @"Frameworks/XCUIAutomation.framework/XCUIAutomation",
                                    @"PrivateFrameworks/XCUIAutomation.framework/XCUIAutomation",
                                    @"Frameworks/XCTest.framework/XCTest"]) {
            NSString *path = [prefix stringByAppendingPathComponent:relative];
            if ([[NSFileManager defaultManager] fileExistsAtPath:path])
                (void)dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
        }
        if (NSClassFromString(@"XCTRunnerDaemonSession") && NSClassFromString(@"XCPointerEventPath")) return YES;
    }
    return NO;
}
static BOOL installOwnedSubclass(void) {
    if (runnerClass) return YES;
    Class base = NSClassFromString(@"XCTRunnerDaemonSession");
    Method orientation = class_getInstanceMethod(base, NSSelectorFromString(@"_XCT_interfaceOrientationDidChange:"));
    if (!orientation || strcmp(method_getTypeEncoding(orientation), "v24@0:8q16")) return NO;
    originalOrientationCallback = method_getImplementation(orientation);
    runnerClass = objc_allocateClassPair(base, "EiscueOwnedRunnerDaemonSession", 0);
    if (!runnerClass) return NO;
    if (!class_addMethod(runnerClass, NSSelectorFromString(@"_XCT_interfaceOrientationDidChange:"),
                         (IMP)orientationChanged, "v24@0:8q16")) {
        objc_disposeClassPair(runnerClass); runnerClass = Nil; return NO;
    }
    objc_registerClassPair(runnerClass);
    return YES;
}

// Every framework callback is marshalled and exception-contained separately.
// The enclosing invocation's @try cannot catch a later callback exception.
static void onMain(EiscueOwnedAutomation *owner, void (^body)(void)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { @synchronized(owner) { if (!live(owner)) return; } body(); }
        @catch (NSException *exception) { fail(owner, EISCUE_AUTOMATION_EXCEPTION); }
    });
}
static void invalidateConnection(id session) {
    @try {
        if (!session || !signature(session, @"connection", "@16@0:8")) return;
        id connection = ((id (*)(id, SEL))objc_msgSend)(session, NSSelectorFromString(@"connection"));
        if ([connection isKindOfClass:NSXPCConnection.class]) [connection invalidate];
    } @catch (NSException *exception) { }
}
static void queryGeometry(EiscueOwnedAutomation *owner);
static void finishGeometry(EiscueOwnedAutomation *owner, uint64_t query, uint64_t began,
                           NSInteger display, double scale, CGRect bounds, NSInteger orientation, NSError *error) {
    @synchronized(owner) {
        if (!live(owner) || owner.queryGeneration != query) return;
        if (owner.status.revision != began) {
            if (++owner.queryRetries > 2) { fail(owner, EISCUE_AUTOMATION_GEOMETRY); return; }
            queryGeometry(owner); return;
        }
        if (error || display < 0 || !isfinite(scale) || scale <= 0 || scale > 8 ||
            !isfinite(bounds.size.width) || !isfinite(bounds.size.height) || bounds.size.width <= 0 ||
            bounds.size.height <= 0 || bounds.size.width > 16384 || bounds.size.height > 16384 ||
            bounds.origin.x != 0 || bounds.origin.y != 0 || orientation < 1 || orientation > 4) {
            fail(owner, EISCUE_AUTOMATION_GEOMETRY); return;
        }
        // XCTScreenService forwards CADisplay.bounds in physical pixels. Keep
        // this bridge's bounds in points so image validation applies scale once
        // and XCPointerEventPath receives the matching point coordinates.
        bounds.size.width /= scale;
        bounds.size.height /= scale;
        eiscue_automation_state state = owner.status;
        if (state.scale && (state.display_id != (uint64_t)display || state.scale != scale ||
            state.bounds_width != bounds.size.width || state.bounds_height != bounds.size.height ||
            state.orientation != orientation)) state.revision++;
        state.display_id = (uint64_t)display; state.scale = scale;
        state.bounds_width = bounds.size.width; state.bounds_height = bounds.size.height;
        state.orientation = orientation; state.error = 0; state.phase = EISCUE_AUTOMATION_READY;
        owner.status = state; owner.geometryDirty = NO;
    }
}
static void queryGeometry(EiscueOwnedAutomation *owner) {
    if (!live(owner)) return;
    id source = owner.screens, session = owner.session;
    uint64_t began = owner.status.revision, query = ++owner.queryGeneration;
    if (!signature(source, @"requestScreenIdentifiersWithCompletion:", "v24@0:8@?16") ||
        !signature(source, @"requestTraitsForScreenWithIdentifier:completion:", "v32@0:8q16@?24") ||
        !signature(source, @"requestScaleForScreenWithIdentifier:completion:", "v32@0:8q16@?24") ||
        !signature(source, @"requestBoundsForScreenWithIdentifier:completion:", "v32@0:8q16@?24") ||
        !signature(session, @"getInterfaceOrientationWithReply:", "v24@0:8@?16")) {
        fail(owner, EISCUE_AUTOMATION_SIGNATURE); return;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(source, NSSelectorFromString(@"requestScreenIdentifiersWithCompletion:"), ^(NSArray *identifiers, NSError *error) {
        onMain(owner, ^{
            if (query != owner.queryGeneration) return;
            if (error || ![identifiers isKindOfClass:NSArray.class] || identifiers.count == 0 || identifiers.count > 8) {
                fail(owner, EISCUE_AUTOMATION_GEOMETRY); return;
            }
            __block NSUInteger remaining = identifiers.count;
            NSMutableArray<NSNumber *> *mainDisplays = [NSMutableArray new];
            NSMutableSet<NSNumber *> *received = [NSMutableSet new];
            for (id raw in identifiers) {
                if (![raw isKindOfClass:NSNumber.class] || [raw integerValue] < 0 || [received containsObject:raw]) {
                    fail(owner, EISCUE_AUTOMATION_GEOMETRY); return;
                }
                [received addObject:raw];
            }
            [received removeAllObjects];
            for (NSNumber *raw in identifiers) {
                NSInteger display = raw.integerValue;
                ((void (*)(id, SEL, NSInteger, id))objc_msgSend)(source, NSSelectorFromString(@"requestTraitsForScreenWithIdentifier:completion:"), display, ^(NSUInteger traits, NSError *traitError) {
                    onMain(owner, ^{
                        if (query != owner.queryGeneration) return;
                        if (traitError || [received containsObject:@(display)]) { fail(owner, EISCUE_AUTOMATION_GEOMETRY); return; }
                        [received addObject:@(display)];
                        if (traits & 1) [mainDisplays addObject:@(display)];
                        if (--remaining != 0) return;
                        if (mainDisplays.count != 1) { fail(owner, EISCUE_AUTOMATION_GEOMETRY); return; }
                        NSInteger selected = mainDisplays[0].integerValue;
                        ((void (*)(id, SEL, NSInteger, id))objc_msgSend)(source, NSSelectorFromString(@"requestScaleForScreenWithIdentifier:completion:"), selected, ^(double scale, NSError *scaleError) {
                            onMain(owner, ^{
                                if (query != owner.queryGeneration) return;
                                if (scaleError) { fail(owner, EISCUE_AUTOMATION_GEOMETRY); return; }
                                ((void (*)(id, SEL, NSInteger, id))objc_msgSend)(source, NSSelectorFromString(@"requestBoundsForScreenWithIdentifier:completion:"), selected, ^(CGRect bounds, NSError *boundsError) {
                                    onMain(owner, ^{
                                        if (query != owner.queryGeneration) return;
                                        if (boundsError) { fail(owner, EISCUE_AUTOMATION_GEOMETRY); return; }
                                        ((void (*)(id, SEL, id))objc_msgSend)(session, NSSelectorFromString(@"getInterfaceOrientationWithReply:"), ^(NSInteger orientation, NSError *orientationError) {
                                            onMain(owner, ^{ finishGeometry(owner, query, began, selected, scale, bounds, orientation, orientationError); });
                                        });
                                    });
                                });
                            });
                        });
                    });
                });
            }
        });
    });
}

static int32_t beginFailure(EiscueOwnedAutomation *owner, int32_t code) {
    eiscue_automation_abort(owner.lease); return code;
}
static BOOL configureEnvironment(EiscueOwnedAutomation *owner, NSUUID *identifier) {
    const char *variant = getenv("XCTestManagerVariant"), *session = getenv("XCTestSessionIdentifier");
    owner.previousVariant = variant ? [NSString stringWithUTF8String:variant] : nil;
    owner.previousIdentifier = session ? [NSString stringWithUTF8String:session] : nil;
    if ((variant && !owner.previousVariant) || (session && !owner.previousIdentifier)) return NO;
    owner.ownsEnvironment = YES;
    // SDK testmanagerdServiceName selects the developer-image runner service only
    // with this variant. Identity matches the authenticated DTX and local config.
    return setenv("XCTestManagerVariant", "DDI", 1) == 0 &&
           setenv("XCTestSessionIdentifier", identifier.UUIDString.UTF8String, 1) == 0;
}
int32_t eiscue_automation_begin(const uint8_t uuid[16], uint64_t *lease) {
    if (!NSThread.isMainThread) return EISCUE_AUTOMATION_WRONG_THREAD;
    if (!uuid || !lease) return EISCUE_AUTOMATION_CONFIGURATION;
    *lease = 0;
    if (current && current.status.phase != EISCUE_AUTOMATION_STOPPED) return EISCUE_AUTOMATION_BUSY;
    if (NSProcessInfo.processInfo.environment[@"XCTestConfigurationFilePath"] ||
        NSProcessInfo.processInfo.environment[@"XCTestBundlePath"]) return EISCUE_AUTOMATION_EXISTING_TEST;
    @try {
        EiscueOwnedAutomation *owner = [EiscueOwnedAutomation new];
        owner.lease = nextLease++; owner.status = (eiscue_automation_state){.phase = EISCUE_AUTOMATION_PREPARING, .revision = 1};
        owner.observers = [NSMutableArray new]; current = owner; *lease = owner.lease;
        NSUUID *identifier = [[NSUUID alloc] initWithUUIDBytes:uuid];
        if (!configureEnvironment(owner, identifier)) return beginFailure(owner, EISCUE_AUTOMATION_CONFIGURATION);
        if (!loadFrameworks()) return beginFailure(owner, EISCUE_AUTOMATION_FRAMEWORK);
        Class configClass = NSClassFromString(@"XCTestConfiguration");
        if (!installOwnedSubclass() || !signature(configClass, @"setActiveTestConfiguration:", "v24@0:8@16") ||
            !signature(runnerClass, @"sessionWithConnection:completion:", "v32@0:8@16@?24") ||
            !signature(runnerClass, @"connectionForInitiatingSharedSession", "@16@0:8") ||
            !signature(runnerClass, @"testmanagerdServiceName", "@16@0:8")) return beginFailure(owner, EISCUE_AUTOMATION_SIGNATURE);
        NSString *service = ((id (*)(id, SEL))objc_msgSend)(runnerClass, NSSelectorFromString(@"testmanagerdServiceName"));
        if (![service isEqualToString:@"com.apple.dt.testmanagerd.runner"]) return beginFailure(owner, EISCUE_AUTOMATION_CONFIGURATION);
        id config = [[configClass alloc] init];
        for (NSString *selector in @[@"setSessionIdentifier:", @"setAutomationFrameworkPath:"])
            if (!signature(config, selector, "v24@0:8@16")) return beginFailure(owner, EISCUE_AUTOMATION_SIGNATURE);
        for (NSString *selector in @[@"setTestsDrivenByIDE:", @"setReportResultsToIDE:", @"setInitializeForUITesting:"])
            if (!signature(config, selector, "v20@0:8B16")) return beginFailure(owner, EISCUE_AUTOMATION_SIGNATURE);
        NSString *support = @"/System/Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework";
        if (![[NSFileManager defaultManager] fileExistsAtPath:support]) support = @"/Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework";
        if (![[NSFileManager defaultManager] fileExistsAtPath:support]) return beginFailure(owner, EISCUE_AUTOMATION_FRAMEWORK);
        ((void (*)(id, SEL, id))objc_msgSend)(config, NSSelectorFromString(@"setSessionIdentifier:"), identifier);
        ((void (*)(id, SEL, id))objc_msgSend)(config, NSSelectorFromString(@"setAutomationFrameworkPath:"), support);
        ((void (*)(id, SEL, BOOL))objc_msgSend)(config, NSSelectorFromString(@"setTestsDrivenByIDE:"), NO);
        ((void (*)(id, SEL, BOOL))objc_msgSend)(config, NSSelectorFromString(@"setReportResultsToIDE:"), NO);
        ((void (*)(id, SEL, BOOL))objc_msgSend)(config, NSSelectorFromString(@"setInitializeForUITesting:"), YES);
        ((void (*)(id, SEL, id))objc_msgSend)(configClass, NSSelectorFromString(@"setActiveTestConfiguration:"), config);
        for (NSNotificationName name in @[UIScreenModeDidChangeNotification, UIScreenDidConnectNotification, UIScreenDidDisconnectNotification]) {
            [owner.observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) { invalidateGeometry(owner); }]];
        }
        // Despite its SDK name, this factory allocates a fresh NSXPCConnection;
        // it does not initiate or retrieve the process-wide shared session.
        id pending = ((id (*)(id, SEL))objc_msgSend)(runnerClass, NSSelectorFromString(@"connectionForInitiatingSharedSession"));
        if (![pending isKindOfClass:NSXPCConnection.class]) return beginFailure(owner, EISCUE_AUTOMATION_RUNNER);
        owner.pendingConnection = pending;
        #if DEBUG
        fprintf(stderr, "NCM owned runner DDIServiceVerified=true pendingConnectionOwned=true\n"); fflush(stderr);
        #endif
        ((void (*)(id, SEL, id, id))objc_msgSend)(runnerClass, NSSelectorFromString(@"sessionWithConnection:completion:"), owner.pendingConnection, ^(id session, NSError *error) {
            #if DEBUG
            fprintf(stderr, "NCM owned runner completion=true errorPresent=%d\n", error != nil); fflush(stderr);
            #endif
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    if (!live(owner)) {
                        invalidateConnection(session);
                        return;
                    }
                    if (error || ![session isKindOfClass:runnerClass]) { invalidateConnection(session); fail(owner, EISCUE_AUTOMATION_RUNNER); return; }
                    owner.session = session;
                    objc_setAssociatedObject(session, ownerKey, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    if (!signature(session, @"supportsAutomationMode", "B16@0:8")) { fail(owner, EISCUE_AUTOMATION_SIGNATURE); return; }
                    BOOL supported = ((BOOL (*)(id, SEL))objc_msgSend)(session, NSSelectorFromString(@"supportsAutomationMode"));
                    if (!supported) { fail(owner, EISCUE_AUTOMATION_CONSENT); return; }
                    Protocol *role = objc_getProtocol("XCTMessagingRole_CapabilityExchange");
                    if (!role) { fail(owner, EISCUE_AUTOMATION_SIGNATURE); return; }
                    SEL enable = NSSelectorFromString(@"_XCT_enableAutomationModeWithReply:");
                    struct objc_method_description descriptor = protocol_getMethodDescription(role, enable, YES, YES);
                    if (!descriptor.types || strcmp(descriptor.types, "v24@0:8@?16")) { fail(owner, EISCUE_AUTOMATION_SIGNATURE); return; }
                    @synchronized(owner) { eiscue_automation_state state = owner.status; state.phase = EISCUE_AUTOMATION_AUTHORIZING; owner.status = state; }
                    // Same request as SDK enableAutomationModeWithError:, without
                    // its synchronous XCTFuture and with an explicit XPC error path.
                    // Only this authenticated, owned connection is used.
                    id proxy = [owner.pendingConnection remoteObjectProxyWithErrorHandler:^(NSError *transportError) {
                        @try {
                        #if DEBUG
                        fprintf(stderr, "NCM owned automation transportError=true code=%ld\n", (long)transportError.code); fflush(stderr);
                        #endif
                        onMain(owner, ^{ fail(owner, EISCUE_AUTOMATION_RUNNER); });
                        } @catch (NSException *exception) { fail(owner, EISCUE_AUTOMATION_EXCEPTION); }
                    }];
                    if (!proxy) { fail(owner, EISCUE_AUTOMATION_RUNNER); return; }
                    #if DEBUG
                    fprintf(stderr, "NCM owned automation permissionRequested=true supported=1 asyncReply=true\n"); fflush(stderr);
                    #endif
                    ((void (*)(id, SEL, id))objc_msgSend)(proxy, enable, ^(NSError *enableError) {
                        @try {
                        #if DEBUG
                        fprintf(stderr, "NCM owned automation permissionReply=true enabled=%d errorCode=%ld\n", enableError == nil, (long)enableError.code); fflush(stderr);
                        #endif
                        onMain(owner, ^{
                            if (enableError) { fail(owner, EISCUE_AUTOMATION_CONSENT); return; }
                            @synchronized(owner) { eiscue_automation_state state = owner.status; state.phase = EISCUE_AUTOMATION_QUERYING; owner.status = state; }
                            Class sourceClass = NSClassFromString(@"XCUILocalDeviceScreenDataSource");
                            id source = [sourceClass alloc];
                            if (!signature(source, @"initWithScreenshotIPCInterface:screenRecordingIPCInterface:", "@32@0:8@16@24")) { fail(owner, EISCUE_AUTOMATION_SIGNATURE); return; }
                            owner.screens = ((id (*)(id, SEL, id, id))objc_msgSend)(source, NSSelectorFromString(@"initWithScreenshotIPCInterface:screenRecordingIPCInterface:"), session, session);
                            queryGeometry(owner);
                        });
                        } @catch (NSException *exception) { fail(owner, EISCUE_AUTOMATION_EXCEPTION); }
                    });
                } @catch (NSException *exception) { fail(owner, EISCUE_AUTOMATION_EXCEPTION); }
            });
        });
        return 0;
    } @catch (NSException *exception) { if (*lease) eiscue_automation_abort(*lease); return EISCUE_AUTOMATION_EXCEPTION; }
}
int32_t eiscue_automation_poll(uint64_t lease, eiscue_automation_state *state) {
    if (!NSThread.isMainThread) return EISCUE_AUTOMATION_WRONG_THREAD;
    if (!state || !current || current.lease != lease) return EISCUE_AUTOMATION_CLOSED;
    @synchronized(current) { *state = current.status; }
    return 0;
}
int32_t eiscue_automation_refresh_geometry(uint64_t lease) {
    if (!NSThread.isMainThread) return EISCUE_AUTOMATION_WRONG_THREAD;
    EiscueOwnedAutomation *owner = current;
    if (!owner || owner.lease != lease) return EISCUE_AUTOMATION_CLOSED;
    if (owner.status.phase != EISCUE_AUTOMATION_READY) return EISCUE_AUTOMATION_BUSY;
    @synchronized(owner) { eiscue_automation_state state = owner.status; state.phase = EISCUE_AUTOMATION_QUERYING; owner.status = state; owner.queryRetries = 0; }
    @try { queryGeometry(owner); return 0; }
    @catch (NSException *exception) { fail(owner, EISCUE_AUTOMATION_EXCEPTION); return EISCUE_AUTOMATION_EXCEPTION; }
}
static int32_t eventSnapshot(EiscueOwnedAutomation *owner, uint64_t request,
                             uint64_t revision, eiscue_automation_state *state) {
    @synchronized(owner) {
        if (owner.closed) return EISCUE_AUTOMATION_CLOSED;
        *state = owner.status;
        if (owner.eventPending || state->phase != EISCUE_AUTOMATION_READY || request <= state->request_id)
            return EISCUE_AUTOMATION_BUSY;
        if (owner.geometryDirty || state->revision != revision) return EISCUE_AUTOMATION_GEOMETRY;
        return 0;
    }
}
static void eventReceipt(EiscueOwnedAutomation *owner, uint64_t request, BOOL delivered, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            @synchronized(owner) {
                if (owner.closed || owner.status.request_id != request) return;
                owner.eventPending = NO;
                if (!live(owner)) return;
                if (!delivered || error) { fail(owner, EISCUE_AUTOMATION_DELIVERY_UNKNOWN); return; }
                eiscue_automation_state completed = owner.status;
                completed.phase = EISCUE_AUTOMATION_READY; owner.status = completed;
            }
        } @catch (NSException *exception) {
            @synchronized(owner) {
                if (owner.closed || owner.status.request_id != request) return;
                owner.eventPending = NO;
                fail(owner, EISCUE_AUTOMATION_DELIVERY_UNKNOWN);
            }
        }
    });
}
static int32_t submitOwnedEvent(EiscueOwnedAutomation *owner, uint64_t request,
                               uint64_t revision, id event, BOOL deviceEvent,
                               void (^preflight)(void)) {
    BOOL invoked = NO;
    @try {
        if (!event) return EISCUE_AUTOMATION_CONFIGURATION;
        NSString *selector = deviceEvent ? @"performDeviceEvent:completion:" : @"synthesizeEvent:completion:";
        if (!signature(owner.session, selector, deviceEvent ? "v32@0:8@16@?24" : "@32@0:8@16@?24"))
            return EISCUE_AUTOMATION_SIGNATURE;
        @synchronized(owner) {
            // Recheck while holding the same lock as orientation invalidation,
            // including the request receipt, until the single submission ends.
            eiscue_automation_state state;
            int32_t rejection = eventSnapshot(owner, request, revision, &state);
            if (rejection) return rejection;
            state.phase = EISCUE_AUTOMATION_DELIVERING; state.request_id = request;
            owner.status = state; owner.eventPending = YES;
            void (^completion)(BOOL, NSError *) = ^(BOOL delivered, NSError *error) {
                @try { eventReceipt(owner, request, delivered, error); }
                @catch (NSException *exception) { fail(owner, EISCUE_AUTOMATION_DELIVERY_UNKNOWN); }
            };
            if (preflight) preflight();
            invoked = YES;
            if (deviceEvent)
                ((void (*)(id, SEL, id, id))objc_msgSend)(owner.session, NSSelectorFromString(selector), event, completion);
            else
                ((id (*)(id, SEL, id, id))objc_msgSend)(owner.session, NSSelectorFromString(selector), event, completion);
        }
        return 0;
    } @catch (NSException *exception) {
        uint32_t error = invoked ? EISCUE_AUTOMATION_DELIVERY_UNKNOWN : EISCUE_AUTOMATION_EXCEPTION;
        fail(owner, error); return error;
    }
}
int32_t eiscue_automation_touch(uint64_t lease, uint64_t request, uint64_t revision,
    uint32_t width, uint32_t height, uint16_t x, uint16_t y, uint16_t endX, uint16_t endY, uint16_t duration) {
    if (!NSThread.isMainThread) return EISCUE_AUTOMATION_WRONG_THREAD;
    EiscueOwnedAutomation *owner = current;
    if (!owner || owner.lease != lease) return EISCUE_AUTOMATION_CLOSED;
    eiscue_automation_state state;
    int32_t rejection = eventSnapshot(owner, request, revision, &state);
    if (rejection) return rejection;
    if (!width || !height || width > 16384 || height > 16384 ||
        (duration != 0 && (duration < 100 || duration > 2000))) return EISCUE_AUTOMATION_GEOMETRY;
    @try {
        Class pathClass = NSClassFromString(@"XCPointerEventPath"), recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
        id path = [pathClass alloc], record = [recordClass alloc];
        if (!signature(path, @"initForTouchAtPoint:offset:", "@40@0:8{CGPoint=dd}16d32") ||
            !signature(path, @"liftUpAtOffset:", "v24@0:8d16") ||
            !signature(path, @"moveToPoint:atOffset:", "v40@0:8{CGPoint=dd}16d32") ||
            !signature(record, @"initWithName:displayID:interfaceOrientation:", "@40@0:8@16Q24q32") ||
            !signature(record, @"addPointerEventPath:", "v24@0:8@16") ||
            !signature(owner.session, @"useLegacyEventCoordinateTransformationPath", "B16@0:8") ||
            !signature(owner.session, @"synthesizeEvent:completion:", "@32@0:8@16@?24")) return EISCUE_AUTOMATION_SIGNATURE;
        double bw = state.bounds_width * state.scale, bh = state.bounds_height * state.scale;
        BOOL direct = fabs(width - bw) <= 1 && fabs(height - bh) <= 1;
        BOOL swapped = fabs(width - bh) <= 1 && fabs(height - bw) <= 1;
        if ((!direct && !swapped) || !isfinite(state.scale) || state.scale <= 0) return EISCUE_AUTOMATION_GEOMETRY;
        CGPoint start = CGPointMake((double)x / 65535 * (width - 1) / state.scale, (double)y / 65535 * (height - 1) / state.scale);
        CGPoint end = CGPointMake((double)endX / 65535 * (width - 1) / state.scale, (double)endY / 65535 * (height - 1) / state.scale);
        BOOL legacy = ((BOOL (*)(id, SEL))objc_msgSend)(owner.session, NSSelectorFromString(@"useLegacyEventCoordinateTransformationPath"));
        NSInteger eventOrientation = state.orientation;
        if (!legacy) {
            // Modern XCTest consumes fixed portrait screen points and removes
            // the event's orientation. Match XCUICoordinate.screenPoint's
            // transform before building both ends of the gesture.
            double nativeWidth = fmin(state.bounds_width, state.bounds_height);
            double nativeHeight = fmax(state.bounds_width, state.bounds_height);
            for (int index = 0; index < 2; index++) {
                CGPoint p = index ? end : start;
                switch (state.orientation) {
                    case 2: p = CGPointMake(nativeWidth - p.x, nativeHeight - p.y); break;
                    case 3: p = CGPointMake(nativeWidth - p.y, p.x); break;
                    case 4: p = CGPointMake(p.y, nativeHeight - p.x); break;
                }
                if (index) end = p; else start = p;
            }
            eventOrientation = 1;
        }
        path = ((id (*)(id, SEL, CGPoint, double))objc_msgSend)(path, NSSelectorFromString(@"initForTouchAtPoint:offset:"), start, 0);
        if (duration) ((void (*)(id, SEL, CGPoint, double))objc_msgSend)(path, NSSelectorFromString(@"moveToPoint:atOffset:"), end, duration / 1000.0);
        ((void (*)(id, SEL, double))objc_msgSend)(path, NSSelectorFromString(@"liftUpAtOffset:"), duration ? duration / 1000.0 + 0.02 : 0.1);
        record = ((id (*)(id, SEL, id, uint64_t, NSInteger))objc_msgSend)(record,
            NSSelectorFromString(@"initWithName:displayID:interfaceOrientation:"), @"Eiscue", state.display_id, eventOrientation);
        if (!path || !record) return EISCUE_AUTOMATION_CONFIGURATION;
        ((void (*)(id, SEL, id))objc_msgSend)(record, NSSelectorFromString(@"addPointerEventPath:"), path);
        return submitOwnedEvent(owner, request, revision, record, NO, nil);
    } @catch (NSException *exception) { fail(owner, EISCUE_AUTOMATION_EXCEPTION); return EISCUE_AUTOMATION_EXCEPTION; }
}
int32_t eiscue_automation_home(uint64_t lease, uint64_t request, uint64_t revision) {
    if (!NSThread.isMainThread) return EISCUE_AUTOMATION_WRONG_THREAD;
    EiscueOwnedAutomation *owner = current;
    if (!owner || owner.lease != lease) return EISCUE_AUTOMATION_CLOSED;
    eiscue_automation_state state;
    int32_t rejection = eventSnapshot(owner, request, revision, &state);
    if (rejection) return rejection;
    @try {
        Class eventClass = NSClassFromString(@"XCDeviceEvent");
        if (!signature(eventClass, @"deviceEventWithPage:usage:duration:", "@32@0:8I16I20d24"))
            return EISCUE_AUTOMATION_SIGNATURE;
        // SDK XCUIDevice Home mapping: consumer page 12, usage 64, 5 ms.
        id event = ((id (*)(id, SEL, uint32_t, uint32_t, double))objc_msgSend)(eventClass,
            NSSelectorFromString(@"deviceEventWithPage:usage:duration:"), 12, 64, 0.005);
        return submitOwnedEvent(owner, request, revision, event, YES, nil);
    } @catch (NSException *exception) { fail(owner, EISCUE_AUTOMATION_EXCEPTION); return EISCUE_AUTOMATION_EXCEPTION; }
}
int32_t eiscue_automation_type_text(uint64_t lease, uint64_t request, uint64_t revision,
                                  const uint8_t *utf8, size_t length) {
    if (!NSThread.isMainThread) return EISCUE_AUTOMATION_WRONG_THREAD;
    EiscueOwnedAutomation *owner = current;
    if (!owner || owner.lease != lease) return EISCUE_AUTOMATION_CLOSED;
    if (!validTextBytes(utf8, length)) return EISCUE_AUTOMATION_CONFIGURATION;
    eiscue_automation_state state;
    int32_t rejection = eventSnapshot(owner, request, revision, &state);
    if (rejection) return rejection;
    @try {
        NSString *text = [[NSString alloc] initWithBytes:utf8 length:length encoding:NSUTF8StringEncoding];
        Class pathClass = NSClassFromString(@"XCPointerEventPath"), recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
        id path = [pathClass alloc], record = [recordClass alloc];
        if (!text) return EISCUE_AUTOMATION_CONFIGURATION;
        if (!signature(path, @"initForTextInput", "@16@0:8") ||
            !signature(path, @"typeKey:modifiers:atOffset:", "v40@0:8@16Q24d32") ||
            !signature(record, @"initWithName:displayID:interfaceOrientation:", "@40@0:8@16Q24q32") ||
            !signature(record, @"addPointerEventPath:", "v24@0:8@16")) return EISCUE_AUTOMATION_SIGNATURE;
        path = ((id (*)(id, SEL))objc_msgSend)(path, NSSelectorFromString(@"initForTextInput"));
        if (!path) return EISCUE_AUTOMATION_CONFIGURATION;
        // A single Command-V event avoids an unbounded per-character event.
        // XCUIElement.h defines XCUIKeyModifierCommand as bit 4.
        ((void (*)(id, SEL, id, NSUInteger, double))objc_msgSend)(path,
            NSSelectorFromString(@"typeKey:modifiers:atOffset:"), @"v", 1UL << 4, 0);
        record = ((id (*)(id, SEL, id, uint64_t, NSInteger))objc_msgSend)(record,
            NSSelectorFromString(@"initWithName:displayID:interfaceOrientation:"), @"Eiscue", state.display_id, state.orientation);
        if (!record) return EISCUE_AUTOMATION_CONFIGURATION;
        ((void (*)(id, SEL, id))objc_msgSend)(record, NSSelectorFromString(@"addPointerEventPath:"), path);
        return submitOwnedEvent(owner, request, revision, record, NO, ^{
            // This explicit input request owns the write. Never read the old
            // clipboard. The final lease/revision guard remains locked through
            // this write and the single owned-session event submission.
            UIPasteboard.generalPasteboard.string = text;
        });
    } @catch (NSException *exception) { fail(owner, EISCUE_AUTOMATION_EXCEPTION); return EISCUE_AUTOMATION_EXCEPTION; }
}
void eiscue_automation_abort(uint64_t lease) {
    if (!NSThread.isMainThread || !current || current.lease != lease) return;
    EiscueOwnedAutomation *owner = current;
    @synchronized(owner) { owner.closed = YES; owner.queryGeneration++; eiscue_automation_state state = owner.status; state.phase = EISCUE_AUTOMATION_STOPPED; state.revision++; owner.status = state; }
    for (id observer in owner.observers) {
        @try { [NSNotificationCenter.defaultCenter removeObserver:observer]; }
        @catch (NSException *exception) { owner.cleanupFailed = YES; }
    }
    [owner.observers removeAllObjects];
    @try { [owner.pendingConnection invalidate]; }
    @catch (NSException *exception) { owner.cleanupFailed = YES; }
    owner.pendingConnection = nil;
    invalidateConnection(owner.session);
    if (owner.ownsEnvironment) {
        int variantResult = owner.previousVariant ? setenv("XCTestManagerVariant", owner.previousVariant.UTF8String, 1) : unsetenv("XCTestManagerVariant");
        int identifierResult = owner.previousIdentifier ? setenv("XCTestSessionIdentifier", owner.previousIdentifier.UTF8String, 1) : unsetenv("XCTestSessionIdentifier");
        if (variantResult || identifierResult) owner.cleanupFailed = YES;
        owner.ownsEnvironment = NO;
    }
    if (owner.session) objc_setAssociatedObject(owner.session, ownerKey, nil, OBJC_ASSOCIATION_ASSIGN);
    owner.session = nil; owner.screens = nil;
}
int32_t eiscue_automation_stop(uint64_t lease) {
    if (!NSThread.isMainThread) return EISCUE_AUTOMATION_WRONG_THREAD;
    if (!current || current.lease != lease) return 0;
    if (current.eventPending) return EISCUE_AUTOMATION_BUSY;
    eiscue_automation_abort(lease); return current.cleanupFailed ? EISCUE_AUTOMATION_EXCEPTION : 0;
}
#else
int32_t eiscue_automation_begin(const uint8_t uuid[16], uint64_t *lease) { return EISCUE_AUTOMATION_UNSUPPORTED; }
int32_t eiscue_automation_poll(uint64_t lease, eiscue_automation_state *state) { return EISCUE_AUTOMATION_UNSUPPORTED; }
int32_t eiscue_automation_refresh_geometry(uint64_t lease) { return EISCUE_AUTOMATION_UNSUPPORTED; }
int32_t eiscue_automation_touch(uint64_t lease, uint64_t request, uint64_t revision, uint32_t width, uint32_t height,
    uint16_t x, uint16_t y, uint16_t endX, uint16_t endY, uint16_t duration) { return EISCUE_AUTOMATION_UNSUPPORTED; }
int32_t eiscue_automation_home(uint64_t lease, uint64_t request, uint64_t revision) { return EISCUE_AUTOMATION_UNSUPPORTED; }
int32_t eiscue_automation_type_text(uint64_t lease, uint64_t request, uint64_t revision,
    const uint8_t *utf8, size_t length) { return EISCUE_AUTOMATION_UNSUPPORTED; }
int32_t eiscue_automation_stop(uint64_t lease) { return 0; }
void eiscue_automation_abort(uint64_t lease) {}
#endif
