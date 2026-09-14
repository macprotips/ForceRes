// VirtualDisplayBridge.h
// ForceRes
//
// Runtime-resolved wrapper around the private CoreGraphics classes
// CGVirtualDisplayDescriptor / CGVirtualDisplaySettings / CGVirtualDisplayMode /
// CGVirtualDisplay. Nothing in this target links a private symbol: every class comes from
// NSClassFromString and every selector is sent through objc_msgSend or key-value coding, so a
// macOS release that drops the classes degrades to +isSupportedWithMissingSymbols: == NO
// instead of a dyld failure at launch.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain for failures reported by `FRVirtualDisplayBridge`.
FOUNDATION_EXPORT NSErrorDomain const FRVirtualDisplayBridgeErrorDomain;

typedef NS_ERROR_ENUM(FRVirtualDisplayBridgeErrorDomain, FRVirtualDisplayBridgeError) {
    /// One or more private classes or selectors did not resolve; `userInfo[@"missingSymbols"]` lists them.
    FRVirtualDisplayBridgeErrorUnsupported = 1,
    /// `-[CGVirtualDisplay initWithDescriptor:]` returned nil.
    FRVirtualDisplayBridgeErrorCreateFailed = 2,
    /// `-[CGVirtualDisplay applySettings:]` returned NO.
    FRVirtualDisplayBridgeErrorApplySettingsFailed = 3,
    /// The created display reported `displayID == 0`.
    FRVirtualDisplayBridgeErrorNoDisplayID = 4,
};

/// Owns one virtual display for the lifetime of the object. Releasing the object (or calling
/// `-terminate`) drops the underlying `CGVirtualDisplay`, which removes the display from the
/// system asynchronously (about two seconds).
///
/// The `terminationHandler` of the descriptor is deliberately never set: blocks stored there have
/// been observed to crash at process shutdown.
///
/// Thread-safe: all state is set once during init; `-terminate` is synchronized and the readable
/// properties are atomic, so the class is exposed to Swift as `Sendable`.
NS_SWIFT_SENDABLE
@interface FRVirtualDisplayBridge : NSObject

/// Checks that every private class and selector this bridge needs resolves at runtime.
/// @param missing On return, the symbols that did not resolve (empty when supported). May be NULL.
/// @return YES when a virtual display can be created on this macOS.
+ (BOOL)isSupportedWithMissingSymbols:(NSArray<NSString *> * _Nullable * _Nullable)missing;

/// Creates and publishes a virtual display whose primary mode is `pixelWidth` x `pixelHeight`
/// at `refreshRate` Hz, plus one extra mode per entry of `additionalModeSizes` (NSValue-wrapped
/// CGSize, same refresh rate). When `hiDPI` is YES macOS also advertises 2x "looks like" modes
/// for the sizes whose doubled backing fits within the primary size.
/// Returns nil and fills `error` if the private API is unavailable or refused the request.
- (nullable instancetype)initWithName:(NSString *)name
                             vendorID:(uint32_t)vendorID
                            productID:(uint32_t)productID
                         serialNumber:(uint32_t)serialNumber
                           pixelWidth:(uint32_t)pixelWidth
                          pixelHeight:(uint32_t)pixelHeight
                  additionalModeSizes:(nullable NSArray<NSValue *> *)additionalModeSizes
                                hiDPI:(BOOL)hiDPI
                          refreshRate:(double)refreshRate
                    sizeInMillimeters:(CGSize)sizeInMillimeters
                                error:(NSError * _Nullable * _Nullable)error NS_DESIGNATED_INITIALIZER;

/// Convenience: a single mode of `pixelWidth` x `pixelHeight`.
- (nullable instancetype)initWithName:(NSString *)name
                             vendorID:(uint32_t)vendorID
                            productID:(uint32_t)productID
                         serialNumber:(uint32_t)serialNumber
                           pixelWidth:(uint32_t)pixelWidth
                          pixelHeight:(uint32_t)pixelHeight
                                hiDPI:(BOOL)hiDPI
                          refreshRate:(double)refreshRate
                    sizeInMillimeters:(CGSize)sizeInMillimeters
                                error:(NSError * _Nullable * _Nullable)error;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// The `CGDirectDisplayID` CoreGraphics assigned. Zero after `-terminate`.
@property (readonly, atomic) CGDirectDisplayID displayID;

/// The name passed at creation.
@property (readonly, atomic, copy) NSString *name;

/// Number of `CGVirtualDisplayMode` objects the display reports after `applySettings:`.
@property (readonly, atomic) NSUInteger reportedModeCount;

/// Releases the `CGVirtualDisplay`; the display disappears shortly afterwards. Idempotent.
- (void)terminate;

@end

NS_ASSUME_NONNULL_END
