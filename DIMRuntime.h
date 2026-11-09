// Общий код для настроек (Settings) и твика.
//
// Почему нужен отдельный файл: твик загружается в ЧУЖИЕ приложения (Telegram и т.д.),
// которые работают в песочнице и не могут надёжно читать NSUserDefaults другого домена.
//
// ВАЖНО (v0.3.2): раньше конфиг писался только обычным файлом в
// /var/mobile/Library/Preferences/. Песочница App Store приложений (Telegram, Discord,
// AIDA64) запрещает прямое чтение этого пути, поэтому твик внутри таких приложений
// вообще не видел профиль и молча выходил — устройство оставалось оригинальным,
// а Check не получал ни одного beacon'а.
//
// Теперь конфиг дополнительно лежит в самом домене com.dim.manager ("Runtime"),
// и приложения читают его через cfprefsd (sandbox-safe). Файл остаётся резервным
// каналом для отладки и окружений без песочницы.

#import <Foundation/Foundation.h>
#import <notify.h>
#import <stdint.h>

#define DIM_DOMAIN @"com.dim.manager"
#define DIM_RUNTIME_KEY @"Runtime"
#define DIM_RUNTIME_PATH @"/var/mobile/Library/Preferences/com.dim.manager.runtime.plist"
#define DIM_RUNTIME_CHANGED "com.dim.manager.changed"

// FNV-1a 64 бит: используется для проверки "что реально видит приложение".
static inline uint64_t DIMFNV1a(const char *string) {
    uint64_t hash = 1469598103934665603ULL;

    while (string && *string) {
        hash ^= (uint8_t)*string++;
        hash *= 1099511628211ULL;
    }

    return hash;
}

// Менеджер -> runtime-конфиг. Вызывается после любого изменения настроек.
static inline void DIMWriteRuntime(NSUserDefaults *prefs) {
    if (!prefs) return;

    NSMutableDictionary *config = [NSMutableDictionary dictionary];

    config[@"Enabled"] =
        @([prefs objectForKey:@"Enabled"] ? [prefs boolForKey:@"Enabled"] : YES);
    config[@"DeviceEnabled"] = @([prefs boolForKey:@"DeviceEnabled"]);
    config[@"Global"] = @([prefs boolForKey:@"GlobalProfileEnabled"]);
    config[@"OnlyIn"] = @([prefs boolForKey:@"OnlyInEnabled"]);

    NSArray *apps = [prefs arrayForKey:@"SelectedApps"];
    config[@"Apps"] = [apps isKindOfClass:[NSArray class]] ? apps : @[];

    NSDictionary *profile = [prefs dictionaryForKey:@"ActiveProfile"];
    config[@"Profile"] = [profile isKindOfClass:[NSDictionary class]] ? profile : @{};

    // Основной канал: тот же домен, что и настройки.
    // Читается из приложений через cfprefsd -> песочница не мешает.
    [prefs setObject:config forKey:DIM_RUNTIME_KEY];
    [prefs synchronize];

    // Резервный канал: обычный файл (из песочницы может не записаться, это не критично).
    [config writeToFile:DIM_RUNTIME_PATH atomically:YES];

    // Запущенные приложения перечитывают конфиг сразу, без перезапуска.
    notify_post(DIM_RUNTIME_CHANGED);
}

// Что записано в runtime сейчас (для диагностики в настройках).
static inline NSString *DIMDescribeRuntime(NSUserDefaults *prefs) {
    NSMutableArray *sources = [NSMutableArray array];

    if ([prefs dictionaryForKey:DIM_RUNTIME_KEY]) {
        [sources addObject:@"prefs"];
    }

    if ([[NSFileManager defaultManager] fileExistsAtPath:DIM_RUNTIME_PATH]) {
        [sources addObject:@"file"];
    }

    NSString *rootless =
        [@"/var/jb" stringByAppendingString:DIM_RUNTIME_PATH];

    if ([[NSFileManager defaultManager] fileExistsAtPath:rootless]) {
        [sources addObject:@"rootless"];
    }

    return sources.count
        ? [sources componentsJoinedByString:@" • "]
        : @"missing (press Apply All)";
}
