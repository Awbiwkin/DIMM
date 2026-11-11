
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <notify.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <string.h>
#import <stdlib.h>

#import <stdbool.h>

#define DIM_SIM_NOTIFY "com.dim.manager.changed"

typedef struct {
    bool itemIsEnabled[44];
    char timeString[64];
    char shortTimeString[64];
    char dateString[256];
    int gsmSignalStrengthRaw;
    int secondaryGsmSignalStrengthRaw;
    int gsmSignalStrengthBars;
    int secondaryGsmSignalStrengthBars;
    char serviceString[100];
    char secondaryServiceString[100];
    char serviceCrossfadeString[100];
    char secondaryServiceCrossfadeString[100];
    char serviceImages[2][100];
    char operatorDirectory[1024];
    unsigned int serviceContentType;
    unsigned int secondaryServiceContentType;
    unsigned int cellLowDataModeActive:1;
    unsigned int secondaryCellLowDataModeActive:1;
    int wifiSignalStrengthRaw;
    int wifiSignalStrengthBars;
    unsigned int wifiLowDataModeActive:1;
    unsigned int dataNetworkType;
    unsigned int secondaryDataNetworkType;
    int batteryCapacity;
    unsigned int batteryState;
    char batteryDetailString[150];
    int bluetoothBatteryCapacity;
    int thermalColor;
    unsigned int thermalSunlightMode:1;
    unsigned int slowActivity:1;
    unsigned int syncActivity:1;
    char activityDisplayId[256];
    unsigned int bluetoothConnected:1;
    unsigned int displayRawGSMSignal:1;
    unsigned int displayRawWifiSignal:1;
    unsigned int locationIconType:1;
    unsigned int voiceControlIconType:2;
    unsigned int quietModeInactive:1;
    unsigned int tetheringConnectionCount;
    unsigned int batterySaverModeActive:1;
    unsigned int deviceIsRTL:1;
    unsigned int lock:1;
    char breadcrumbTitle[256];
    char breadcrumbSecondaryTitle[256];
    char personName[100];
    unsigned int electronicTollCollectionAvailable:1;
    unsigned int radarAvailable:1;
    unsigned int wifiLinkWarning:1;
    unsigned int wifiSearching:1;
    double backgroundActivityDisplayStartDate;
    unsigned int shouldShowEmergencyOnlyStatus:1;
    unsigned int secondaryCellularConfigured:1;
    char primaryServiceBadgeString[100];
    char secondaryServiceBadgeString[100];
    char quietModeImage[256];
} DIMStatusBarRawData;

typedef struct {
    bool overrideItemIsEnabled[44];
    unsigned int overrideTimeString:1;
    unsigned int overrideDateString:1;
    unsigned int overrideGsmSignalStrengthRaw:1;
    unsigned int overrideSecondaryGsmSignalStrengthRaw:1;
    unsigned int overrideGsmSignalStrengthBars:1;
    unsigned int overrideSecondaryGsmSignalStrengthBars:1;
    unsigned int overrideServiceString:1;
    unsigned int overrideSecondaryServiceString:1;
    unsigned int overrideServiceImages:2;
    unsigned int overrideOperatorDirectory:1;
    unsigned int overrideServiceContentType:1;
    unsigned int overrideSecondaryServiceContentType:1;
    unsigned int overrideWifiSignalStrengthRaw:1;
    unsigned int overrideWifiSignalStrengthBars:1;
    unsigned int overrideDataNetworkType:1;
    unsigned int overrideSecondaryDataNetworkType:1;
    unsigned int disallowsCellularDataNetworkTypes:1;
    unsigned int overrideBatteryCapacity:1;
    unsigned int overrideBatteryState:1;
    unsigned int overrideBatteryDetailString:1;
    unsigned int overrideBluetoothBatteryCapacity:1;
    unsigned int overrideThermalColor:1;
    unsigned int overrideSlowActivity:1;
    unsigned int overrideActivityDisplayId:1;
    unsigned int overrideBluetoothConnected:1;
    unsigned int overrideBreadcrumb:1;
    unsigned int overrideLock;
    unsigned int overrideDisplayRawGSMSignal:1;
    unsigned int overrideDisplayRawWifiSignal:1;
    unsigned int overridePersonName:1;
    unsigned int overrideWifiLinkWarning:1;
    unsigned int overrideSecondaryCellularConfigured:1;
    unsigned int overridePrimaryServiceBadgeString:1;
    unsigned int overrideSecondaryServiceBadgeString:1;
    unsigned int overrideQuietModeImage:1;
    DIMStatusBarRawData values;
} DIMStatusBarOverrideData;

