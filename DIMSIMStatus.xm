
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <string.h>
#import <stdlib.h>

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

static BOOL gEnabled = NO;
static BOOL gDynamic = NO;
static NSInteger gStrength = 4;
static NSString *gCarrier = nil;
static NSString *gCountry = nil;
static BOOL gInitialized = NO;
static int gNotifyToken = 0;
static dispatch_source_t gTimer = nil;
static BOOL gOverrideApplied = NO;

typedef DIMStatusBarOverrideData *(*DIMGetFn)(id, SEL);
typedef void (*DIMPostFn)(id, SEL, DIMStatusBarOverrideData *);

static Class DIMServer(void) {
    return objc_getClass("UIStatusBarServer");
}

static NSDictionary *DIMReadRuntime(void) {
    CFPropertyListRef value = CFPreferencesCopyValue(
        CFSTR("Runtime"),
        CFSTR("com.dim.manager"),
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    );

    if (!value) return nil;

    id object = CFBridgingRelease(value);

    if (![object isKindOfClass:NSDictionary.class]) return nil;

    return object;
}

static BOOL DIMLoadConfig(void) {
    NSDictionary *runtime = DIMReadRuntime();

    if (!runtime) {
        NSArray *paths = @[
            @"/var/mobile/Library/Preferences/com.dim.manager.runtime.plist",
            @"/var/jb/var/mobile/Library/Preferences/com.dim.manager.runtime.plist"
        ];

        for (NSString *path in paths) {
            NSDictionary *file =
                [NSDictionary dictionaryWithContentsOfFile:path];

            if ([file[@"SIM"] isKindOfClass:NSDictionary.class]) {
                runtime = file;
                break;
            }
        }
    }

    NSDictionary *sim = runtime[@"SIM"];

    if (![sim isKindOfClass:NSDictionary.class]) {
        gEnabled = NO;
        return NO;
    }

    gEnabled = [sim[@"Enabled"] boolValue];

    NSString *mode = sim[@"SignalMode"];
    gDynamic = [mode isKindOfClass:NSString.class] &&
        [mode caseInsensitiveCompare:@"Dynamic"] == NSOrderedSame;

    gStrength = [sim[@"SignalStrength"] integerValue];
    gStrength = MAX(1, MIN(4, gStrength ?: 4));

    NSString *carrier = sim[@"CarrierName"];
    NSString *country = sim[@"CarrierCountry"];

    gCarrier = ([carrier isKindOfClass:NSString.class] && carrier.length)
        ? [carrier copy] : @"DIM";

    gCountry = ([country isKindOfClass:NSString.class] && country.length)
        ? [country copy] : @"";

    return YES;
}

static void DIMCancelTimer(void) {
    if (gTimer) {
        dispatch_source_cancel(gTimer);
        gTimer = nil;
    }
}

static void DIMApply(NSInteger strength) {
    Class cls = DIMServer();

    if (!cls) {
        NSLog(@"[DIM SIM] UIStatusBarServer unavailable");
        return;
    }

    SEL getSel = sel_registerName("getStatusBarOverrideData");
    SEL postSel = sel_registerName("postStatusBarOverrideData:");
    SEL permanentSel =
        sel_registerName("permanentizeStatusBarOverrideData");

    DIMStatusBarOverrideData *current =
        ((DIMGetFn)objc_msgSend)(cls, getSel);

    if (!current) {
        NSLog(@"[DIM SIM] Could not get override data");
        return;
    }

    DIMStatusBarOverrideData data = *current;

    strength = MAX(1, MIN(4, strength));

    // CellularSignalStrengthStatusBarItem = 4
    data.overrideGsmSignalStrengthBars = 1;
    data.values.gsmSignalStrengthBars = (int)strength;

    data.overrideItemIsEnabled[4] = 1;
    data.values.itemIsEnabled[4] = 1;

    // CellularServiceStatusBarItem = 6
    data.overrideItemIsEnabled[6] = 1;
    data.values.itemIsEnabled[6] = 1;

    data.overrideServiceString = 1;

    const char *carrier = (gCarrier ?: @"DIM").UTF8String;

    strlcpy(data.values.serviceString, carrier,
            sizeof(data.values.serviceString));

    strlcpy(data.values.serviceCrossfadeString, carrier,
            sizeof(data.values.serviceCrossfadeString));

    ((DIMPostFn)objc_msgSend)(cls, postSel, &data);

    if ([cls respondsToSelector:permanentSel]) {
        ((void (*)(id, SEL))objc_msgSend)(cls, permanentSel);
    }

    gOverrideApplied = YES;

    NSLog(@"[DIM SIM] %@ %@ signal=%ld/4",
          gCountry, gCarrier, (long)strength);
}

