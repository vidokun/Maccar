#import "SidecarCoreBridge.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <os/lock.h>

static NSString * const kSidecarBridgeDomain = @"com.maccar.sidecar";
static const int64_t kSidecarConnectTimeoutSeconds = 10;
static const int64_t kSidecarDisconnectTimeoutSeconds = 5;
static const NSInteger kSidecarConnectTimeoutCode = -300;
static const NSInteger kSidecarDisconnectTimeoutCode = -301;

static os_unfair_lock sBridgeLock = OS_UNFAIR_LOCK_INIT;
static void *sSidecarHandle = NULL;

static os_unfair_lock sObserverLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSNumber *, NSArray<id<NSObject>> *> * _Nullable sObserverRegistry = nil;
static uint64_t sNextObserverToken = 1;

static NSError *MakeSidecarError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:kSidecarBridgeDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface MaccarSidecarWaitToken : NSObject {
    os_unfair_lock _lock;
    BOOL _timedOut;
    BOOL _completed;
    NSError * _Nullable _capturedError;
}
- (instancetype)init;
- (BOOL)completeWithError:(NSError * _Nullable)error;
- (BOOL)finishWaitWithGroupCompleted:(BOOL)groupCompleted
                         timeoutCode:(NSInteger)timeoutCode
                      timeoutMessage:(NSString *)timeoutMessage
                    needsLateCleanup:(BOOL * _Nullable)outNeedsLateCleanup
                               error:(NSError * _Nullable * _Nullable)outError;
@end

@implementation MaccarSidecarWaitToken

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _timedOut = NO;
        _completed = NO;
        _capturedError = nil;
    }
    return self;
}

- (BOOL)completeWithError:(NSError * _Nullable)error {
    os_unfair_lock_lock(&_lock);
    _completed = YES;
    _capturedError = error;
    BOOL needsCleanup = (_timedOut && error == nil);
    os_unfair_lock_unlock(&_lock);
    return needsCleanup;
}

- (BOOL)finishWaitWithGroupCompleted:(BOOL)groupCompleted
                         timeoutCode:(NSInteger)timeoutCode
                      timeoutMessage:(NSString *)timeoutMessage
                    needsLateCleanup:(BOOL * _Nullable)outNeedsLateCleanup
                               error:(NSError * _Nullable * _Nullable)outError {
    if (outNeedsLateCleanup) { *outNeedsLateCleanup = NO; }
    if (outError) { *outError = nil; }
    os_unfair_lock_lock(&_lock);
    if (groupCompleted) {
        NSError *captured = _capturedError;
        os_unfair_lock_unlock(&_lock);
        if (captured && outError) { *outError = captured; }
        return (captured == nil);
    }
    _timedOut = YES;
    BOOL lateCleanup = (_completed && _capturedError == nil);
    os_unfair_lock_unlock(&_lock);
    if (outNeedsLateCleanup) { *outNeedsLateCleanup = lateCleanup; }
    if (outError) { *outError = MakeSidecarError(timeoutCode, timeoutMessage); }
    return NO;
}

@end

static id _Nullable InvokeZeroArgObject(id target, NSString *selectorName) {
    if (!target || !selectorName) { return nil; }
    SEL sel = NSSelectorFromString(selectorName);
    if (!sel || ![target respondsToSelector:sel]) { return nil; }
    IMP imp = [target methodForSelector:sel];
    if (!imp) { return nil; }
    id (*fn)(id, SEL) = (id (*)(id, SEL))imp;
    return fn(target, sel);
}

static NSArray<NSString *> *ExtractDeviceNames(id rawDevices) {
    if (![rawDevices isKindOfClass:[NSArray class]]) { return @[]; }
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id dev in (NSArray *)rawDevices) {
        id rawName = InvokeZeroArgObject(dev, @"name");
        if ([rawName isKindOfClass:[NSString class]]) {
            [names addObject:(NSString *)rawName];
        }
    }
    return [names copy];
}

static BOOL EnsureSidecarCoreLoadedUnlocked(NSError * _Nullable * _Nullable outError) {
    if (sSidecarHandle) { return YES; }
    sSidecarHandle = dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_NOW);
    if (!sSidecarHandle) {
        if (outError) { *outError = MakeSidecarError(-10, @"Failed to dlopen SidecarCore.framework"); }
        return NO;
    }
    return YES;
}

