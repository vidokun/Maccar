#ifndef SidecarCoreBridge_h
#define SidecarCoreBridge_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL SidecarCoreIsAvailable(void);

NSArray<NSString *> *SidecarCoreGetReachableDeviceNames(NSError * _Nullable * _Nullable outError);
NSArray<NSString *> *SidecarCoreGetConnectedDeviceNames(void);
BOOL SidecarCoreIsDeviceConnected(NSString *deviceName);

/// One entry per device Sidecar knows about, keyed by "identifier", "name" and "model".
///
/// Sidecar exposes a stable `identifier` (an NSUUID) alongside a user-visible `name`. Names are
/// neither unique nor stable — they are editable on the iPad — so anything that must identify a
/// device across sessions keys on `identifier`. `identifier` was verified stable across a
/// physical unplug/replug on 2026-11-16 (PRD U4). `name` is retained for display only.
typedef NSDictionary<NSString *, id> *SidecarDeviceInfoDictionary;

/// Every device Sidecar has **paired** with.
///
/// Not a presence list: a paired device stays here while its cable is out. Use
/// `SidecarCoreIsIPadAttached` for physical presence.
NSArray<SidecarDeviceInfoDictionary> *SidecarCoreGetReachableDevices(NSError * _Nullable * _Nullable outError);

/// The devices Sidecar currently reports as connected, in the same shape.
NSArray<SidecarDeviceInfoDictionary> *SidecarCoreGetConnectedDevices(void);

/// Whether an iPad is attached over USB right now, independent of what Sidecar has paired.
BOOL SidecarCoreIsIPadAttached(void);

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
