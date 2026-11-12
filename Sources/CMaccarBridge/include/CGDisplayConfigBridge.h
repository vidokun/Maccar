#ifndef CGDisplayConfigBridge_h
#define CGDisplayConfigBridge_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface CGDisplayConfigBridge : NSObject

/// Configures mirrorDisplay to mirror masterDisplay.
/// If masterDisplay is 0 (kCGNullDirectDisplay), mirroring is disabled.
+ (BOOL)mirrorDisplay:(CGDirectDisplayID)mirrorDisplay
      toMasterDisplay:(CGDirectDisplayID)masterDisplay
                error:(NSString * _Nullable * _Nullable)outError;

/// Disables mirroring for the specified display.
+ (BOOL)disableMirroringForDisplay:(CGDirectDisplayID)display
                             error:(NSString * _Nullable * _Nullable)outError;

/// Returns the master display ID that this display is mirroring, or 0 if not mirroring.
+ (CGDirectDisplayID)primaryDisplayForMirror:(CGDirectDisplayID)display;

/// Returns all active online display IDs.
+ (NSArray<NSNumber *> *)onlineDisplayIDs;

/// Returns an array of dictionaries describing all display modes for displayID,
/// including width, height, pixelWidth, pixelHeight, refreshRate, and usableForDesktop.
+ (NSArray<NSDictionary<NSString *, NSNumber *> *> *)availableDisplayModesForDisplay:(CGDirectDisplayID)displayID NS_SWIFT_NAME(availableDisplayModes(forDisplay:));

/// Actively switches the active display mode of displayID in WindowServer.
/// Matches logical point width/height, preferring HiDPI 2x usable mode when hiDPI is YES,
/// and falling back only to desktop-usable modes.
+ (BOOL)setDisplayModeForDisplay:(CGDirectDisplayID)displayID
                    logicalWidth:(unsigned int)logicalWidth
                   logicalHeight:(unsigned int)logicalHeight
                           hiDPI:(BOOL)hiDPI
                     refreshRate:(double)refreshRate NS_SWIFT_NAME(setDisplayMode(forDisplay:logicalWidth:logicalHeight:hiDPI:refreshRate:));

@end

NS_ASSUME_NONNULL_END

#endif /* CGDisplayConfigBridge_h */
