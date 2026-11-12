#import "CGVirtualDisplayBridge.h"

static NSString *sLastError = nil;

// Forward declarations of private CoreGraphics classes
@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) unsigned int maxPixelsWide;
@property (nonatomic, assign) unsigned int maxPixelsHigh;
@property (nonatomic, assign) CGSize sizeInMillimeters;
@property (nonatomic, assign) unsigned int vendorID;
@property (nonatomic, assign) unsigned int productID;
@property (nonatomic, assign) unsigned int serialNum;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) void (^terminationHandler)(id display, unsigned int reason);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, copy) NSArray *modes;
@property (nonatomic, assign) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property (nonatomic, readonly) uint32_t displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

@interface MaccarVirtualDisplay () {
    id _display;
    uint32_t _displayID;
}
@end

@implementation MaccarVirtualDisplay

+ (BOOL)isSupported {
    return (NSClassFromString(@"CGVirtualDisplay") != nil &&
            NSClassFromString(@"CGVirtualDisplayDescriptor") != nil &&
            NSClassFromString(@"CGVirtualDisplayMode") != nil &&
            NSClassFromString(@"CGVirtualDisplaySettings") != nil);
}

+ (nullable NSString *)lastError {
    return sLastError;
}

- (uint32_t)displayID {
    return _displayID;
}

- (BOOL)isValid {
    return _display != nil;
}

static void AppendUniqueDisplayMode(NSMutableArray *modes,
                                    NSMutableSet<NSString *> *seenKeys,
                                    Class modeClass,
                                    unsigned int width,
                                    unsigned int height,
                                    double refreshRate) {
    if (width == 0 || height == 0 || refreshRate <= 0.0) {
        return;
    }
    NSString *key = [NSString stringWithFormat:@"%ux%u@%.1f", width, height, refreshRate];
    if ([seenKeys containsObject:key]) {
        return;
    }
    id mode = [[(CGVirtualDisplayMode *)[modeClass alloc] initWithWidth:width height:height refreshRate:refreshRate] self];
    if (mode != nil) {
        [seenKeys addObject:key];
        [modes addObject:mode];
    }
}

static NSArray *BuildDeduplicatedDisplayModes(Class modeClass,
                                            unsigned int primaryWidth,
                                            unsigned int primaryHeight,
                                            unsigned int backingWidth,
                                            unsigned int backingHeight,
                                            double refreshRate) {
    NSMutableArray *modes = [NSMutableArray array];
    NSMutableSet<NSString *> *seenKeys = [NSMutableSet set];

    // Primary requested backing and logical dimensions first
    AppendUniqueDisplayMode(modes, seenKeys, modeClass, backingWidth, backingHeight, refreshRate);
    AppendUniqueDisplayMode(modes, seenKeys, modeClass, primaryWidth, primaryHeight, refreshRate);

    static const unsigned int presetModes[][2] = {
        // iPad Mini 6/7 (ratio ~1.52:1)
        {2880, 1892}, {1440, 946},
        {3200, 2100}, {1600, 1050},
        {2560, 1680}, {1280, 840},
        {2266, 1488},
        // iPad Air / 10th Gen (ratio ~1.44:1)
        {2880, 2000}, {1440, 1000},
        {3280, 2280}, {2360, 1640},
        // iPad 9.7" / Mini 1-5 (ratio 4:3)
        {2732, 2048}, {1366, 1024},
        {2880, 2160}, {2048, 1536},
        // iPad Pro 11" (ratio ~1.43:1)
        {2880, 2012}, {1440, 1006},
        {2388, 1668},
        // iPad Pro 12.9"/13" (ratio 4:3)
        {3200, 2400}, {1600, 1200},
        {2732, 2048},
        // Standard 16:9
        {3840, 2160}, {1920, 1080}, {2560, 1440}
    };

    const size_t count = sizeof(presetModes) / sizeof(presetModes[0]);
    for (size_t i = 0; i < count; i++) {
        AppendUniqueDisplayMode(modes, seenKeys, modeClass, presetModes[i][0], presetModes[i][1], 60.0);
    }

    return [modes copy];
}