static BOOL gDIMSIMEnabled = NO;
static BOOL gDIMDynamic = NO;
static int gDIMSignal = 4;
static int gDIMCurrentSignal = 4;
static NSString *gDIMCarrier = nil;
static BOOL gDIMInitialized = NO;

typedef DIMStatusBarOverrideData *(*DIMGetOverridesFn)(id, SEL);
typedef void (*DIMPostOverridesFn)(id, SEL, DIMStatusBarOverrideData *);

static Class DIMStatusClass(void) {
    return objc_getClass("UIStatusBarServer");
}

static BOOL DIMLoadConfig(void) {
    CFPropertyListRef value = CFPreferencesCopyValue(
        CFSTR("Runtime"),
        CFSTR("com.dim.manager"),
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    );

    if (!value) {
        value = CFPreferencesCopyValue(
            CFSTR("Runtime"),
            CFSTR("com.dim.manager"),
            kCFPreferencesAnyUser,
            kCFPreferencesAnyHost
        );
    }

    NSDictionary *runtime = nil;

    if (value) {
        id object = CFBridgingRelease(value);
        if ([object isKindOfClass:NSDictionary.class]) {
            runtime = object;
        }
    }

    if (!runtime) {
        NSArray *paths = @[
            @"/var/mobile/Library/Preferences/com.dim.manager.runtime.plist",
            @"/var/jb/var/mobile/Library/Preferences/com.dim.manager.runtime.plist"
        ];

        for (NSString *path in paths) {
            NSDictionary *file =
                [NSDictionary dictionaryWithContentsOfFile:path];

            if ([file[@"Runtime"] isKindOfClass:NSDictionary.class]) {
                runtime = file[@"Runtime"];
                break;
            }

            if ([file[@"SIM"] isKindOfClass:NSDictionary.class]) {
                runtime = file;
                break;
            }
        }
    }

    NSDictionary *sim = runtime[@"SIM"];

    if (![sim isKindOfClass:NSDictionary.class]) {
        gDIMSIMEnabled = NO;
        return NO;
    }

    gDIMSIMEnabled = [sim[@"Enabled"] boolValue];

    NSString *mode = sim[@"SignalMode"];
    gDIMDynamic = [mode isKindOfClass:NSString.class] &&
                  [mode caseInsensitiveCompare:@"Dynamic"] == NSOrderedSame;

    gDIMSignal = [sim[@"SignalStrength"] respondsToSelector:@selector(intValue)]
        ? [sim[@"SignalStrength"] intValue] : 4;

    gDIMSignal = MAX(1, MIN(4, gDIMSignal));

    NSString *carrier = sim[@"CarrierName"];

    gDIMCarrier = ([carrier isKindOfClass:NSString.class] && carrier.length)
        ? [carrier copy] : @"DIM";

    return YES;
}

