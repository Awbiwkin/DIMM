
#import <Foundation/Foundation.h>
#import <notify.h>
#import <stdint.h>

#define DIM_DOMAIN @"com.dim.manager"
#define DIM_RUNTIME_KEY @"Runtime"
#define DIM_RUNTIME_PATH @"/var/mobile/Library/Preferences/com.dim.manager.runtime.plist"
#define DIM_RUNTIME_CHANGED "com.dim.manager.changed"

#define DIM_SIM_ENABLED_KEY @"SIMEnabled"
#define DIM_SIM_MODE_KEY @"SIMSignalMode"
#define DIM_SIM_STRENGTH_KEY @"SIMSignalStrength"
#define DIM_SIM_CARRIER_KEY @"SIMCarrierName"
#define DIM_SIM_COUNTRY_KEY @"SIMCarrierCountry"

static inline uint64_t DIMFNV1a(const char *string) {
    uint64_t hash = 1469598103934665603ULL;
    while (string && *string) {
        hash ^= (uint8_t)*string++;
        hash *= 1099511628211ULL;
    }
    return hash;
}

static inline void DIMWriteRuntime(NSUserDefaults *prefs) {
    if (!prefs) return;

    NSMutableDictionary *config = [NSMutableDictionary dictionary];

    config[@"Enabled"] =
        @([prefs objectForKey:@"Enabled"]
          ? [prefs boolForKey:@"Enabled"] : YES);

    config[@"DeviceEnabled"] = @([prefs boolForKey:@"DeviceEnabled"]);
    config[@"Global"] = @([prefs boolForKey:@"GlobalProfileEnabled"]);
    config[@"OnlyIn"] = @([prefs boolForKey:@"OnlyInEnabled"]);

    NSArray *apps = [prefs arrayForKey:@"SelectedApps"];
    config[@"Apps"] = [apps isKindOfClass:NSArray.class] ? apps : @[];

    NSDictionary *profile = [prefs dictionaryForKey:@"ActiveProfile"];
    config[@"Profile"] =
        [profile isKindOfClass:NSDictionary.class] ? profile : @{};

    NSMutableDictionary *sim = [NSMutableDictionary dictionary];

    sim[@"Enabled"] = @([prefs boolForKey:DIM_SIM_ENABLED_KEY]);

    NSString *mode = [prefs stringForKey:DIM_SIM_MODE_KEY];

    if (![mode isKindOfClass:NSString.class] ||
        (![mode isEqualToString:@"Static"] &&
         ![mode isEqualToString:@"Dynamic"])) {
        mode = @"Static";
    }

    sim[@"SignalMode"] = mode;

    NSInteger strength = [prefs integerForKey:DIM_SIM_STRENGTH_KEY];
    strength = MAX(1, MIN(4, strength ?: 4));
    sim[@"SignalStrength"] = @(strength);

    NSString *carrier = [prefs stringForKey:DIM_SIM_CARRIER_KEY];
    NSString *country = [prefs stringForKey:DIM_SIM_COUNTRY_KEY];

    sim[@"CarrierName"] =
        [carrier isKindOfClass:NSString.class] ? carrier : @"";

    sim[@"CarrierCountry"] =
        [country isKindOfClass:NSString.class] ? country : @"";

    config[@"SIM"] = sim;

    [prefs setObject:config forKey:DIM_RUNTIME_KEY];
    [prefs synchronize];

    [config writeToFile:DIM_RUNTIME_PATH atomically:YES];

    notify_post(DIM_RUNTIME_CHANGED);
}

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
