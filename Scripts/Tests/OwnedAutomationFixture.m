// SPDX-License-Identifier: GPL-3.0-only
// Host-only runtime fixtures exercise the production C entry points without
// loading developer frameworks or contacting any device. The script changes
// only the platform guard and UIKit notification imports in its source copy.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
static void *fixtureDlopen(const char *path, int mode);
static Class fixtureClassFromString(NSString *name);
// Any regression to clipboard input fails against this process-local fake;
// no NSPasteboard or real system clipboard is accessed by this fixture.
@interface UIPasteboard : NSObject
@property(copy) NSString *string;
+ (UIPasteboard *)generalPasteboard;
@end
#define dlopen fixtureDlopen
#define NSClassFromString fixtureClassFromString
#import "OwnedAutomationUnderTest.m"
#undef NSClassFromString
#undef dlopen
#include <stdlib.h>
#include <unistd.h>
#include <stdio.h>

static NSUInteger checks;
#define CHECK(condition) do { checks++; if (!(condition)) { \
    fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); abort(); \
} } while (0)

static Class fakeSessionClass;
static Class wrongSignatureSessionClass;
static Class textPathClassOverride;
static NSXPCConnection *sessionConnection;
static uint32_t capturedPage, capturedUsage;
static double capturedDuration, capturedOffset;
static NSUInteger capturedTypingSpeed, textEvents, clipboardAccesses;
static BOOL capturedRedaction, dirtyDuringConstruction, throwOnSend, throwOnTextConstruction;
static BOOL legacyCoordinates;
static CGPoint capturedTouchPoint;
static NSInteger capturedOrientation;
static uint64_t capturedDisplay;
static NSString *capturedText, *capturedName;
static id capturedPath, capturedEvent;
static void (^lastCompletion)(BOOL, NSError *);
static NSUInteger submissions, constructions;
static NSString *capturedImageType;
static double capturedImageQuality;
static NSInteger capturedScreenID;
static CGRect capturedCaptureRect;
static id capturedEncoding, capturedScreenshotRequest;
static void (^lastScreenshotReply)(id, NSError *);
static NSUInteger screenshotSubmissions;
static BOOL throwOnScreenshotSend;

@interface EiscueFixtureImage : NSObject
@property(strong) id bytes;
@property BOOL throwsOnData;
- (id)data;
@end
@implementation EiscueFixtureImage
- (id)data {
    if (self.throwsOnData) @throw [NSException exceptionWithName:@"FixtureImage" reason:nil userInfo:nil];
    return self.bytes;
}
@end

@implementation UIPasteboard
+ (UIPasteboard *)generalPasteboard {
    clipboardAccesses++; CHECK(NO); return nil;
}
- (NSString *)string { CHECK(NO); return nil; }
- (void)setString:(NSString *)value { CHECK(NO); }
@end

