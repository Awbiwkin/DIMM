
#import <Foundation/Foundation.h>
#import <notify.h>
#import <stdint.h>

#define DIM_DOMAIN @"com.dim.manager"
#define DIM_RUNTIME_KEY @"Runtime"
#define DIM_RUNTIME_PATH @"/var/mobile/Library/Preferences/com.dim.manager.runtime.plist"
#define DIM_RUNTIME_CHANGED "com.dim.manager.changed"

// SIM Status preference keys
#define DIM_SIM_ENABLED_KEY @"SIMEnabled"
#define DIM_SIM_MODE_KEY @"SIMSignalMode"
#define DIM_SIM_STRENGTH_KEY @"SIMSignalStrength"
#define DIM_SIM_CARRIER_KEY @"SIMCarrierName"
#define DIM_SIM_COUNTRY_KEY @"SIMCarrierCountry"

// FNV-1a 64 bit
static inline uint64_t DIMFNV1a(const char *string) {
    uint64_t hash = 1469598103934665603ULL;

    while (string && *string) {
        hash ^= (uint8_t)*string++;
        hash *= 1099511628211ULL;
    }

    return hash;
}

// Менеджер -> runtime-конфиг
static inline void DIMWriteRuntime(NSUserDefaults *prefs) {
    if (!prefs) return;

    NSMutableDictionary *config = [NSMutableDictionary dictionary];

    // GENERAL
    config[@"Enabled"] =
        @([prefs objectForKey:@"Enabled"]
            ? [prefs boolForKey:@"Enabled"] : YES);

    // DEVICE IDENTITY
    config[@"DeviceEnabled"] = @([prefs boolForKey:@"DeviceEnabled"]);
    config[@"Global"] = @([prefs boolForKey:@"GlobalProfileEnabled"]);
    config[@"OnlyIn"] = @([prefs boolForKey:@"OnlyInEnabled"]);

    NSArray *apps = [prefs arrayForKey:@"SelectedApps"];
    config[@"Apps"] =
        [apps isKindOfClass:[NSArray class]] ? apps : @[];

    NSDictionary *profile = [prefs dictionaryForKey:@"ActiveProfile"];
    config[@"Profile"] =
        [profile isKindOfClass:[NSDictionary class]] ? profile : @{};

    // SIM STATUS
    NSMutableDictionary *sim = [NSMutableDictionary dictionary];

    sim[@"Enabled"] = @([prefs boolForKey:DIM_SIM_ENABLED_KEY]);

    NSString *signalMode = [prefs stringForKey:DIM_SIM_MODE_KEY];
    if (![signalMode isKindOfClass:[NSString class]] ||
        !signalMode.length) {
        signalMode = @"Static";
    }
    sim[@"SignalMode"] = signalMode;

    NSInteger signalStrength =
        [prefs objectForKey:DIM_SIM_STRENGTH_KEY]
            ? [prefs integerForKey:DIM_SIM_STRENGTH_KEY] : 4;

    signalStrength = MAX(1, MIN(4, signalStrength));
    sim[@"SignalStrength"] = @(signalStrength);

    NSString *carrierName = [prefs stringForKey:DIM_SIM_CARRIER_KEY];
    if (![carrierName isKindOfClass:[NSString class]]) {
        carrierName = @"";
    }
    sim[@"CarrierName"] = carrierName;

    NSString *carrierCountry = [prefs stringForKey:DIM_SIM_COUNTRY_KEY];
    if (![carrierCountry isKindOfClass:[NSString class]]) {
        carrierCountry = @"";
    }
    sim[@"CarrierCountry"] = carrierCountry;

    config[@"SIM"] = [sim copy];

    // Основной канал: cfprefsd
    [prefs setObject:config forKey:DIM_RUNTIME_KEY];
    [prefs synchronize];

    // Резервный файл
    [config writeToFile:DIM_RUNTIME_PATH atomically:YES];

    // Уведомляем запущенные приложения
    notify_post(DIM_RUNTIME_CHANGED);
}

// Диагностика runtime
static inline NSString *DIMDescribeRuntime(NSUserDefaults *prefs) {
    NSMutableArray *sources = [NSMutableArray array];

    if ([prefs dictionaryForKey:DIM_RUNTIME_KEY]) {
        [sources addObject:@"prefs"];
    }

    if ([[NSFileManager defaultManager]
            fileExistsAtPath:DIM_RUNTIME_PATH]) {
        [sources addObject:@"file"];
    }

    NSString *rootless =
        [@"/var/jb" stringByAppendingString:DIM_RUNTIME_PATH];

    if ([[NSFileManager defaultManager]
            fileExistsAtPath:rootless]) {
        [sources addObject:@"rootless"];
    }

    return sources.count
        ? [sources componentsJoinedByString:@" • "]
        : @"missing (press Apply All)";
}