static void DIMApplySignal(int strength) {
    Class cls = DIMStatusClass();
    if (!cls) {
        NSLog(@"[DIM SIM] UIStatusBarServer unavailable");
        return;
    }

    SEL getSelector = sel_registerName("getStatusBarOverrideData");
    SEL postSelector = sel_registerName("postStatusBarOverrideData:");
    SEL permanentSelector = sel_registerName("permanentizeStatusBarOverrideData");

    DIMGetOverridesFn getOverrides =
        (DIMGetOverridesFn)objc_msgSend;

    DIMPostOverridesFn postOverrides =
        (DIMPostOverridesFn)objc_msgSend;

    DIMStatusBarOverrideData *current =
        getOverrides(cls, getSelector);

    if (!current) {
        NSLog(@"[DIM SIM] Could not get status bar overrides");
        return;
    }

    DIMStatusBarOverrideData data = *current;

    strength = MAX(1, MIN(4, strength));

    data.overrideGsmSignalStrengthBars = 1;
    data.values.gsmSignalStrengthBars = strength;

    data.overrideItemIsEnabled[4] = 1;
    data.values.itemIsEnabled[4] = 1;

    data.overrideItemIsEnabled[6] = 1;
    data.values.itemIsEnabled[6] = 1;

    data.overrideServiceString = 1;

    const char *carrier = (gDIMCarrier ?: @"DIM").UTF8String;

    strlcpy(data.values.serviceString, carrier,
            sizeof(data.values.serviceString));

    strlcpy(data.values.serviceCrossfadeString, carrier,
            sizeof(data.values.serviceCrossfadeString));

    postOverrides(cls, postSelector, &data);

    if ([cls respondsToSelector:permanentSelector]) {
        ((void (*)(id, SEL))objc_msgSend)(cls, permanentSelector);
    }

    gDIMCurrentSignal = strength;

    NSLog(@"[DIM SIM] Applied: %@, signal %d/4",
          gDIMCarrier, strength);
}

static void DIMDisableSignal(void) {
    Class cls = DIMStatusClass();
    if (!cls) return;

    SEL getSelector = sel_registerName("getStatusBarOverrideData");
    SEL postSelector = sel_registerName("postStatusBarOverrideData:");
    SEL permanentSelector =
        sel_registerName("permanentizeStatusBarOverrideData");

    DIMStatusBarOverrideData *current =
        ((DIMGetOverridesFn)objc_msgSend)(cls, getSelector);

    if (!current) return;

    DIMStatusBarOverrideData data = *current;

    data.overrideGsmSignalStrengthBars = 0;
    data.overrideItemIsEnabled[4] = 0;
    data.overrideItemIsEnabled[6] = 0;
    data.overrideServiceString = 0;

    ((DIMPostOverridesFn)objc_msgSend)(cls, postSelector, &data);

    if ([cls respondsToSelector:permanentSelector]) {
        ((void (*)(id, SEL))objc_msgSend)(cls, permanentSelector);
    }

    NSLog(@"[DIM SIM] Overrides disabled");
}

static void DIMScheduleDynamic(void);

static void DIMDynamicDrop(void) {
    if (!gDIMSIMEnabled || !gDIMDynamic) return;

    int reduced = (arc4random_uniform(8) == 0) ? 2 : 3;

    DIMApplySignal(reduced);

    int duration = 8 + (int)arc4random_uniform(13);

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)duration * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
            if (gDIMSIMEnabled && gDIMDynamic) {
                DIMApplySignal(4);
                DIMScheduleDynamic();
            }
        }
    );
}

static void DIMScheduleDynamic(void) {
    if (!gDIMSIMEnabled || !gDIMDynamic) return;

    int delay = 1800 + (int)arc4random_uniform(3600);

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)delay * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
            DIMDynamicDrop();
        }
    );
}

static void DIMRefresh(void) {
    DIMLoadConfig();

    if (!gDIMSIMEnabled) {
        DIMDisableSignal();
        return;
    }

    if (gDIMDynamic) {
        DIMApplySignal(4);
        DIMScheduleDynamic();
    } else {
        DIMApplySignal(gDIMSignal);
    }
}

static void DIMSIMInitialize(void) {
    if (gDIMInitialized) return;
    gDIMInitialized = YES;

    NSString *bundle = NSBundle.mainBundle.bundleIdentifier;

    if (![bundle isEqualToString:@"com.apple.springboard"]) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        DIMRefresh();

        int token = 0;

        notify_register_dispatch(
            DIM_SIM_NOTIFY,
            &token,
            dispatch_get_main_queue(),
            ^(int observer) {
                DIMRefresh();
            }
        );
    });
}

__attribute__((constructor))
static void DIMSIMConstructor(void) {
    @autoreleasepool {
        DIMSIMInitialize();
    }
}