static id _Nullable GetSidecarDisplayManagerUnlocked(NSError * _Nullable * _Nullable outError) {
    if (!EnsureSidecarCoreLoadedUnlocked(outError)) { return nil; }
    Class mgrClass = NSClassFromString(@"SidecarDisplayManager");
    if (!mgrClass) {
        if (outError) { *outError = MakeSidecarError(-11, @"SidecarDisplayManager class not found"); }
        return nil;
    }
    return InvokeZeroArgObject(mgrClass, @"sharedManager");
}

static id _Nullable GetSidecarDisplayManager(NSError * _Nullable * _Nullable outError) {
    os_unfair_lock_lock(&sBridgeLock);
    id manager = GetSidecarDisplayManagerUnlocked(outError);
    os_unfair_lock_unlock(&sBridgeLock);
    return manager;
}

static NSArray *CopySelectorArrayUnlocked(id manager, NSString *selectorName) {
    id raw = InvokeZeroArgObject(manager, selectorName);
    return [raw isKindOfClass:[NSArray class]] ? [(NSArray *)raw copy] : @[];
}

static NSString *ResolveSidecarCFStringSymbol(const char *symbolName, NSString *fallback) {
    if (!symbolName) { return fallback; }
    CFStringRef resolved = NULL;
    os_unfair_lock_lock(&sBridgeLock);
    if (EnsureSidecarCoreLoadedUnlocked(NULL) && sSidecarHandle) {
        CFStringRef *symPtr = (CFStringRef *)dlsym(sSidecarHandle, symbolName);
        if (symPtr && *symPtr) { resolved = *symPtr; }
    }
    os_unfair_lock_unlock(&sBridgeLock);
    return resolved ? (__bridge NSString *)resolved : fallback;
}

BOOL SidecarCoreIsAvailable(void) {
    os_unfair_lock_lock(&sBridgeLock);
    BOOL loaded = EnsureSidecarCoreLoadedUnlocked(NULL);
    Class mgrClass = loaded ? NSClassFromString(@"SidecarDisplayManager") : Nil;
    os_unfair_lock_unlock(&sBridgeLock);
    return loaded && (mgrClass != Nil);
}

NSArray<NSString *> *SidecarCoreGetReachableDeviceNames(NSError * _Nullable * _Nullable outError) {
    if (outError) { *outError = nil; }
    os_unfair_lock_lock(&sBridgeLock);
    id manager = GetSidecarDisplayManagerUnlocked(outError);
    NSArray *devices = manager ? CopySelectorArrayUnlocked(manager, @"devices") : @[];
    os_unfair_lock_unlock(&sBridgeLock);
    return ExtractDeviceNames(devices);
}

NSArray<NSString *> *SidecarCoreGetConnectedDeviceNames(void) {
    os_unfair_lock_lock(&sBridgeLock);
    id manager = GetSidecarDisplayManagerUnlocked(NULL);
    NSArray *connected = manager ? CopySelectorArrayUnlocked(manager, @"connectedDevices") : @[];
    os_unfair_lock_unlock(&sBridgeLock);
    return ExtractDeviceNames(connected);
}

BOOL SidecarCoreIsDeviceConnected(NSString *deviceName) {
    if (!deviceName || deviceName.length == 0) { return NO; }
    NSString *target = deviceName.lowercaseString;
    for (NSString *name in SidecarCoreGetConnectedDeviceNames()) {
        if ([name.lowercaseString isEqualToString:target]) { return YES; }
    }
    return NO;
}