@interface EiscueFixturePendingConnection : NSXPCConnection
@property NSUInteger invalidations;
@property BOOL throwsOnInvalidate;
@end
@implementation EiscueFixturePendingConnection
- (void)invalidate {
    self.invalidations++;
    if (self.throwsOnInvalidate) @throw [NSException exceptionWithName:@"FixtureInvalidate" reason:nil userInfo:nil];
}
- (void)activate { CHECK(NO); }
- (void)resume { CHECK(NO); }
@end
static EiscueFixturePendingConnection *newPendingConnection(void) {
    // Foundation documents this initializer as constructing only a local object.
    // The fixture never activates/resumes it or obtains a remote proxy.
    return [[EiscueFixturePendingConnection alloc] initWithMachServiceName:@"org.eiscue.fixture.unused" options:0];
}
static NSUInteger invalidFactoryCalls, invalidObjectInvalidations;
static IMP originalFileExists;
static id invalidFactoryObject;
typedef NS_ENUM(NSUInteger, FixtureLoaderMode) {
    FixtureLoaderInactive, FixtureLoaderModern, FixtureLoaderLegacy, FixtureLoaderFailed
};
static FixtureLoaderMode loaderMode;
static NSString *loaderRoot;
static NSMutableArray<NSString *> *loaderAttempts;
static BOOL loaderInteropReady, loaderTestingReady, loaderRunnerReady, loaderPointerReady;
static int loaderHandle;
static BOOL loaderPath(NSString *path, NSString *relative) {
    return [path isEqualToString:[loaderRoot stringByAppendingPathComponent:relative]];
}
static Class fixtureClassFromString(NSString *name) {
    if (loaderMode != FixtureLoaderInactive) {
        if ([name isEqualToString:@"XCTRunnerDaemonSession"]) return loaderRunnerReady ? NSObject.class : Nil;
        if ([name isEqualToString:@"XCPointerEventPath"]) return loaderPointerReady ? NSObject.class : Nil;
    }
    if (textPathClassOverride && [name isEqualToString:@"XCPointerEventPath"]) return textPathClassOverride;
    return NSClassFromString(name);
}
static void *fixtureDlopen(const char *path, int mode) {
    // No host developer library may load, even if another fixture unexpectedly
    // reaches this path. Model dependency failures rather than inspecting a list.
    CHECK(loaderMode != FixtureLoaderInactive && path);
    CHECK(mode == (RTLD_NOW | RTLD_GLOBAL));
    NSString *value=[NSString stringWithUTF8String:path]; CHECK(value);
    [loaderAttempts addObject:value];
    if (loaderMode == FixtureLoaderFailed) return NULL;
    CHECK([value hasPrefix:[loaderRoot stringByAppendingString:@"/"]]);
    if (loaderPath(value,@"usr/lib/lib_TestingInterop.dylib")) loaderInteropReady=YES;
    else if (loaderPath(value,@"Library/Frameworks/Testing.framework/Testing")) {
        if (!loaderInteropReady) return NULL;
        loaderTestingReady=YES;
    } else if (loaderPath(value,@"Library/PrivateFrameworks/XCTestCore.framework/XCTestCore")) {
        if (loaderMode == FixtureLoaderModern && (!loaderInteropReady || !loaderTestingReady)) return NULL;
        loaderRunnerReady=YES;
    } else if (loaderPath(value,@"Library/Frameworks/XCUIAutomation.framework/XCUIAutomation") ||
               loaderPath(value,@"Library/PrivateFrameworks/XCUIAutomation.framework/XCUIAutomation")) {
        if (!loaderRunnerReady) return NULL;
        loaderPointerReady=YES;
    }
    return &loaderHandle;
}
static BOOL fixtureFileExists(id receiver, SEL selector, NSString *path) {
    if (loaderMode != FixtureLoaderInactive) {
        if (loaderMode == FixtureLoaderFailed)
            return [path hasPrefix:@"/System/Developer/"] || [path hasPrefix:@"/Developer/"];
        if (![path hasPrefix:[loaderRoot stringByAppendingString:@"/"]]) return NO;
        if (loaderMode == FixtureLoaderLegacy &&
            (loaderPath(path,@"usr/lib/lib_TestingInterop.dylib") ||
             loaderPath(path,@"Library/Frameworks/Testing.framework/Testing"))) return NO;
        return YES;
    }
    if ([path isEqualToString:@"/System/Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework"])
        return YES;
    return ((BOOL (*)(id,SEL,NSString *))originalFileExists)(receiver,selector,path);
}
static void resetLoader(FixtureLoaderMode mode, NSString *root) {
    loaderMode=mode; loaderRoot=root; loaderAttempts=[NSMutableArray new];
    loaderInteropReady=NO; loaderTestingReady=NO; loaderRunnerReady=NO; loaderPointerReady=NO;
}
static void loaderFixtures(void) {
    Method fileExists=class_getInstanceMethod(NSFileManager.class,@selector(fileExistsAtPath:));
    originalFileExists=method_setImplementation(fileExists,(IMP)fixtureFileExists);
    @try {
        for (NSString *root in @[@"/System/Developer", @"/Developer"]) {
            resetLoader(FixtureLoaderModern,root);
            CHECK(loadFrameworks() && loaderInteropReady && loaderTestingReady && loaderRunnerReady && loaderPointerReady);
            NSUInteger interop=[loaderAttempts indexOfObject:[root stringByAppendingPathComponent:@"usr/lib/lib_TestingInterop.dylib"]];
            NSUInteger testing=[loaderAttempts indexOfObject:[root stringByAppendingPathComponent:@"Library/Frameworks/Testing.framework/Testing"]];
            NSUInteger core=[loaderAttempts indexOfObject:[root stringByAppendingPathComponent:@"Library/PrivateFrameworks/XCTestCore.framework/XCTestCore"]];
            CHECK(interop != NSNotFound && testing != NSNotFound && core != NSNotFound && interop < testing && testing < core);
            NSUInteger loaded=loaderAttempts.count;
            CHECK(loadFrameworks() && loaderAttempts.count==loaded);
        }
        // Earlier DDIs need neither optional dependency; missing files must not
        // prevent their XCTest classes from becoming available.
        resetLoader(FixtureLoaderLegacy,@"/System/Developer");
        CHECK(loadFrameworks() && loaderRunnerReady && loaderPointerReady);
        CHECK(!loaderInteropReady && !loaderTestingReady);
        CHECK(![loaderAttempts containsObject:[loaderRoot stringByAppendingPathComponent:@"usr/lib/lib_TestingInterop.dylib"]]);
        CHECK(![loaderAttempts containsObject:[loaderRoot stringByAppendingPathComponent:@"Library/Frameworks/Testing.framework/Testing"]]);
        resetLoader(FixtureLoaderFailed,nil);
        CHECK(!loadFrameworks() && !loaderRunnerReady && !loaderPointerReady && loaderAttempts.count>0);
        BOOL triedSystem=NO, triedLegacy=NO;
        for (NSString *path in loaderAttempts) {
            triedSystem |= [path hasPrefix:@"/System/Developer/"];
            triedLegacy |= [path hasPrefix:@"/Developer/"];
        }
        CHECK(triedSystem && triedLegacy);
        // A failed attempt must not poison a later retry after preparation.
        resetLoader(FixtureLoaderModern,@"/System/Developer");
        CHECK(loadFrameworks() && loaderRunnerReady && loaderPointerReady);
    } @finally {
        loaderMode=FixtureLoaderInactive; loaderRoot=nil; loaderAttempts=nil;
        method_setImplementation(fileExists,originalFileExists);
    }
}
static void noopObjectSetter(id receiver, SEL selector, id value) {}
static void noopBoolSetter(id receiver, SEL selector, BOOL value) {}
static void noopOrientation(id receiver, SEL selector, NSInteger orientation) {}
static id fixtureServiceName(id receiver, SEL selector) { return @"com.apple.dt.testmanagerd.runner"; }
static id invalidConnectionFactory(id receiver, SEL selector) { invalidFactoryCalls++; return invalidFactoryObject; }
static void unexpectedSessionFactory(id receiver, SEL selector, id connection, id completion) { CHECK(NO); }
static void invalidObjectInvalidate(id receiver, SEL selector) { invalidObjectInvalidations++; }

