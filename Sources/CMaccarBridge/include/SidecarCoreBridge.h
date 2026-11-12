#ifndef SidecarCoreBridge_h
#define SidecarCoreBridge_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL SidecarCoreIsAvailable(void);

NSArray<NSString *> *SidecarCoreGetReachableDeviceNames(NSError * _Nullable * _Nullable outError);
NSArray<NSString *> *SidecarCoreGetConnectedDeviceNames(void);
BOOL SidecarCoreIsDeviceConnected(NSString *deviceName);

BOOL SidecarCoreConnectDevice(
    NSString *deviceName,
    BOOL wiredOnly,
    NSError * _Nullable * _Nullable outError
);

BOOL SidecarCoreDisconnectDevice(
    NSString *deviceName,
    NSError * _Nullable * _Nullable outError
);

typedef void (^ NS_SWIFT_SENDABLE SidecarCoreNotificationHandler)(NSString *notificationName);

/// Registers NSNotificationCenter observers for SidecarDevicesChangedNotification
/// and SidecarDisplayManagerConnectedDevicesChangedNotification.
/// Returns a non-zero observer token on success, or 0 if SidecarCore is unavailable.
uint64_t SidecarCoreStartObservingNotifications(SidecarCoreNotificationHandler handler);

/// Unregisters all observers associated with observerToken. Safe to pass 0 or stale tokens.
void SidecarCoreStopObservingNotifications(uint64_t observerToken);

/// Returns YES when error belongs to SidecarErrorDomain and indicates the device is not connected.
BOOL SidecarCoreIsNotConnectedError(NSError * _Nullable error);

NS_ASSUME_NONNULL_END

#endif /* SidecarCoreBridge_h */
