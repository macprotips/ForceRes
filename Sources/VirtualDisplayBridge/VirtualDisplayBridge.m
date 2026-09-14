#import "VirtualDisplayBridge.h"
#import <objc/message.h>
#import <objc/runtime.h>

NSErrorDomain const FRVirtualDisplayBridgeErrorDomain = @"ForceRes.VirtualDisplayBridge";

// Private class names, resolved with NSClassFromString only.
static NSString *const kDescriptorClass = @"CGVirtualDisplayDescriptor";
static NSString *const kSettingsClass   = @"CGVirtualDisplaySettings";
static NSString *const kModeClass       = @"CGVirtualDisplayMode";
static NSString *const kDisplayClass    = @"CGVirtualDisplay";

/// Instance selectors each class must respond to (verified against the runtime on macOS 27.0).
static NSDictionary<NSString *, NSArray<NSString *> *> *FRRequiredSelectors(void) {
    return @{
        kDescriptorClass: @[ @"setName:", @"setVendorID:", @"setProductID:", @"setSerialNum:",
                             @"setSizeInMillimeters:", @"setMaxPixelsWide:", @"setMaxPixelsHigh:",
                             @"setDispatchQueue:" ],
        kSettingsClass:   @[ @"setHiDPI:", @"setModes:" ],
        kModeClass:       @[ @"initWithWidth:height:refreshRate:" ],
        kDisplayClass:    @[ @"initWithDescriptor:", @"applySettings:", @"displayID", @"modes" ],
    };
}

/// `init…` family calls made through objc_msgSend casts must tell ARC that the receiver is
/// consumed and the result is returned retained; without the attributes ARC over-releases the
/// receiver.
typedef id (*FRInitWithObjectIMP)(id __attribute__((ns_consumed)) receiver, SEL selector, id argument)
    __attribute__((ns_returns_retained));
typedef id (*FRInitModeIMP)(id __attribute__((ns_consumed)) receiver, SEL selector,
                            uint32_t width, uint32_t height, double refreshRate)
    __attribute__((ns_returns_retained));

static NSError *FRError(FRVirtualDisplayBridgeError code, NSString *description, NSDictionary * _Nullable extra) {
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithDictionary:extra ?: @{}];
    info[NSLocalizedDescriptionKey] = description;
    return [NSError errorWithDomain:FRVirtualDisplayBridgeErrorDomain code:code userInfo:info];
}

@implementation FRVirtualDisplayBridge {
    id _display;          // CGVirtualDisplay, held only as `id`
    dispatch_queue_t _queue;
}

+ (BOOL)isSupportedWithMissingSymbols:(NSArray<NSString *> **)missing {
    NSMutableArray<NSString *> *missingSymbols = [NSMutableArray array];
    [FRRequiredSelectors() enumerateKeysAndObjectsUsingBlock:^(NSString *className, NSArray<NSString *> *selectors, BOOL *stop) {
        Class cls = NSClassFromString(className);
        if (cls == Nil) {
            [missingSymbols addObject:className];
            return;
        }
        for (NSString *selectorName in selectors) {
            if (![cls instancesRespondToSelector:NSSelectorFromString(selectorName)]) {
                [missingSymbols addObject:[NSString stringWithFormat:@"-[%@ %@]", className, selectorName]];
            }
        }
    }];
    [missingSymbols sortUsingSelector:@selector(compare:)];
    if (missing) { *missing = [missingSymbols copy]; }
    return missingSymbols.count == 0;
}

- (instancetype)initWithName:(NSString *)name
                    vendorID:(uint32_t)vendorID
                   productID:(uint32_t)productID
                serialNumber:(uint32_t)serialNumber
                  pixelWidth:(uint32_t)pixelWidth
                 pixelHeight:(uint32_t)pixelHeight
                       hiDPI:(BOOL)hiDPI
                 refreshRate:(double)refreshRate
           sizeInMillimeters:(CGSize)sizeInMillimeters
                       error:(NSError **)error {
    return [self initWithName:name vendorID:vendorID productID:productID serialNumber:serialNumber
                   pixelWidth:pixelWidth pixelHeight:pixelHeight additionalModeSizes:nil hiDPI:hiDPI
                  refreshRate:refreshRate sizeInMillimeters:sizeInMillimeters error:error];
}