BOOL SidecarCoreIsNotConnectedError(NSError * _Nullable error) {
    if (!error) { return NO; }
    NSString *sidecarDomain = ResolveSidecarCFStringSymbol("SidecarErrorDomain", @"SidecarErrorDomain");
    if (![error.domain isEqualToString:sidecarDomain]) { return NO; }
    NSString *description = error.localizedDescription;
    if (!description || description.length == 0) { return NO; }
    return [description rangeOfString:@"not connected" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static id _Nullable FindDeviceForSelector(id manager, NSString *selectorName, NSString *targetName) {
    if (!targetName || targetName.length == 0) { return nil; }
    os_unfair_lock_lock(&sBridgeLock);
    NSArray *devices = CopySelectorArrayUnlocked(manager, selectorName);
    os_unfair_lock_unlock(&sBridgeLock);
    NSString *lowercasedTarget = targetName.lowercaseString;
    for (id dev in devices) {
        id nameObj = InvokeZeroArgObject(dev, @"name");
        if ([nameObj isKindOfClass:[NSString class]] &&
            [[(NSString *)nameObj lowercaseString] isEqualToString:lowercasedTarget]) {
            return dev;
        }
    }
    return nil;
}

static id _Nullable FindReachableDeviceByName(id manager, NSString *targetName) {
    return FindDeviceForSelector(manager, @"devices", targetName);
}

static id _Nullable FindConnectedDeviceByName(id manager, NSString *targetName) {
    return FindDeviceForSelector(manager, @"connectedDevices", targetName);
}

static void DispatchSidecarConnect(
    id manager,
    id targetDevice,
    BOOL wiredOnly,
    void (^completionBlock)(NSError * _Nullable)
) {
    if (wiredOnly) {
        Class configClass = NSClassFromString(@"SidecarDisplayConfig");
        id config = [[configClass alloc] init];
        SEL setTransportSel = NSSelectorFromString(@"setTransport:");
        if (config && [config respondsToSelector:setTransportSel]) {
            void (*setTransportFunc)(id, SEL, int64_t) = (void *)[config methodForSelector:setTransportSel];
            setTransportFunc(config, setTransportSel, 2); // 2 = wired transport
        }
        SEL connectSel = NSSelectorFromString(@"connectToDevice:withConfig:completion:");
        if ([manager respondsToSelector:connectSel]) {
            void (*connectFunc)(id, SEL, id, id, id) = (void *)[manager methodForSelector:connectSel];
            connectFunc(manager, connectSel, targetDevice, config, completionBlock);
        } else {
            completionBlock(MakeSidecarError(-12, @"connectToDevice:withConfig:completion: selector not found"));
        }
        return;
    }

    SEL connectSel = NSSelectorFromString(@"connectToDevice:completion:");
    if ([manager respondsToSelector:connectSel]) {
        void (*connectFunc)(id, SEL, id, id) = (void *)[manager methodForSelector:connectSel];
        connectFunc(manager, connectSel, targetDevice, completionBlock);
    } else {
        completionBlock(MakeSidecarError(-12, @"connectToDevice:completion: selector not found"));
    }
}

static void InvokeSidecarDisconnect(
    id manager,
    id targetDevice,
    void (^completionBlock)(NSError * _Nullable)
) {
    SEL discSel = NSSelectorFromString(@"disconnectFromDevice:completion:");
    if ([manager respondsToSelector:discSel]) {
        void (*discFunc)(id, SEL, id, id) = (void *)[manager methodForSelector:discSel];
        discFunc(manager, discSel, targetDevice, completionBlock);
    } else {
        completionBlock(MakeSidecarError(-13, @"disconnectFromDevice:completion: selector not found"));
    }
}

static void DispatchAsyncDisconnectCleanup(id manager, id targetDevice) {
    if (!manager || !targetDevice) { return; }
    dispatch_queue_t utilityQueue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_async(utilityQueue, ^{
        InvokeSidecarDisconnect(manager, targetDevice, ^(NSError * _Nullable __unused error) {});
    });
}

static BOOL WaitForSidecarToken(
    dispatch_group_t group,
    MaccarSidecarWaitToken *token,
    int64_t timeoutSeconds,
    NSInteger timeoutCode,
    NSString *timeoutMessage,
    BOOL * _Nullable outLateCleanup,
    NSError * _Nullable * _Nullable outError
) {
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, timeoutSeconds * NSEC_PER_SEC);
    BOOL groupCompleted = (dispatch_group_wait(group, timeout) == 0);
    return [token finishWaitWithGroupCompleted:groupCompleted
                                   timeoutCode:timeoutCode
                                timeoutMessage:timeoutMessage
                              needsLateCleanup:outLateCleanup
                                         error:outError];
}

BOOL SidecarCoreConnectDevice(NSString *deviceName, BOOL wiredOnly, NSError * _Nullable * _Nullable outError) {
    if (outError) { *outError = nil; }
    id manager = GetSidecarDisplayManager(outError);
    if (!manager) { return NO; }
    id targetDevice = FindReachableDeviceByName(manager, deviceName);
    if (!targetDevice) {
        if (outError) {
            *outError = MakeSidecarError(-200, [NSString stringWithFormat:@"Device '%@' not reachable", deviceName]);
        }
        return NO;
    }
    MaccarSidecarWaitToken *token = [[MaccarSidecarWaitToken alloc] init];
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    DispatchSidecarConnect(manager, targetDevice, wiredOnly, ^(NSError * _Nullable err) {
        BOOL needsCleanup = [token completeWithError:err];
        dispatch_group_leave(group);
        if (needsCleanup) { DispatchAsyncDisconnectCleanup(manager, targetDevice); }
    });
    BOOL lateCleanup = NO;
    BOOL ok = WaitForSidecarToken(
        group, token, kSidecarConnectTimeoutSeconds, kSidecarConnectTimeoutCode,
        @"Sidecar connection timed out after 10s", &lateCleanup, outError
    );
    if (lateCleanup) { DispatchAsyncDisconnectCleanup(manager, targetDevice); }
    return ok;
}

BOOL SidecarCoreDisconnectDevice(NSString *deviceName, NSError * _Nullable * _Nullable outError) {
    if (outError) { *outError = nil; }
    id manager = GetSidecarDisplayManager(outError);
    if (!manager) { return NO; }
    id targetDevice = FindConnectedDeviceByName(manager, deviceName);
    if (!targetDevice) { targetDevice = FindReachableDeviceByName(manager, deviceName); }
    if (!targetDevice) { return YES; }

    MaccarSidecarWaitToken *token = [[MaccarSidecarWaitToken alloc] init];
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    InvokeSidecarDisconnect(manager, targetDevice, ^(NSError * _Nullable err) {
        [token completeWithError:err];
        dispatch_group_leave(group);
    });
    NSError *waitErr = nil;
    BOOL ok = WaitForSidecarToken(
        group, token, kSidecarDisconnectTimeoutSeconds, kSidecarDisconnectTimeoutCode,
        @"Disconnect timed out after 5s", NULL, &waitErr
    );
    if (ok) { return YES; }
    BOOL isTimeout = [waitErr.domain isEqualToString:kSidecarBridgeDomain] &&
        waitErr.code == kSidecarDisconnectTimeoutCode;
    if (!isTimeout && SidecarCoreIsNotConnectedError(waitErr) && !SidecarCoreIsDeviceConnected(deviceName)) {
        return YES;
    }
    if (outError) { *outError = waitErr; }
    return NO;
}

static uint64_t RegisterObserverPair(NSArray<id<NSObject>> *observers) {
    os_unfair_lock_lock(&sObserverLock);
    if (!sObserverRegistry) { sObserverRegistry = [NSMutableDictionary dictionary]; }
    if (sNextObserverToken == 0) { sNextObserverToken = 1; }
    uint64_t token = sNextObserverToken++;
    sObserverRegistry[@(token)] = observers;
    os_unfair_lock_unlock(&sObserverLock);
    return token;
}

static id<NSObject> AddNotificationObserver(
    NSNotificationCenter *center,
    NSString *notificationName,
    SidecarCoreNotificationHandler handler
) {
    return [center addObserverForName:notificationName
                               object:nil
                                queue:nil
                           usingBlock:^(NSNotification *note) {
        handler(note.name ?: notificationName);
    }];
}

uint64_t SidecarCoreStartObservingNotifications(SidecarCoreNotificationHandler handler) {
    if (!handler || !GetSidecarDisplayManager(NULL)) { return 0; }
    NSString *devicesChanged = ResolveSidecarCFStringSymbol(
        "SidecarDevicesChangedNotification", @"SidecarDevicesChangedNotification"
    );
    NSString *connectedChanged = ResolveSidecarCFStringSymbol(
        "SidecarDisplayManagerConnectedDevicesChangedNotification",
        @"SidecarDisplayManagerConnectedDevicesChangedNotification"
    );
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    SidecarCoreNotificationHandler handlerCopy = [handler copy];
    return RegisterObserverPair(@[
        AddNotificationObserver(center, devicesChanged, handlerCopy),
        AddNotificationObserver(center, connectedChanged, handlerCopy)
    ]);
}

void SidecarCoreStopObservingNotifications(uint64_t observerToken) {
    if (observerToken == 0) { return; }
    os_unfair_lock_lock(&sObserverLock);
    NSArray<id<NSObject>> *observers = sObserverRegistry[@(observerToken)];
    if (observers) { [sObserverRegistry removeObjectForKey:@(observerToken)]; }
    os_unfair_lock_unlock(&sObserverLock);
    if (!observers) { return; }
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    for (id<NSObject> obs in observers) { [center removeObserver:obs]; }
}