static id deviceEvent(id cls, SEL sel, uint32_t page, uint32_t usage, double duration) {
    constructions++; capturedPage=page; capturedUsage=usage; capturedDuration=duration;
    return [cls new];
}
static id initText(id receiver, SEL selector) { constructions++; return receiver; }
static id initTouch(id receiver, SEL selector, CGPoint point, double offset) { constructions++; capturedTouchPoint=point; return receiver; }
static void moveTouch(id receiver, SEL selector, CGPoint point, double offset) {}
static void liftTouch(id receiver, SEL selector, double offset) {}
static void fixtureTypeText(id receiver, SEL selector, id text, double offset, NSUInteger speed, BOOL redact) {
    textEvents++; capturedText=[text copy]; capturedOffset=offset; capturedTypingSpeed=speed; capturedRedaction=redact;
    if (throwOnTextConstruction) @throw [NSException exceptionWithName:@"FixtureTextConstruction" reason:nil userInfo:nil];
}
static id initRecord(id receiver, SEL selector, id name, uint64_t display, NSInteger orientation) {
    capturedName=[name copy]; capturedDisplay=display; capturedOrientation=orientation;
    if (dirtyDuringConstruction) invalidateGeometry(current);
    return receiver;
}
static void addPath(id receiver, SEL selector, id path) { capturedPath=path; }
static void receiveEvent(id receiver, id event, id completion) {
    submissions++; capturedEvent=event; lastCompletion=[completion copy];
    if (throwOnSend) @throw [NSException exceptionWithName:@"FixtureSubmit" reason:nil userInfo:nil];
}
static void performDevice(id receiver, SEL selector, id event, id completion) { receiveEvent(receiver,event,completion); }
static id synthesize(id receiver, SEL selector, id event, id completion) { receiveEvent(receiver,event,completion); return nil; }
static id fixtureConnection(id receiver, SEL selector) { return sessionConnection; }
static BOOL fixtureLegacyCoordinates(id receiver, SEL selector) { return legacyCoordinates; }
static id initImageEncoding(id receiver, SEL selector, NSString *type, double quality) {
    capturedImageType=[type copy]; capturedImageQuality=quality; return receiver;
}
static id initScreenshotRequest(id receiver, SEL selector, NSInteger screen, CGRect rect, id encoding) {
    capturedScreenID=screen; capturedCaptureRect=rect; capturedEncoding=encoding;
    if (dirtyDuringConstruction) invalidateGeometry(current);
    return receiver;
}
static void requestScreenshot(id receiver, SEL selector, id request, id reply) {
    screenshotSubmissions++; capturedScreenshotRequest=request; lastScreenshotReply=[reply copy];
    if (throwOnScreenshotSend) @throw [NSException exceptionWithName:@"FixtureScreenshot" reason:nil userInfo:nil];
}
static void method(Class cls, const char *selector, IMP implementation, const char *types) {
    CHECK(class_addMethod(cls,sel_registerName(selector),implementation,types));
}
static Class fixtureClass(const char *name) {
    Class cls=objc_allocateClassPair(NSObject.class,name,0); CHECK(cls); objc_registerClassPair(cls); return cls;
}
static void installFixtures(void) {
    Class device=fixtureClass("XCDeviceEvent");
    method(object_getClass(device),"deviceEventWithPage:usage:duration:",(IMP)deviceEvent,"@32@0:8I16I20d24");
    Class path=fixtureClass("XCPointerEventPath");
    method(path,"initForTextInput",(IMP)initText,"@16@0:8");
    // Exact Xcode 26/27 device SDK method encoding, including integer speed.
    method(path,"typeText:atOffset:typingSpeed:shouldRedact:",(IMP)fixtureTypeText,"v44@0:8@16d24Q32B40");
    method(path,"initForTouchAtPoint:offset:",(IMP)initTouch,"@40@0:8{CGPoint=dd}16d32");
    method(path,"moveToPoint:atOffset:",(IMP)moveTouch,"v40@0:8{CGPoint=dd}16d32");
    method(path,"liftUpAtOffset:",(IMP)liftTouch,"v24@0:8d16");
    Class record=fixtureClass("XCSynthesizedEventRecord");
    method(record,"initWithName:displayID:interfaceOrientation:",(IMP)initRecord,"@40@0:8@16Q24q32");
    method(record,"addPointerEventPath:",(IMP)addPath,"v24@0:8@16");
    Class encoding=fixtureClass("XCTImageEncoding");
    method(encoding,"initWithUniformTypeIdentifier:compressionQuality:",(IMP)initImageEncoding,"@32@0:8@16d24");
    Class capture=fixtureClass("XCTScreenshotRequest");
    method(capture,"initWithScreenID:rect:encoding:",(IMP)initScreenshotRequest,"@64@0:8q16{CGRect={CGPoint=dd}{CGSize=dd}}24@56");
    fakeSessionClass=fixtureClass("EiscueFixtureSession");
    method(fakeSessionClass,"performDeviceEvent:completion:",(IMP)performDevice,"v32@0:8@16@?24");
    method(fakeSessionClass,"synthesizeEvent:completion:",(IMP)synthesize,"@32@0:8@16@?24");
    method(fakeSessionClass,"connection",(IMP)fixtureConnection,"@16@0:8");
    method(fakeSessionClass,"useLegacyEventCoordinateTransformationPath",(IMP)fixtureLegacyCoordinates,"B16@0:8");
    method(fakeSessionClass,"requestScreenshotWithRequest:withReply:",(IMP)requestScreenshot,"v32@0:8@16@?24");
    wrongSignatureSessionClass=fixtureClass("EiscueFixtureWrongSignatureSession");
    method(wrongSignatureSessionClass,"performDeviceEvent:completion:",(IMP)performDevice,"v24@0:8@16");
    method(wrongSignatureSessionClass,"synthesizeEvent:completion:",(IMP)synthesize,"v32@0:8@16@?24");
    method(wrongSignatureSessionClass,"requestScreenshotWithRequest:withReply:",(IMP)requestScreenshot,"@32@0:8@16@?24");
}
static void resetOwner(void) {
    if (current) eiscue_automation_abort(current.lease);
    current=[EiscueOwnedAutomation new]; current.lease=19;
    current.status=(eiscue_automation_state){.phase=EISCUE_AUTOMATION_READY,.revision=7,.display_id=3,.orientation=1,.scale=3,.bounds_width=390,.bounds_height=844};
    current.session=[fakeSessionClass new]; current.observers=[NSMutableArray new];
    submissions=0; constructions=0; textEvents=0; clipboardAccesses=0; capturedTypingSpeed=0; capturedRedaction=NO;
    dirtyDuringConstruction=NO; throwOnSend=NO; throwOnTextConstruction=NO; textPathClassOverride=Nil;
    legacyCoordinates=NO;
    capturedText=nil; capturedName=nil; capturedPath=nil; capturedEvent=nil; lastCompletion=nil;
    capturedImageType=nil; capturedImageQuality=0; capturedScreenID=-1; capturedCaptureRect=CGRectZero;
    capturedEncoding=nil; capturedScreenshotRequest=nil; lastScreenshotReply=nil;
    screenshotSubmissions=0; throwOnScreenshotSend=NO;
    sessionConnection=nil;
}
static void receipt(BOOL success, NSError *error) {
    CHECK(lastCompletion); lastCompletion(success,error);
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
static void expectInvalid(const uint8_t *bytes, size_t length) {
    NSUInteger before=submissions, built=constructions, events=textEvents;
    CHECK(eiscue_automation_type_text(19,1,7,bytes,length)==EISCUE_AUTOMATION_CONFIGURATION);
    CHECK(submissions==before && constructions==built && textEvents==events && clipboardAccesses==0);
    CHECK(current.status.phase==EISCUE_AUTOMATION_READY && current.status.request_id==0);
}
static void expectEnvironment(const char *name, const char *expected) {
    const char *value=getenv(name);
    CHECK(expected ? value && strcmp(value,expected)==0 : value==NULL);
}
static void invalidFactoryFixture(void) {
    // Fake SDK signatures drive the production begin path to the connection
    // factory. All framework names resolve to these local NSObject classes.
    Class config=fixtureClass("XCTestConfiguration");
    method(object_getClass(config),"setActiveTestConfiguration:",(IMP)noopObjectSetter,"v24@0:8@16");
    method(config,"setSessionIdentifier:",(IMP)noopObjectSetter,"v24@0:8@16");
    method(config,"setAutomationFrameworkPath:",(IMP)noopObjectSetter,"v24@0:8@16");
    method(config,"setTestsDrivenByIDE:",(IMP)noopBoolSetter,"v20@0:8B16");
    method(config,"setReportResultsToIDE:",(IMP)noopBoolSetter,"v20@0:8B16");
    method(config,"setInitializeForUITesting:",(IMP)noopBoolSetter,"v20@0:8B16");
    Class runner=fixtureClass("XCTRunnerDaemonSession");
    method(runner,"_XCT_interfaceOrientationDidChange:",(IMP)noopOrientation,"v24@0:8q16");
    method(object_getClass(runner),"testmanagerdServiceName",(IMP)fixtureServiceName,"@16@0:8");
    method(object_getClass(runner),"connectionForInitiatingSharedSession",(IMP)invalidConnectionFactory,"@16@0:8");
    method(object_getClass(runner),"sessionWithConnection:completion:",(IMP)unexpectedSessionFactory,"v32@0:8@16@?24");
    Class invalid=fixtureClass("EiscueFixtureInvalidConnection");
    method(invalid,"invalidate",(IMP)invalidObjectInvalidate,"v16@0:8");
    invalidFactoryObject=[invalid new];
    resetOwner(); eiscue_automation_abort(19);
    CHECK(setenv("XCTestManagerVariant","fixture.factory.variant",1)==0);
    CHECK(unsetenv("XCTestSessionIdentifier")==0);
    Method fileExists=class_getInstanceMethod(NSFileManager.class,@selector(fileExistsAtPath:));
    originalFileExists=method_setImplementation(fileExists,(IMP)fixtureFileExists);
    uint8_t uuid[16]={0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xaa,0xbb,0xcc,0xdd,0xee,0xff,0};
    uint64_t lease=0;
    @try { CHECK(eiscue_automation_begin(uuid,&lease)==EISCUE_AUTOMATION_RUNNER); }
    @finally { method_setImplementation(fileExists,originalFileExists); }
    CHECK(lease && current.lease==lease && invalidFactoryCalls==1);
    CHECK(invalidObjectInvalidations==0 && !current.pendingConnection && !current.cleanupFailed);
    CHECK(current.closed && current.status.phase==EISCUE_AUTOMATION_STOPPED && current.observers.count==0);
    expectEnvironment("XCTestManagerVariant","fixture.factory.variant");
    expectEnvironment("XCTestSessionIdentifier",NULL);
    CHECK(unsetenv("XCTestManagerVariant")==0);
}
static void environmentAndPendingFixtures(void) {
    NSUUID *identifier=[[NSUUID alloc] initWithUUIDString:@"11223344-5566-7788-99AA-BBCCDDEEFF00"];
    CHECK(identifier);
    // Abort restores existing values and releases a pending connection even
    // before a session callback has provided any session object.
    resetOwner(); current.session=nil;
    current.status=(eiscue_automation_state){.phase=EISCUE_AUTOMATION_PREPARING,.revision=1};
    CHECK(setenv("XCTestManagerVariant","fixture.previous.variant",1)==0);
    CHECK(setenv("XCTestSessionIdentifier","fixture.previous.identifier",1)==0);
    EiscueFixturePendingConnection *pending=newPendingConnection();
    CHECK([pending isKindOfClass:NSXPCConnection.class]);
    current.pendingConnection=pending;
    CHECK(configureEnvironment(current,identifier) && current.ownsEnvironment);
    expectEnvironment("XCTestManagerVariant","DDI");
    expectEnvironment("XCTestSessionIdentifier",identifier.UUIDString.UTF8String);
    eiscue_automation_abort(19);
    CHECK(pending.invalidations==1 && !current.pendingConnection && !current.session);
    CHECK(current.closed && current.status.phase==EISCUE_AUTOMATION_STOPPED && !current.ownsEnvironment);
    expectEnvironment("XCTestManagerVariant","fixture.previous.variant");
    expectEnvironment("XCTestSessionIdentifier","fixture.previous.identifier");
    eiscue_automation_abort(19); CHECK(pending.invalidations==1);

    // Originally absent variables must be unset rather than restored as empty.
    resetOwner();
    CHECK(unsetenv("XCTestManagerVariant")==0 && unsetenv("XCTestSessionIdentifier")==0);
    CHECK(configureEnvironment(current,identifier));
    eiscue_automation_abort(19);
    expectEnvironment("XCTestManagerVariant",NULL);
    expectEnvironment("XCTestSessionIdentifier",NULL);

    // A present empty value is distinct from an absent one.
    resetOwner();
    CHECK(setenv("XCTestManagerVariant","",1)==0);
    CHECK(configureEnvironment(current,identifier));
    eiscue_automation_abort(19);
    expectEnvironment("XCTestManagerVariant","");
    expectEnvironment("XCTestSessionIdentifier",NULL);

    // A failed begin must abort its owned resources and environment, keeping
    // the reported failure code. Late queued callbacks cannot revive this owner.
    resetOwner();
    current.status=(eiscue_automation_state){.phase=EISCUE_AUTOMATION_PREPARING,.revision=1};
    CHECK(setenv("XCTestManagerVariant","fixture.failure.variant",1)==0);
    CHECK(setenv("XCTestSessionIdentifier","fixture.failure.identifier",1)==0);
    CHECK(configureEnvironment(current,identifier));
    pending=newPendingConnection();
    EiscueFixturePendingConnection *connected=newPendingConnection();
    current.pendingConnection=pending; sessionConnection=connected;
    EiscueOwnedAutomation *failedOwner=current;
    __block NSUInteger lateCallbacks=0;
    onMain(failedOwner, ^{ lateCallbacks++; });
    CHECK(beginFailure(failedOwner,EISCUE_AUTOMATION_SIGNATURE)==EISCUE_AUTOMATION_SIGNATURE);
    CHECK(pending.invalidations==1 && connected.invalidations==1);
    CHECK(!failedOwner.pendingConnection && !failedOwner.session && !failedOwner.ownsEnvironment);
    CHECK(failedOwner.closed && failedOwner.status.phase==EISCUE_AUTOMATION_STOPPED);
    expectEnvironment("XCTestManagerVariant","fixture.failure.variant");
    expectEnvironment("XCTestSessionIdentifier","fixture.failure.identifier");
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    CHECK(lateCallbacks==0 && failedOwner.status.phase==EISCUE_AUTOMATION_STOPPED);

    // An invalidation exception must not skip environment restoration or falsely
    // acknowledge release. Stop preserves the uncertain cleanup result.
    resetOwner();
    CHECK(setenv("XCTestManagerVariant","fixture.throw.variant",1)==0);
    CHECK(unsetenv("XCTestSessionIdentifier")==0);
    CHECK(configureEnvironment(current,identifier));
    pending=newPendingConnection(); pending.throwsOnInvalidate=YES;
    current.pendingConnection=pending;
    CHECK(eiscue_automation_stop(19)==EISCUE_AUTOMATION_EXCEPTION);
    CHECK(pending.invalidations==1 && current.cleanupFailed && !current.pendingConnection);
    CHECK(current.closed && !current.ownsEnvironment && current.status.phase==EISCUE_AUTOMATION_STOPPED);
    expectEnvironment("XCTestManagerVariant","fixture.throw.variant");
    expectEnvironment("XCTestSessionIdentifier",NULL);
    CHECK(eiscue_automation_stop(19)==EISCUE_AUTOMATION_EXCEPTION && pending.invalidations==1);
    // Keep subsequent fixtures independent of the local initialization settings.
    CHECK(unsetenv("XCTestManagerVariant")==0 && unsetenv("XCTestSessionIdentifier")==0);
}
static void drainReplies(void) {
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
static EiscueFixtureImage *fixtureImage(id bytes) {
    EiscueFixtureImage *image=[EiscueFixtureImage new]; image.bytes=bytes; return image;
}
static void screenshotFixtures(void) {
    // Only the PNG transport signature matters here; decoding is owned by Swift.
    const uint8_t png[]={137,80,78,71,13,10,26,10,1,2};
    NSData *data=[NSData dataWithBytes:png length:sizeof(png)];
    uint8_t copied[sizeof(png)]; size_t length=123;
    resetOwner();
    CHECK(eiscue_automation_screenshot(18,1,7)==EISCUE_AUTOMATION_CLOSED);
    CHECK(eiscue_automation_screenshot(19,1,6)==EISCUE_AUTOMATION_GEOMETRY);
    CHECK(screenshotSubmissions==0 && current.status.request_id==0);
    CHECK(eiscue_automation_copy_screenshot(19,1,NULL,0,NULL)==EISCUE_AUTOMATION_CONFIGURATION);
    CHECK(eiscue_automation_screenshot(19,1,7)==0 && screenshotSubmissions==1);
    CHECK([capturedImageType isEqualToString:@"public.png"] && capturedImageQuality==1);
    CHECK(capturedScreenID==3 && CGRectIsNull(capturedCaptureRect));
    CHECK(capturedEncoding && capturedScreenshotRequest && lastScreenshotReply);
    CHECK(current.status.phase==EISCUE_AUTOMATION_CAPTURING && current.status.request_id==1);
    CHECK(current.screenshotRequest==1 && !current.eventPending);
    CHECK(eiscue_automation_screenshot(19,2,7)==EISCUE_AUTOMATION_BUSY);
    CHECK(eiscue_automation_home(19,2,7)==EISCUE_AUTOMATION_BUSY);
    CHECK(eiscue_automation_type_text(19,2,7,(const uint8_t *)"x",1)==EISCUE_AUTOMATION_BUSY);
    CHECK(eiscue_automation_touch(19,2,7,1170,2532,0,0,0,0,0)==EISCUE_AUTOMATION_BUSY);
    CHECK(screenshotSubmissions==1 && submissions==0 && clipboardAccesses==0);
    CHECK(eiscue_automation_copy_screenshot(19,1,NULL,0,&length)==EISCUE_AUTOMATION_BUSY && length==0);

    // The framework callback may arrive off-main; it must not publish there.
    NSMutableData *mutable=[data mutableCopy]; EiscueFixtureImage *image=fixtureImage(mutable);
    void (^reply)(id,NSError *)=[lastScreenshotReply copy];
    dispatch_semaphore_t finished=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0), ^{
        reply(image,nil); dispatch_semaphore_signal(finished);
    });
    CHECK(dispatch_semaphore_wait(finished,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
    CHECK(current.status.phase==EISCUE_AUTOMATION_CAPTURING && !current.screenshotData);
    drainReplies();
    memset(mutable.mutableBytes,0,mutable.length);
    CHECK(current.status.phase==EISCUE_AUTOMATION_READY && !current.closed);
    CHECK(eiscue_automation_home(19,2,7)==EISCUE_AUTOMATION_BUSY);
    CHECK(eiscue_automation_copy_screenshot(19,1,NULL,0,&length)==0 && length==sizeof(png));
    CHECK(eiscue_automation_copy_screenshot(19,1,copied,sizeof(copied)-1,&length)==EISCUE_AUTOMATION_CONFIGURATION);
    CHECK(current.screenshotRequest==1 && current.screenshotData);
    CHECK(eiscue_automation_copy_screenshot(19,1,copied,sizeof(copied),&length)==0);
    CHECK(length==sizeof(png) && memcmp(copied,png,sizeof(png))==0);
    CHECK(!current.screenshotData && current.screenshotRequest==0);
    CHECK(eiscue_automation_copy_screenshot(19,1,NULL,0,&length)==EISCUE_AUTOMATION_CLOSED && length==0);
    CHECK(eiscue_automation_screenshot(19,1,7)==EISCUE_AUTOMATION_BUSY);
    CHECK(eiscue_automation_home(19,2,7)==0);
    CHECK(eiscue_automation_screenshot(19,3,7)==EISCUE_AUTOMATION_BUSY && screenshotSubmissions==1);
    receipt(YES,nil);

    // Cancel releases only this read. A late old reply must neither finish nor
    // cancel a newer capture on the same owned runner.
    resetOwner();
    EiscueFixturePendingConnection *connection=newPendingConnection(); sessionConnection=connection;
    id session=current.session;
    CHECK(eiscue_automation_screenshot(19,1,7)==0);
    void (^oldReply)(id,NSError *)=[lastScreenshotReply copy];
    eiscue_automation_cancel_screenshot(19,1);
    CHECK(current.status.phase==EISCUE_AUTOMATION_READY && current.screenshotRequest==0);
    CHECK(current.session==session && !current.closed && connection.invalidations==0);
    CHECK(eiscue_automation_screenshot(19,1,7)==EISCUE_AUTOMATION_BUSY);
    CHECK(eiscue_automation_screenshot(19,2,7)==0);
    eiscue_automation_cancel_screenshot(19,1);
    eiscue_automation_cancel_screenshot(18,2);
    oldReply(fixtureImage(data),nil); drainReplies();
    CHECK(current.status.phase==EISCUE_AUTOMATION_CAPTURING && current.screenshotRequest==2);
    CHECK(!current.screenshotData && current.screenshotError==0 && connection.invalidations==0);
    lastScreenshotReply(fixtureImage(data),nil); drainReplies();
    CHECK(eiscue_automation_copy_screenshot(19,2,copied,sizeof(copied),&length)==0);
    CHECK(memcmp(copied,png,sizeof(png))==0 && current.session==session);

    // Replacing an aborted owner can reuse request IDs without admitting its
    // queued result into the replacement session.
    CHECK(eiscue_automation_screenshot(19,3,7)==0);
    oldReply=[lastScreenshotReply copy]; EiscueOwnedAutomation *oldOwner=current;
    resetOwner(); CHECK(oldOwner.closed && connection.invalidations==1);
    CHECK(eiscue_automation_screenshot(19,1,7)==0);
    oldReply(fixtureImage(data),nil); drainReplies();
    CHECK(current.status.phase==EISCUE_AUTOMATION_CAPTURING && current.screenshotRequest==1);
    CHECK(!current.screenshotData && oldOwner.status.phase==EISCUE_AUTOMATION_STOPPED);
    eiscue_automation_cancel_screenshot(19,1);

    // Failures of an observation never invalidate the existing input session.
    NSError *error=[NSError errorWithDomain:@"FixtureScreenshot" code:1 userInfo:nil];
    EiscueFixtureImage *throwing=fixtureImage(data); throwing.throwsOnData=YES;
    NSArray *images=@[fixtureImage(data),[NSObject new],fixtureImage(@"not bytes"),
                      fixtureImage([NSData data]),fixtureImage([@"invalid PNG" dataUsingEncoding:NSUTF8StringEncoding]),throwing];
    for (NSUInteger index=0;index<images.count;index++) {
        resetOwner(); connection=newPendingConnection(); sessionConnection=connection; session=current.session;
        CHECK(eiscue_automation_screenshot(19,1,7)==0);
        lastScreenshotReply(images[index],index==0?error:nil); drainReplies();
        CHECK(eiscue_automation_copy_screenshot(19,1,NULL,0,&length)==
              (index==images.count-1?EISCUE_AUTOMATION_EXCEPTION:EISCUE_AUTOMATION_CONFIGURATION));
        CHECK(length==0 && !current.closed && current.session==session && connection.invalidations==0);
        CHECK(current.status.phase==EISCUE_AUTOMATION_READY && current.status.error==0);
        eiscue_automation_cancel_screenshot(19,1);
        CHECK(eiscue_automation_home(19,2,7)==0); receipt(YES,nil);
    }

    // Rotation before delivery or between the length and byte copies rejects
    // stale pixels without disconnecting. A fresh geometry query is required.
    for (NSUInteger stage=0;stage<2;stage++) {
        resetOwner(); connection=newPendingConnection(); sessionConnection=connection; session=current.session;
        CHECK(eiscue_automation_screenshot(19,1,7)==0);
        if (stage==0) invalidateGeometry(current);
        lastScreenshotReply(fixtureImage(data),nil); drainReplies();
        if (stage==1) {
            CHECK(eiscue_automation_copy_screenshot(19,1,NULL,0,&length)==0 && length==sizeof(png));
            invalidateGeometry(current);
        }
        CHECK(eiscue_automation_copy_screenshot(19,1,copied,sizeof(copied),&length)==EISCUE_AUTOMATION_GEOMETRY);
        CHECK(length==0 && current.geometryDirty && current.status.revision==8);
        CHECK(!current.closed && current.session==session && connection.invalidations==0);
        CHECK(current.status.phase==EISCUE_AUTOMATION_READY && current.status.error==0);
        eiscue_automation_cancel_screenshot(19,1);
        CHECK(eiscue_automation_home(19,2,8)==EISCUE_AUTOMATION_GEOMETRY && submissions==0);
    }
    resetOwner(); dirtyDuringConstruction=YES;
    CHECK(eiscue_automation_screenshot(19,1,7)==EISCUE_AUTOMATION_GEOMETRY && screenshotSubmissions==0);
    CHECK(current.status.request_id==0 && !current.closed && current.session);
    resetOwner(); current.session=[wrongSignatureSessionClass new];
    CHECK(eiscue_automation_screenshot(19,1,7)==EISCUE_AUTOMATION_SIGNATURE && screenshotSubmissions==0);
    CHECK(current.status.phase==EISCUE_AUTOMATION_READY && current.screenshotRequest==0);
    resetOwner(); throwOnScreenshotSend=YES; session=current.session;
    CHECK(eiscue_automation_screenshot(19,1,7)==EISCUE_AUTOMATION_EXCEPTION && screenshotSubmissions==1);
    CHECK(current.status.phase==EISCUE_AUTOMATION_READY && current.screenshotRequest==0);
    CHECK(!current.closed && current.session==session);
    lastScreenshotReply(fixtureImage(data),nil); drainReplies();
    CHECK(!current.screenshotData && current.status.phase==EISCUE_AUTOMATION_READY);

    resetOwner(); CHECK(eiscue_automation_screenshot(19,1,7)==0);
    __block int32_t wrongThreadStart=0, wrongThreadCopy=0;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0), ^{
        size_t copiedLength=0;
        wrongThreadStart=eiscue_automation_screenshot(19,2,7);
        wrongThreadCopy=eiscue_automation_copy_screenshot(19,1,NULL,0,&copiedLength);
        eiscue_automation_cancel_screenshot(19,1); dispatch_semaphore_signal(finished);
    });
    CHECK(dispatch_semaphore_wait(finished,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
    CHECK(wrongThreadStart==EISCUE_AUTOMATION_WRONG_THREAD && wrongThreadCopy==EISCUE_AUTOMATION_WRONG_THREAD);
    CHECK(current.status.phase==EISCUE_AUTOMATION_CAPTURING && current.screenshotRequest==1 && screenshotSubmissions==1);
    eiscue_automation_cancel_screenshot(19,1);
}
int main(void) { @autoreleasepool {
    alarm(15); // A missing async callback must terminate this host fixture.
    CHECK(NSThread.isMainThread); loaderFixtures(); installFixtures(); environmentAndPendingFixtures(); invalidFactoryFixture(); screenshotFixtures(); resetOwner();
    // Exact local SDK Home payload and receipt identity; no automatic retry.
    CHECK(eiscue_automation_home(18,1,7)==EISCUE_AUTOMATION_CLOSED);
    CHECK(eiscue_automation_home(19,1,6)==EISCUE_AUTOMATION_GEOMETRY && submissions==0);
    CHECK(eiscue_automation_home(19,1,7)==0 && submissions==1);
    CHECK(capturedPage==12 && capturedUsage==64 && capturedDuration==0.005);
    CHECK(current.eventPending && current.status.phase==EISCUE_AUTOMATION_DELIVERING && current.status.request_id==1);
    CHECK(eiscue_automation_home(19,1,7)==EISCUE_AUTOMATION_BUSY);
    CHECK(eiscue_automation_home(19,2,7)==EISCUE_AUTOMATION_BUSY && submissions==1);
    CHECK(eiscue_automation_stop(19)==EISCUE_AUTOMATION_BUSY);
    receipt(YES,nil); CHECK(!current.eventPending && current.status.phase==EISCUE_AUTOMATION_READY);
    CHECK(eiscue_automation_home(19,1,7)==EISCUE_AUTOMATION_BUSY && submissions==1);
    CHECK(eiscue_automation_home(19,2,7)==0); receipt(NO,nil);
    CHECK(current.status.phase==EISCUE_AUTOMATION_FAILED && current.status.error==EISCUE_AUTOMATION_DELIVERY_UNKNOWN && submissions==2);
    CHECK(eiscue_automation_home(19,3,7)==EISCUE_AUTOMATION_BUSY && submissions==2);
    resetOwner();
    current.session=[wrongSignatureSessionClass new];
    CHECK(eiscue_automation_home(19,1,7)==EISCUE_AUTOMATION_SIGNATURE);
    CHECK(eiscue_automation_type_text(19,1,7,(const uint8_t *)"hello",5)==EISCUE_AUTOMATION_SIGNATURE);
    CHECK(submissions==0 && !current.eventPending && current.status.request_id==0 && clipboardAccesses==0);
    // An absent or changed private text ABI must fail before creating an event.
    resetOwner();
    Class absentTextPath=fixtureClass("EiscueFixtureAbsentTextPath");
    method(absentTextPath,"initForTextInput",(IMP)initText,"@16@0:8");
    textPathClassOverride=absentTextPath;
    CHECK(eiscue_automation_type_text(19,1,7,(const uint8_t *)"hello",5)==EISCUE_AUTOMATION_SIGNATURE);
    CHECK(submissions==0 && constructions==0 && textEvents==0 && clipboardAccesses==0 && !current.eventPending);
    Class changedTextPath=fixtureClass("EiscueFixtureChangedTextPath");
    method(changedTextPath,"initForTextInput",(IMP)initText,"@16@0:8");
    method(changedTextPath,"typeText:atOffset:typingSpeed:shouldRedact:",(IMP)fixtureTypeText,"v44@0:8@16d24d32B40");
    textPathClassOverride=changedTextPath;
    CHECK(eiscue_automation_type_text(19,1,7,(const uint8_t *)"hello",5)==EISCUE_AUTOMATION_SIGNATURE);
    CHECK(submissions==0 && constructions==0 && textEvents==0 && current.status.request_id==0);
    resetOwner();
    __block int32_t wrongThreadHome=0, wrongThreadText=0;
    dispatch_semaphore_t workerFinished=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0), ^{
        wrongThreadHome=eiscue_automation_home(19,1,7);
        wrongThreadText=eiscue_automation_type_text(19,1,7,(const uint8_t *)"hello",5);
        dispatch_semaphore_signal(workerFinished);
    });
    CHECK(dispatch_semaphore_wait(workerFinished,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
    CHECK(wrongThreadHome==EISCUE_AUTOMATION_WRONG_THREAD && wrongThreadText==EISCUE_AUTOMATION_WRONG_THREAD);
    CHECK(submissions==0);
    // Canonical Unicode validation includes NUL, malformed/overlong sequences,
    // UTF-16 surrogates, out-of-range scalars and the ABI's byte-count limit.
    expectInvalid(NULL,1); expectInvalid((const uint8_t *)"x",0);
    uint8_t nul[]={0}; expectInvalid(nul,sizeof(nul));
    uint8_t embedded[]={'a',0,'b'}; expectInvalid(embedded,sizeof(embedded));
    uint8_t lone[]={0x80}; expectInvalid(lone,sizeof(lone));
    uint8_t truncated[]={0xf0,0x9f,0x98}; expectInvalid(truncated,sizeof(truncated));
    uint8_t overlong2[]={0xc0,0x80}; expectInvalid(overlong2,sizeof(overlong2));
    uint8_t overlong3[]={0xe0,0x80,0xaf}; expectInvalid(overlong3,sizeof(overlong3));
    uint8_t overlong4[]={0xf0,0x80,0x80,0xaf}; expectInvalid(overlong4,sizeof(overlong4));
    uint8_t surrogate[]={0xed,0xa0,0x80}; expectInvalid(surrogate,sizeof(surrogate));
    uint8_t range[]={0xf4,0x90,0x80,0x80}; expectInvalid(range,sizeof(range));
    uint8_t badlead[]={0xf5,0x80,0x80,0x80}; expectInvalid(badlead,sizeof(badlead));
    uint8_t huge[8193]; memset(huge,'a',sizeof(huge)); expectInvalid(huge,sizeof(huge));
    CHECK(validTextBytes(huge,8192));
    uint8_t highest[]={0xf4,0x8f,0xbf,0xbf}; CHECK(validTextBytes(highest,sizeof(highest)));
    uint8_t unicode[]={0xe4,0xbd,0xa0,0xe5,0xa5,0xbd,0xf0,0x9f,0x98,0x80};
    CHECK(eiscue_automation_type_text(19,1,7,unicode,sizeof(unicode))==0 && submissions==1);
    memset(unicode,'x',sizeof(unicode)); CHECK([capturedText isEqualToString:@"你好😀"]);
    CHECK(textEvents==1 && capturedOffset==0 && capturedTypingSpeed==60 && capturedRedaction);
    CHECK(clipboardAccesses==0 && [capturedName isEqualToString:@"Eiscue"]);
    CHECK(capturedDisplay==3 && capturedOrientation==1 && capturedPath && capturedEvent);
    CHECK(eiscue_automation_stop(19)==EISCUE_AUTOMATION_BUSY);
    CHECK(eiscue_automation_type_text(19,2,7,(const uint8_t *)"blocked",7)==EISCUE_AUTOMATION_BUSY);
    CHECK(textEvents==1 && clipboardAccesses==0 && submissions==1);
    receipt(YES,nil); CHECK(current.status.phase==EISCUE_AUTOMATION_READY);
    CHECK(eiscue_automation_type_text(19,1,7,(const uint8_t *)"duplicate",9)==EISCUE_AUTOMATION_BUSY);
    CHECK(textEvents==1 && clipboardAccesses==0 && submissions==1);
    CHECK(eiscue_automation_type_text(19,2,7,huge,8192)==0);
    CHECK(capturedText.length==8192 && submissions==2 && textEvents==2 && clipboardAccesses==0);
    // Cleanup must retain the session for the original (potentially long)
    // event. Stop cannot abort it or pretend the callback was received.
    id pendingTextSession=current.session;
    CHECK(eiscue_automation_stop(19)==EISCUE_AUTOMATION_BUSY);
    CHECK(current.eventPending && !current.closed && current.session==pendingTextSession);
    receipt(YES,nil);
    CHECK(!current.eventPending && !current.closed && current.session==pendingTextSession);
    // Preserve composed Unicode and control characters without per-scalar
    // events or shortcut fallback. This also covers the physical check's text.
    NSString *complexText=@"你好，Eiscue 🧊 e\u0301 👨‍👩‍👧‍👦\r\n";
    NSData *complexBytes=[complexText dataUsingEncoding:NSUTF8StringEncoding];
    CHECK(eiscue_automation_type_text(19,3,7,complexBytes.bytes,complexBytes.length)==0);
    CHECK([capturedText isEqualToString:complexText] && textEvents==3 && submissions==3 && clipboardAccesses==0);
    CHECK(capturedRedaction && capturedTypingSpeed==60); receipt(YES,nil);
    CHECK(eiscue_automation_home(19,4,7)==0);
    invalidateGeometry(current);
    receipt(YES,nil);
    CHECK(current.geometryDirty && current.status.revision==8 && current.status.phase==EISCUE_AUTOMATION_READY);
    CHECK(eiscue_automation_home(19,5,8)==EISCUE_AUTOMATION_GEOMETRY && submissions==4);
    // Revalidation after building an event stops a changed orientation/revision.
    resetOwner(); dirtyDuringConstruction=YES;
    CHECK(eiscue_automation_type_text(19,1,7,(const uint8_t *)"hello",5)==EISCUE_AUTOMATION_GEOMETRY);
    CHECK(submissions==0 && clipboardAccesses==0 && current.geometryDirty && current.status.revision==8 && current.status.request_id==0);
    resetOwner();
    CHECK(eiscue_automation_type_text(19,1,6,(const uint8_t *)"stale",5)==EISCUE_AUTOMATION_GEOMETRY);
    CHECK(textEvents==0 && clipboardAccesses==0 && submissions==0);
    eiscue_automation_abort(19);
    CHECK(eiscue_automation_type_text(19,1,7,(const uint8_t *)"closed",6)==EISCUE_AUTOMATION_CLOSED);
    CHECK(textEvents==0 && clipboardAccesses==0 && submissions==0);
    resetOwner(); throwOnTextConstruction=YES;
    CHECK(eiscue_automation_type_text(19,1,7,(const uint8_t *)"hello",5)==EISCUE_AUTOMATION_EXCEPTION);
    CHECK(textEvents==1 && clipboardAccesses==0 && submissions==0 && current.status.phase==EISCUE_AUTOMATION_FAILED);
    CHECK(eiscue_automation_type_text(19,2,7,(const uint8_t *)"retry",5)==EISCUE_AUTOMATION_BUSY);
    CHECK(textEvents==1 && clipboardAccesses==0 && submissions==0);
    resetOwner(); throwOnSend=YES;
    CHECK(eiscue_automation_type_text(19,1,7,(const uint8_t *)"hello",5)==EISCUE_AUTOMATION_DELIVERY_UNKNOWN);
    CHECK(textEvents==1 && clipboardAccesses==0 && submissions==1 && current.eventPending && current.status.phase==EISCUE_AUTOMATION_FAILED);
    CHECK(eiscue_automation_type_text(19,2,7,(const uint8_t *)"retry",5)==EISCUE_AUTOMATION_BUSY);
    CHECK(textEvents==1 && clipboardAccesses==0 && submissions==1);
    resetOwner(); throwOnSend=YES;
    CHECK(eiscue_automation_home(19,1,7)==EISCUE_AUTOMATION_DELIVERY_UNKNOWN);
    CHECK(submissions==1 && current.eventPending && current.status.phase==EISCUE_AUTOMATION_FAILED);
    CHECK(eiscue_automation_home(19,2,7)==EISCUE_AUTOMATION_BUSY && submissions==1);
    // Abort owns the old receipt; a late completion cannot revive it.
    void (^oldReceipt)(BOOL,NSError *)=[lastCompletion copy]; EiscueOwnedAutomation *old=current;
    eiscue_automation_abort(19);
    resetOwner();
    CHECK(eiscue_automation_home(19,1,7)==0);
    oldReceipt(YES,nil);
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    CHECK(old.closed && old.status.phase==EISCUE_AUTOMATION_STOPPED);
    CHECK(current.status.phase==EISCUE_AUTOMATION_DELIVERING && current.eventPending && current.status.request_id==1);
    id pendingTouchSession=current.session;
    CHECK(eiscue_automation_stop(19)==EISCUE_AUTOMATION_BUSY);
    CHECK(!current.closed && current.session==pendingTouchSession);
    void (^backgroundReceipt)(BOOL,NSError *)=[lastCompletion copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0), ^{
        backgroundReceipt(YES,nil); dispatch_semaphore_signal(workerFinished);
    });
    CHECK(dispatch_semaphore_wait(workerFinished,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
    CHECK(current.status.phase==EISCUE_AUTOMATION_DELIVERING);
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    CHECK(current.status.phase==EISCUE_AUTOMATION_READY && !current.eventPending);
    CHECK(eiscue_automation_stop(19)==0);
    CHECK(eiscue_automation_stop(19)==0 && current.status.phase==EISCUE_AUTOMATION_STOPPED);
    resetOwner();
    CHECK(eiscue_automation_touch(19,1,7,1170,2532,0,0,0,0,0)==0);
    receipt(YES,nil); CHECK(current.status.phase==EISCUE_AUTOMATION_READY && submissions==1);
    NSError *error=[NSError errorWithDomain:@"Fixture" code:1 userInfo:nil];
    CHECK(eiscue_automation_type_text(19,2,7,(const uint8_t *)"hello",5)==0);
    receipt(YES,error); CHECK(current.status.phase==EISCUE_AUTOMATION_FAILED && current.status.error==EISCUE_AUTOMATION_DELIVERY_UNKNOWN);
    // Actual iPhone 14 Pro screen-service geometry is pixels, at scale three.
    // Converting twice rejected its first 1179x2556 screenshot as stale.
    resetOwner();
    finishGeometry(current,0,7,3,3,CGRectMake(0,0,1179,2556),1,nil);
    CHECK(current.status.bounds_width==393 && current.status.bounds_height==852);
    CHECK(current.status.scale==3 && current.status.revision==8);
    finishGeometry(current,0,8,3,3,CGRectMake(0,0,1179,2556),1,nil);
    CHECK(current.status.revision==8);
    CHECK(eiscue_automation_touch(19,1,8,1179,2556,0,0,0,0,0)==0);
    receipt(YES,nil); CHECK(current.status.phase==EISCUE_AUTOMATION_READY);
    for (NSInteger orientation=3;orientation<=4;orientation++) {
        resetOwner();
        finishGeometry(current,0,7,3,3,CGRectMake(0,0,1179,2556),orientation,nil);
        CHECK(eiscue_automation_touch(19,1,8,2556,1179,16384,32768,16384,32768,0)==0);
        double x=16384.0/65535*2555/3, y=32768.0/65535*1178/3;
        CHECK(fabs(capturedTouchPoint.x-(orientation==3?393-y:y))<0.001);
        CHECK(fabs(capturedTouchPoint.y-(orientation==3?x:852-x))<0.001);
        CHECK(capturedOrientation==1);
        receipt(YES,nil);
    }
    eiscue_automation_abort(19);
    alarm(0);
    printf("PASS: %lu owned loader/home/text/touch/screenshot checks (dependencies, UTF-8, geometry, receipts, unknown delivery, abort)\n", (unsigned long)checks);
} return 0; }