- (instancetype)initWithName:(NSString *)name
                    vendorID:(uint32_t)vendorID
                   productID:(uint32_t)productID
                serialNumber:(uint32_t)serialNumber
                  pixelWidth:(uint32_t)pixelWidth
                 pixelHeight:(uint32_t)pixelHeight
         additionalModeSizes:(NSArray<NSValue *> *)additionalModeSizes
                       hiDPI:(BOOL)hiDPI
                 refreshRate:(double)refreshRate
           sizeInMillimeters:(CGSize)sizeInMillimeters
                       error:(NSError **)error {
    self = [super init];
    if (!self) { return nil; }

    NSArray<NSString *> *missing = nil;
    if (![FRVirtualDisplayBridge isSupportedWithMissingSymbols:&missing]) {
        if (error) {
            *error = FRError(FRVirtualDisplayBridgeErrorUnsupported,
                             [NSString stringWithFormat:@"Private virtual display API unavailable: %@",
                              [missing componentsJoinedByString:@", "]],
                             @{ @"missingSymbols": missing ?: @[] });
        }
        return nil;
    }

    _name = [name copy];
    _queue = dispatch_queue_create("ForceRes.VirtualDisplay", DISPATCH_QUEUE_SERIAL);

    // Descriptor. Every property is set through KVC (NSNumber / NSValue boxing for scalars and
    // structs), so no call depends on a hard-coded calling convention.
    id descriptor = [[NSClassFromString(kDescriptorClass) alloc] init];
    [descriptor setValue:_name forKey:@"name"];
    [descriptor setValue:@(vendorID) forKey:@"vendorID"];
    [descriptor setValue:@(productID) forKey:@"productID"];
    [descriptor setValue:@(serialNumber) forKey:@"serialNum"];
    [descriptor setValue:@(pixelWidth) forKey:@"maxPixelsWide"];
    [descriptor setValue:@(pixelHeight) forKey:@"maxPixelsHigh"];
    [descriptor setValue:[NSValue valueWithSize:NSMakeSize(sizeInMillimeters.width, sizeInMillimeters.height)]
                  forKey:@"sizeInMillimeters"];
    [descriptor setValue:_queue forKey:@"dispatchQueue"];
    // terminationHandler intentionally left nil (crashes at shutdown, see docs/RESEARCH.md §5).

    // CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    id display = ((FRInitWithObjectIMP)objc_msgSend)([NSClassFromString(kDisplayClass) alloc],
                                                     NSSelectorFromString(@"initWithDescriptor:"), descriptor);
    if (display == nil) {
        if (error) {
            *error = FRError(FRVirtualDisplayBridgeErrorCreateFailed, @"CGVirtualDisplay initWithDescriptor: returned nil", nil);
        }
        return nil;
    }

    // CGVirtualDisplayMode *mode = [[CGVirtualDisplayMode alloc] initWithWidth:height:refreshRate:];
    id mode = ((FRInitModeIMP)objc_msgSend)([NSClassFromString(kModeClass) alloc],
                                           NSSelectorFromString(@"initWithWidth:height:refreshRate:"),
                                           pixelWidth, pixelHeight, refreshRate);

    NSMutableArray *modes = [NSMutableArray array];
    if (mode) { [modes addObject:mode]; }
    for (NSValue *value in additionalModeSizes) {
        CGSize size = value.sizeValue;
        id extra = ((FRInitModeIMP)objc_msgSend)([NSClassFromString(kModeClass) alloc],
                                                NSSelectorFromString(@"initWithWidth:height:refreshRate:"),
                                                (uint32_t)size.width, (uint32_t)size.height, refreshRate);
        if (extra) { [modes addObject:extra]; }
    }

    id settings = [[NSClassFromString(kSettingsClass) alloc] init];
    [settings setValue:@(hiDPI ? 1u : 0u) forKey:@"hiDPI"];
    [settings setValue:[modes copy] forKey:@"modes"];

    BOOL applied = ((BOOL (*)(id, SEL, id))objc_msgSend)(display, NSSelectorFromString(@"applySettings:"), settings);
    if (!applied) {
        if (error) {
            *error = FRError(FRVirtualDisplayBridgeErrorApplySettingsFailed, @"CGVirtualDisplay applySettings: returned NO", nil);
        }
        return nil; // `display` is released by ARC; the display never publishes.
    }

    NSNumber *displayID = [display valueForKey:@"displayID"];
    _displayID = (CGDirectDisplayID)displayID.unsignedIntValue;
    if (_displayID == 0) {
        if (error) {
            *error = FRError(FRVirtualDisplayBridgeErrorNoDisplayID, @"CGVirtualDisplay reported displayID 0", nil);
        }
        return nil;
    }
    NSArray *reportedModes = [display valueForKey:@"modes"];
    _reportedModeCount = [reportedModes isKindOfClass:[NSArray class]] ? reportedModes.count : 0;
    _display = display;
    return self;
}

- (void)terminate {
    @synchronized (self) {
        _display = nil;
        _displayID = 0;
    }
}

- (void)dealloc {
    _display = nil;
}

@end