+ (nullable MaccarVirtualDisplay *)createWithWidth:(unsigned int)width
                                            height:(unsigned int)height
                                      backingWidth:(unsigned int)backingWidth
                                     backingHeight:(unsigned int)backingHeight
                                       refreshRate:(double)refreshRate
                                             hiDPI:(BOOL)hiDPI {
    sLastError = nil;
    fprintf(stderr, "[Maccar] Creating virtual display logical %ux%u (backing %ux%u) @ %.0fHz (hiDPI: %d)...\n",
            width, height, backingWidth, backingHeight, refreshRate, hiDPI);

    Class descClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");

    if (!descClass || !displayClass || !modeClass || !settingsClass) {
        sLastError = @"CGVirtualDisplay private classes not available on this macOS version";
        fprintf(stderr, "[Maccar] Error: Private classes unavailable.\n");
        return nil;
    }

    @try {
        CGVirtualDisplayDescriptor *descriptor = [[descClass alloc] init];
        descriptor.name = @"Maccar Display";
        // Support up to 6K resolution dynamically so 2x HiDPI mode changes never exceed bounds
        descriptor.maxPixelsWide = 6016;
        descriptor.maxPixelsHigh = 3384;
        descriptor.sizeInMillimeters = CGSizeMake(508.0, 285.0);
        descriptor.vendorID = 0x05AC;
        descriptor.productID = 0x1000;
        descriptor.serialNum = 0x0001;

        // Dedicated high-priority interactive queue for zero cursor lag & rock-solid 60 FPS
        dispatch_queue_attr_t qosAttr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        dispatch_queue_t queue = dispatch_queue_create("com.maccar.virtualdisplay", qosAttr);
        descriptor.queue = queue;

        descriptor.terminationHandler = ^(id display, unsigned int reason) {
            (void)display;
            fprintf(stderr, "[MaccarVirtualDisplay] Virtual display terminated (reason: %u)\n", reason);
        };

        fprintf(stderr, "[MaccarVirtualDisplay] Initializing CGVirtualDisplay with descriptor (max: 6016x3384, dedicated queue)...\n");
        CGVirtualDisplay *rawDisplay = [(CGVirtualDisplay *)[displayClass alloc] initWithDescriptor:descriptor];
        if (!rawDisplay) {
            sLastError = @"CGVirtualDisplay initWithDescriptor returned nil";
            fprintf(stderr, "[MaccarVirtualDisplay] Error: rawDisplay is nil.\n");
            return nil;
        }

        fprintf(stderr, "[MaccarVirtualDisplay] Applying initial mode and settings...\n");
        NSArray *modes = BuildDeduplicatedDisplayModes(modeClass, width, height, backingWidth, backingHeight, refreshRate);

        CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
        settings.modes = modes;
        settings.hiDPI = hiDPI ? 1 : 0;
        [rawDisplay applySettings:settings];

        uint32_t dispID = rawDisplay.displayID;
        fprintf(stderr, "[MaccarVirtualDisplay] Virtual display created successfully! DisplayID: %u (0x%x)\n", dispID, dispID);

        MaccarVirtualDisplay *instance = [[MaccarVirtualDisplay alloc] init];
        instance->_display = rawDisplay;
        instance->_displayID = dispID;
        return instance;
    } @catch (NSException *exception) {
        sLastError = exception.reason ?: @"Unknown ObjC exception in createWithWidth";
        fprintf(stderr, "[Maccar] Exception: %s\n", [sLastError UTF8String]);
        return nil;
    }
}

- (BOOL)applyWidth:(unsigned int)width
            height:(unsigned int)height
      backingWidth:(unsigned int)backingWidth
     backingHeight:(unsigned int)backingHeight
       refreshRate:(double)refreshRate
             hiDPI:(BOOL)hiDPI {
    if (!_display) {
        return NO;
    }

    @try {
        Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
        Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
        if (!modeClass || !settingsClass) return NO;

        NSArray *modes = BuildDeduplicatedDisplayModes(modeClass, width, height, backingWidth, backingHeight, refreshRate);

        CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
        settings.modes = modes;
        settings.hiDPI = hiDPI ? 1 : 0;

        CGVirtualDisplay *disp = (CGVirtualDisplay *)_display;
        return [disp applySettings:settings];
    } @catch (NSException *exception) {
        (void)exception;
        return NO;
    }
}

- (void)destroy {
    _display = nil;
    _displayID = 0;
}

- (void)dealloc {
    [self destroy];
}

@end
