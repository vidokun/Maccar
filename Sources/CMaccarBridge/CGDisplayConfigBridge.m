#import "CGDisplayConfigBridge.h"
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>

static BOOL ModeMatchesRequestedRefresh(CGDisplayModeRef mode, double refreshRate) {
    if (refreshRate <= 0.0) {
        return YES;
    }
    double modeRate = CGDisplayModeGetRefreshRate(mode);
    return fabs(modeRate - refreshRate) < 1.0;
}

typedef enum : NSUInteger {
    MaccarModeMatchHiDPI2x = 0,
    MaccarModeMatchExact1x,
    MaccarModeMatchLogicalAny,
    MaccarModeMatchPixelExact
} MaccarModeMatchKind;

static BOOL ModeMatchesGeometry(CGDisplayModeRef mode,
                                unsigned int targetWidth,
                                unsigned int targetHeight,
                                MaccarModeMatchKind kind) {
    size_t w = CGDisplayModeGetWidth(mode);
    size_t h = CGDisplayModeGetHeight(mode);
    size_t pW = CGDisplayModeGetPixelWidth(mode);
    size_t pH = CGDisplayModeGetPixelHeight(mode);

    switch (kind) {
        case MaccarModeMatchHiDPI2x:
            return (w == targetWidth && h == targetHeight && pW >= (size_t)targetWidth * 2 && pH >= (size_t)targetHeight * 2);
        case MaccarModeMatchExact1x:
            return (w == targetWidth && h == targetHeight && pW == targetWidth && pH == targetHeight);
        case MaccarModeMatchLogicalAny:
            return (w == targetWidth && h == targetHeight);
        case MaccarModeMatchPixelExact:
            return (pW == targetWidth && pH == targetHeight);
    }
}

static CGDisplayModeRef FindUsableModePass(CFArrayRef modes,
                                           unsigned int targetWidth,
                                           unsigned int targetHeight,
                                           MaccarModeMatchKind kind,
                                           double refreshRate) {
    CFIndex count = CFArrayGetCount(modes);
    CGDisplayModeRef fallbackMatch = NULL;

    for (CFIndex i = 0; i < count; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (!CGDisplayModeIsUsableForDesktopGUI(mode)) {
            continue;
        }
        if (!ModeMatchesGeometry(mode, targetWidth, targetHeight, kind)) {
            continue;
        }
        if (ModeMatchesRequestedRefresh(mode, refreshRate)) {
            return mode;
        }
        if (!fallbackMatch) {
            fallbackMatch = mode;
        }
    }

    return fallbackMatch;
}

static CGDisplayModeRef FindBestUsableMode(CFArrayRef modes,
                                           unsigned int logicalWidth,
                                           unsigned int logicalHeight,
                                           BOOL hiDPI,
                                           double refreshRate) {
    MaccarModeMatchKind primaryKind = hiDPI ? MaccarModeMatchHiDPI2x : MaccarModeMatchExact1x;
    CGDisplayModeRef match = FindUsableModePass(modes, logicalWidth, logicalHeight, primaryKind, refreshRate);
    if (match) return match;

    match = FindUsableModePass(modes, logicalWidth, logicalHeight, MaccarModeMatchLogicalAny, refreshRate);
    if (match) return match;

    return FindUsableModePass(modes, logicalWidth, logicalHeight, MaccarModeMatchPixelExact, refreshRate);
}

@implementation CGDisplayConfigBridge

+ (BOOL)mirrorDisplay:(CGDirectDisplayID)mirrorDisplay
      toMasterDisplay:(CGDirectDisplayID)masterDisplay
                error:(NSString **)outError {
    if (outError) {
        *outError = nil;
    }

    CGDisplayConfigRef config = NULL;
    CGError err = CGBeginDisplayConfiguration(&config);
    if (err != kCGErrorSuccess) {
        if (outError) {
            *outError = [NSString stringWithFormat:@"CGBeginDisplayConfiguration failed with error %d", err];
        }
        return NO;
    }

    err = CGConfigureDisplayMirrorOfDisplay(config, mirrorDisplay, masterDisplay);
    if (err != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        if (outError) {
            *outError = [NSString stringWithFormat:@"CGConfigureDisplayMirrorOfDisplay failed with error %d", err];
        }
        return NO;
    }

    err = CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
    if (err != kCGErrorSuccess) {
        if (outError) {
            *outError = [NSString stringWithFormat:@"CGCompleteDisplayConfiguration failed with error %d", err];
        }
        return NO;
    }

    return YES;
}

