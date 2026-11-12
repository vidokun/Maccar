#ifndef CGVirtualDisplayBridge_h
#define CGVirtualDisplayBridge_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MaccarVirtualDisplay : NSObject

@property (nonatomic, readonly) uint32_t displayID;
@property (nonatomic, readonly) BOOL isValid;

+ (BOOL)isSupported;
+ (nullable NSString *)lastError;

+ (nullable MaccarVirtualDisplay *)createWithWidth:(unsigned int)width
                                            height:(unsigned int)height
                                      backingWidth:(unsigned int)backingWidth
                                     backingHeight:(unsigned int)backingHeight
                                       refreshRate:(double)refreshRate
                                             hiDPI:(BOOL)hiDPI;

- (BOOL)applyWidth:(unsigned int)width
            height:(unsigned int)height
      backingWidth:(unsigned int)backingWidth
     backingHeight:(unsigned int)backingHeight
       refreshRate:(double)refreshRate
             hiDPI:(BOOL)hiDPI;

- (void)destroy;

@end

NS_ASSUME_NONNULL_END

#endif /* CGVirtualDisplayBridge_h */