static void DIMDisable(void) {
    Class cls = DIMServer();

    if (!cls || !gOverrideApplied) return;

    SEL getSel = sel_registerName("getStatusBarOverrideData");
    SEL postSel = sel_registerName("postStatusBarOverrideData:");
    SEL permanentSel =
        sel_registerName("permanentizeStatusBarOverrideData");

    DIMStatusBarOverrideData *current =
        ((DIMGetFn)objc_msgSend)(cls, getSel);

    if (!current) return;

    DIMStatusBarOverrideData data = *current;

    data.overrideGsmSignalStrengthBars = 0;
    data.overrideItemIsEnabled[4] = 0;
    data.overrideItemIsEnabled[6] = 0;
    data.overrideServiceString = 0;

    ((DIMPostFn)objc_msgSend)(cls, postSel, &data);

    if ([cls respondsToSelector:permanentSel]) {
        ((void (*)(id, SEL))objc_msgSend)(cls, permanentSel);
    }

    gOverrideApplied = NO;
    NSLog(@"[DIM SIM] Disabled");
}

static void DIMScheduleDynamic(void);

static void DIMDynamicTick(void) {
    if (!gEnabled || !gDynamic) return;

    // 1 из 8 циклов опускается до 2 полосок,
    // остальные — до 3. Затем возвращается к 4.
    NSInteger reduced =
        arc4random_uniform(8) == 0 ? 2 : 3;

    DIMApply(reduced);

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(8 + arc4random_uniform(13)) *
                      NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
            if (!gEnabled || !gDynamic) return;

            DIMApply(4);
            DIMScheduleDynamic();
        }
    );
}

static void DIMScheduleDynamic(void) {
    if (!gEnabled || !gDynamic) return;

    DIMCancelTimer();

    gTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER,
        0,
        0,
        dispatch_get_main_queue()
    );

    uint64_t delay =
        (uint64_t)(1800 + arc4random_uniform(3600)) * NSEC_PER_SEC;

    dispatch_source_set_timer(
        gTimer,
        dispatch_time(DISPATCH_TIME_NOW, delay),
        DISPATCH_TIME_FOREVER,
        1 * NSEC_PER_SEC
    );

    dispatch_source_set_event_handler(gTimer, ^{
        dispatch_source_t old = gTimer;
        gTimer = nil;
        if (old) dispatch_source_cancel(old);

        DIMDynamicTick();
    });

    dispatch_resume(gTimer);
}

static void DIMRefresh(void) {
    DIMCancelTimer();
    DIMLoadConfig();

    if (!gEnabled) {
        DIMDisable();
        return;
    }

    if (gDynamic) {
        DIMApply(4);
        DIMScheduleDynamic();
    } else {
        DIMApply(gStrength);
    }
}

static void DIMInitialize(void) {
    if (gInitialized) return;

    NSString *bundle = NSBundle.mainBundle.bundleIdentifier;

    if (![bundle isEqualToString:@"com.apple.springboard"]) {
        return;
    }

    gInitialized = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        DIMRefresh();

        notify_register_dispatch(
            DIM_SIM_NOTIFY,
            &gNotifyToken,
            dispatch_get_main_queue(),
            ^(int token) {
                DIMRefresh();
            }
        );
    });
}

__attribute__((constructor))
static void DIMSIMConstructor(void) {
    @autoreleasepool {
        DIMInitialize();
    }
}