+ (BOOL)disableMirroringForDisplay:(CGDirectDisplayID)display
                             error:(NSString **)outError {
    return [self mirrorDisplay:display toMasterDisplay:kCGNullDirectDisplay error:outError];
}

+ (CGDirectDisplayID)primaryDisplayForMirror:(CGDirectDisplayID)display {
    return CGDisplayMirrorsDisplay(display);
}

+ (NSArray<NSNumber *> *)onlineDisplayIDs {
    uint32_t maxDisplays = 16;
    CGDirectDisplayID displays[16];
    uint32_t displayCount = 0;

    CGError err = CGGetOnlineDisplayList(maxDisplays, displays, &displayCount);
    if (err != kCGErrorSuccess) {
        return @[];
    }

    NSMutableArray<NSNumber *> *list = [NSMutableArray arrayWithCapacity:displayCount];
    for (uint32_t i = 0; i < displayCount; i++) {
        [list addObject:@(displays[i])];
    }
    return [list copy];
}

+ (NSArray<NSDictionary<NSString *, NSNumber *> *> *)availableDisplayModesForDisplay:(CGDirectDisplayID)displayID {
    if (displayID == 0) {
        return @[];
    }

    NSDictionary *options = @{ (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES };
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayID, (__bridge CFDictionaryRef)options);
    if (!modes) {
        return @[];
    }

    CFIndex count = CFArrayGetCount(modes);
    NSMutableArray<NSDictionary<NSString *, NSNumber *> *> *result = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (CFIndex i = 0; i < count; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        NSDictionary<NSString *, NSNumber *> *entry = @{
            @"width": @((NSUInteger)CGDisplayModeGetWidth(mode)),
            @"height": @((NSUInteger)CGDisplayModeGetHeight(mode)),
            @"pixelWidth": @((NSUInteger)CGDisplayModeGetPixelWidth(mode)),
            @"pixelHeight": @((NSUInteger)CGDisplayModeGetPixelHeight(mode)),
            @"refreshRate": @(CGDisplayModeGetRefreshRate(mode)),
            @"usableForDesktop": @(CGDisplayModeIsUsableForDesktopGUI(mode))
        };
        [result addObject:entry];
    }

    CFRelease(modes);
    return [result copy];
}

+ (BOOL)setDisplayModeForDisplay:(CGDirectDisplayID)displayID
                    logicalWidth:(unsigned int)logicalWidth
                   logicalHeight:(unsigned int)logicalHeight
                           hiDPI:(BOOL)hiDPI
                     refreshRate:(double)refreshRate {
    if (displayID == 0) return NO;

    NSDictionary *options = @{ (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES };
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayID, (__bridge CFDictionaryRef)options);
    if (!modes) return NO;

    CGDisplayModeRef bestMode = FindBestUsableMode(modes, logicalWidth, logicalHeight, hiDPI, refreshRate);
    if (!bestMode) {
        CFRelease(modes);
        return NO;
    }

    CGDisplayConfigRef config = NULL;
    CGError err = CGBeginDisplayConfiguration(&config);
    if (err != kCGErrorSuccess) {
        CFRelease(modes);
        return NO;
    }

    err = CGConfigureDisplayWithDisplayMode(config, displayID, bestMode, NULL);
    if (err != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        CFRelease(modes);
        return NO;
    }

    err = CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
    CFRelease(modes);
    return (err == kCGErrorSuccess);
}

@end
