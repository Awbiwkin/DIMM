#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <notify.h>
#import <dlfcn.h>
#import <pthread.h>
#import <CoreFoundation/CoreFoundation.h>

#import <sys/types.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <errno.h>
#import <string.h>
#import <stdlib.h>
#import <stdio.h>

#import "DIMRuntime.h"

#ifndef KERN_OSVERSION
#define KERN_OSVERSION 65
#endif

#ifndef KERN_OSPRODUCTVERSION
#define KERN_OSPRODUCTVERSION 245
#endif

// ------------------------------------------------------------
// ЧТО ИЗМЕНИЛОСЬ В 0.3.2
// ------------------------------------------------------------
// 1. Профиль больше не читается один раз на старте напрямую из файла.
//    Приложения в песочнице этот файл читать не могут, поэтому твик раньше
//    вообще не устанавливал хуки. Теперь конфиг читается через cfprefsd
//    (домен com.dim.manager, ключ Runtime), с резервом на файл; значения
//    подставляются в момент вызова, а не в момент запуска процесса.
// 2. Хуки ставятся всегда и переживают применение профиля "на ходу":
//    после Apply приложение получает darwin-уведомление и сразу видит новые
//    значения (для уже прочитанных в память кешей всё равно нужен перезапуск).
// 3. Добавлены поверхности, по которым реальные приложения и смотрят модель:
//    MobileGestalt (MGCopyAnswer / MGGetStringAnswer), kern.osproductversion,
//    __sysctl, NSProcessInfo.operatingSystemVersion(String).
// 4. Два beacon'а: "alive" (твик вообще загрузился в процесс) и "verify"
//    (какие значения реально видит приложение). По ним Check отличает
//    "не загрузился" от "загрузился, но профиль не применён".

// ------------------------------------------------------------
// СОСТОЯНИЕ
// ------------------------------------------------------------

typedef struct {
    int configActive;               // модель/борд подставляются
    int iosActive;                  // версия iOS/build/darwin подставляются
    char machine[64];               // iPhone16,2
    char board[64];                 // D84AP
    char family[16];                // iPhone / iPad
    char version[32];               // 18.0
    char build[32];                 // 22A3354
    char darwin[32];                // 24.0.0
    char kernelVersion[512];        // kern.version с подставленным Darwin
} DIMProfile;

static DIMProfile gProfile;
static pthread_mutex_t gLock;
static int gLockReady = 0;
static int gReloading = 0;
static CFAbsoluteTime gProfileStamp = 0;
static int gProfileDirty = 1;
static char gBundleID[192];

typedef int (*DIMSysctlByNameFn)(const char *, void *, size_t *, void *, size_t);
typedef int (*DIMSysctlFn)(int *, u_int, void *, size_t *, void *, size_t);
typedef int (*DIMUnameFn)(struct utsname *);

static DIMSysctlByNameFn DIMOriginalSysctlByName = NULL;
static DIMSysctlFn DIMOriginalSysctl = NULL;
static DIMSysctlFn DIMOriginalUnderscoreSysctl = NULL;
static DIMUnameFn DIMOriginalUname = NULL;

static NSString *(*DIMOriginalDeviceModel)(id, SEL) = NULL;
static NSString *(*DIMOriginalDeviceLocalizedModel)(id, SEL) = NULL;
static NSString *(*DIMOriginalDeviceSystemVersion)(id, SEL) = NULL;
static NSOperatingSystemVersion (*DIMOriginalOperatingSystemVersion)(id, SEL) = NULL;
static NSString *(*DIMOriginalOperatingSystemVersionString)(id, SEL) = NULL;
static BOOL (*DIMOriginalIsOperatingSystemAtLeastVersion)(id, SEL, NSOperatingSystemVersion) = NULL;

typedef CFTypeRef (*DIMCopyAnswerFn)(CFStringRef);
typedef CFStringRef (*DIMStringAnswerFn)(CFStringRef);

static DIMCopyAnswerFn DIMOriginalMGCopyAnswer = NULL;
static DIMStringAnswerFn DIMOriginalMGStringAnswer = NULL;

// ------------------------------------------------------------
// MUTEX
// ------------------------------------------------------------

static void DIMInitLock(void) {
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        pthread_mutexattr_t attributes;
        pthread_mutexattr_init(&attributes);
        pthread_mutexattr_settype(&attributes, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&gLock, &attributes);
        pthread_mutexattr_destroy(&attributes);
        gLockReady = 1;
    });
}

static inline double DIMNow(void) {
    return CFAbsoluteTimeGetCurrent();
}

// ------------------------------------------------------------
// ЧТЕНИЕ КОНФИГА (sandbox-safe)
// ------------------------------------------------------------

static NSString *DIMStringValue(NSDictionary *dictionary, NSString *key) {
    id value = dictionary[key];

    return ([value isKindOfClass:[NSString class]] && [value length]) ? value : nil;
}

static NSDictionary *DIMConfigFromPreferences(void) {
    CFStringRef domain = CFSTR("com.dim.manager");
    CFStringRef key = CFSTR("Runtime");

    CFPropertyListRef value =
        CFPreferencesCopyValue(key, domain,
                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost);

    if (!value) {
        value = CFPreferencesCopyValue(key, domain,
                                       kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    }

    if (!value) return nil;

    id object = (__bridge_transfer id)value;

    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

static NSDictionary *DIMConfigFromFile(void) {
    NSArray<NSString *> *paths = @[
        @"/var/mobile/Library/Preferences/com.dim.manager.runtime.plist",
        @"/var/jb/var/mobile/Library/Preferences/com.dim.manager.runtime.plist",
        @"/var/mobile/Library/Preferences/com.dim.manager.plist",
        @"/var/jb/var/mobile/Library/Preferences/com.dim.manager.plist"
    ];

    for (NSString *path in paths) {
        NSDictionary *contents = [NSDictionary dictionaryWithContentsOfFile:path];

        if (![contents isKindOfClass:[NSDictionary class]]) continue;

        NSDictionary *runtime = contents[@"Runtime"];

        if ([runtime isKindOfClass:[NSDictionary class]]) return runtime;

        // Старый (плоский) формат файла: ключи лежат на верхнем уровне.
        if (contents[@"Profile"] || contents[@"Enabled"]) return contents;
    }

    return nil;
}

static NSDictionary *DIMReadConfig(void) {
    NSDictionary *config = DIMConfigFromPreferences();

    if (config) return config;

    return DIMConfigFromFile();
}

// ------------------------------------------------------------
// ПРОФИЛЬ
// ------------------------------------------------------------

static void DIMRefreshMGCacheLocked(void);

static void DIMBuildKernelVersionLocked(void) {
    gProfile.kernelVersion[0] = '\0';

    if (!gProfile.iosActive || !DIMOriginalUname) return;

    struct utsname info;
    memset(&info, 0, sizeof(info));

    if (DIMOriginalUname(&info) != 0) return;

    NSString *original = [NSString stringWithUTF8String:info.version];
    NSString *release = [NSString stringWithUTF8String:info.release];

    if (!original.length) return;

    NSString *patched = original;

    if (release.length) {
        patched = [original
            stringByReplacingOccurrencesOfString:release
                                      withString:[NSString stringWithUTF8String:gProfile.darwin]];
    }

    strlcpy(gProfile.kernelVersion, patched.UTF8String,
            sizeof(gProfile.kernelVersion));
}

static void DIMReloadProfileLocked(void) {
    memset(&gProfile, 0, sizeof(gProfile));
    gProfileStamp = DIMNow();

    NSDictionary *config = DIMReadConfig();
    NSDictionary *profile = [config[@"Profile"] isKindOfClass:[NSDictionary class]]
        ? config[@"Profile"] : nil;

    BOOL enabled = [config[@"Enabled"] boolValue];
    BOOL deviceEnabled = [config[@"DeviceEnabled"] boolValue];
    BOOL global = [config[@"Global"] boolValue];
    BOOL onlyIn = [config[@"OnlyIn"] boolValue];

    BOOL inScope = NO;

    if (config && enabled && deviceEnabled) {
        if (global) {
            inScope = YES;
        } else if (onlyIn) {
            NSArray *apps = config[@"Apps"];
            NSString *bundleID = [NSString stringWithUTF8String:gBundleID];

            inScope = [apps isKindOfClass:[NSArray class]] &&
                      bundleID.length &&
                      [apps containsObject:bundleID];
        }
    }

    if (inScope && profile) {
        NSString *identifier = DIMStringValue(profile, @"identifier");
        NSString *board = DIMStringValue(profile, @"boardconfig");
        NSString *version = DIMStringValue(profile, @"version");
        NSString *build = DIMStringValue(profile, @"build");
        NSString *darwin = DIMStringValue(profile, @"darwin");

        if ([profile[@"config_applied"] boolValue] && identifier && board) {
            gProfile.configActive = 1;

            strlcpy(gProfile.machine, identifier.UTF8String,
                    sizeof(gProfile.machine));
            strlcpy(gProfile.board, board.UTF8String, sizeof(gProfile.board));
            strlcpy(gProfile.family,
                    [identifier hasPrefix:@"iPad"] ? "iPad" : "iPhone",
                    sizeof(gProfile.family));
        }

        if ([profile[@"ios_applied"] boolValue] && version && build && darwin) {
            gProfile.iosActive = 1;

            strlcpy(gProfile.version, version.UTF8String,
                    sizeof(gProfile.version));
            strlcpy(gProfile.build, build.UTF8String, sizeof(gProfile.build));
            strlcpy(gProfile.darwin, darwin.UTF8String, sizeof(gProfile.darwin));
        }
    }

    if (gProfile.iosActive) {
        DIMBuildKernelVersionLocked();
    }

    DIMRefreshMGCacheLocked();
    gProfileDirty = 0;
}

// Вызывать только с захваченным gLock.
static void DIMEnsureProfileLocked(void) {
    if (!gLockReady || gReloading) return;

    if (!gProfileDirty && (DIMNow() - gProfileStamp) < 3.0) return;

    gReloading = 1;
    DIMReloadProfileLocked();
    gReloading = 0;
}

static void DIMMarkDirty(void) {
    if (!gLockReady) return;

    pthread_mutex_lock(&gLock);
    gProfileDirty = 1;
    pthread_mutex_unlock(&gLock);
}

// ------------------------------------------------------------
// SYSCTL OUTPUT
// ------------------------------------------------------------

// Ведёт себя как настоящий sysctl: вызов с oldp == NULL возвращает только размер,
// слишком маленький буфер -> ENOMEM и нужный размер.
static int DIMWriteString(const char *value, void *oldp, size_t *oldlenp) {
    if (!value || !oldlenp) {
        errno = EFAULT;
        return -1;
    }

    size_t required = strlen(value) + 1;

    if (!oldp) {
        *oldlenp = required;
        return 0;
    }

    if (*oldlenp < required) {
        *oldlenp = required;
        errno = ENOMEM;
        return -1;
    }

    memcpy(oldp, value, required);
    *oldlenp = required;

    return 0;
}

static const char *DIMValueForNameLocked(const char *name) {
    if (!name) return NULL;

    if (gProfile.configActive) {
        if (strcmp(name, "hw.machine") == 0) return gProfile.machine;
        if (strcmp(name, "hw.model") == 0) return gProfile.board;
    }

    if (gProfile.iosActive) {
        if (strcmp(name, "kern.osrelease") == 0) return gProfile.darwin;
        if (strcmp(name, "kern.osversion") == 0) return gProfile.build;
        if (strcmp(name, "kern.osproductversion") == 0) return gProfile.version;
        if (strcmp(name, "kern.version") == 0 && gProfile.kernelVersion[0])
            return gProfile.kernelVersion;
    }

    return NULL;
}

static const char *DIMValueForMIBLocked(int *name, u_int length) {
    if (!name || length != 2) return NULL;

    if (gProfile.configActive && name[0] == CTL_HW) {
        if (name[1] == HW_MACHINE) return gProfile.machine;
        if (name[1] == HW_MODEL) return gProfile.board;
    }

    if (gProfile.iosActive && name[0] == CTL_KERN) {
        if (name[1] == KERN_OSRELEASE) return gProfile.darwin;
        if (name[1] == KERN_OSVERSION) return gProfile.build;
        if ((u_int)name[1] == (u_int)KERN_OSPRODUCTVERSION) return gProfile.version;
        if (name[1] == KERN_VERSION && gProfile.kernelVersion[0])
            return gProfile.kernelVersion;
    }

    return NULL;
}

// ------------------------------------------------------------
// SYSCTL HOOKS
// ------------------------------------------------------------

static int DIMHookSysctlByName(
    const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen
) {
    if (newp == NULL && oldlenp) {
        int handled = 0;
        int status = 0;

        pthread_mutex_lock(&gLock);
        DIMEnsureProfileLocked();

        const char *replacement = DIMValueForNameLocked(name);

        if (replacement) {
            status = DIMWriteString(replacement, oldp, oldlenp);
            handled = 1;
        }

        pthread_mutex_unlock(&gLock);

        if (handled) return status;
    }

    return DIMOriginalSysctlByName
        ? DIMOriginalSysctlByName(name, oldp, oldlenp, newp, newlen)
        : (errno = ENOSYS, -1);
}

static int DIMHookSysctl(
    int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen,
    DIMSysctlFn original
) {
    if (newp == NULL && oldlenp) {
        int handled = 0;
        int status = 0;

        pthread_mutex_lock(&gLock);
        DIMEnsureProfileLocked();

        const char *replacement = DIMValueForMIBLocked(name, namelen);

        if (replacement) {
            status = DIMWriteString(replacement, oldp, oldlenp);
            handled = 1;
        }

        pthread_mutex_unlock(&gLock);

        if (handled) return status;
    }

    return original ? original(name, namelen, oldp, oldlenp, newp, newlen)
                    : (errno = ENOSYS, -1);
}

static int DIMTrampolineSysctl(
    int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen
) {
    return DIMHookSysctl(name, namelen, oldp, oldlenp, newp, newlen, DIMOriginalSysctl);
}

static int DIMTrampolineUnderscoreSysctl(
    int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen
) {
    return DIMHookSysctl(name, namelen, oldp, oldlenp, newp, newlen,
                         DIMOriginalUnderscoreSysctl);
}

// ------------------------------------------------------------
// UNAME
// ------------------------------------------------------------

static int DIMHookUname(struct utsname *info) {
    if (!DIMOriginalUname) {
        errno = ENOSYS;
        return -1;
    }

    int result = DIMOriginalUname(info);

    if (result != 0 || !info) return result;

    pthread_mutex_lock(&gLock);
    DIMEnsureProfileLocked();

    if (gProfile.configActive)
        strlcpy(info->machine, gProfile.machine, sizeof(info->machine));

    if (gProfile.iosActive) {
        strlcpy(info->release, gProfile.darwin, sizeof(info->release));

        if (gProfile.kernelVersion[0])
            strlcpy(info->version, gProfile.kernelVersion, sizeof(info->version));
    }

    pthread_mutex_unlock(&gLock);

    return 0;
}

// ------------------------------------------------------------
// UIDEVICE / NSPROCESSINFO
// ------------------------------------------------------------

// UIDevice.model в настоящей системе — это "iPhone" / "iPad", а не маркетинговое
// название. Приложения часто сравнивают именно с этими строками.
static NSString *DIMDeviceFamily(id self, SEL selector, NSString *(*fallback)(id, SEL)) {
    NSString *value = nil;

    pthread_mutex_lock(&gLock);
    DIMEnsureProfileLocked();

    if (gProfile.configActive && gProfile.family[0]) {
        value = [NSString stringWithUTF8String:gProfile.family];
    }

    pthread_mutex_unlock(&gLock);

    if (value) return value;

    return fallback ? fallback(self, selector) : @"iPhone";
}

static NSString *DIMDeviceModel(id self, SEL selector) {
    return DIMDeviceFamily(self, selector, DIMOriginalDeviceModel);
}

static NSString *DIMDeviceLocalizedModel(id self, SEL selector) {
    return DIMDeviceFamily(self, selector, DIMOriginalDeviceLocalizedModel);
}

static NSString *DIMDeviceSystemVersion(id self, SEL selector) {
    NSString *value = nil;

    pthread_mutex_lock(&gLock);
    DIMEnsureProfileLocked();

    if (gProfile.iosActive && gProfile.version[0]) {
        value = [NSString stringWithUTF8String:gProfile.version];
    }

    pthread_mutex_unlock(&gLock);

    if (value) return value;

    return DIMOriginalDeviceSystemVersion
        ? DIMOriginalDeviceSystemVersion(self, selector) : @"";
}

static NSOperatingSystemVersion DIMParseSystemVersion(const char *string) {
    NSOperatingSystemVersion version = {0, 0, 0};

    if (!string || !*string) return version;

    long parts[3] = {0, 0, 0};
    int index = 0;
    const char *cursor = string;

    while (*cursor && index < 3) {
        if (*cursor >= '0' && *cursor <= '9') {
            parts[index] = parts[index] * 10 + (*cursor - '0');
        } else if (*cursor == '.') {
            index++;
        } else {
            break;
        }

        cursor++;
    }

    version.majorVersion = parts[0];
    version.minorVersion = parts[1];
    version.patchVersion = parts[2];

    return version;
}

static NSOperatingSystemVersion DIMOperatingSystemVersion(id self, SEL selector) {
    BOOL active = NO;
    NSOperatingSystemVersion spoofed = {0, 0, 0};

    pthread_mutex_lock(&gLock);
    DIMEnsureProfileLocked();

    if (gProfile.iosActive && gProfile.version[0]) {
        spoofed = DIMParseSystemVersion(gProfile.version);
        active = YES;
    }

    pthread_mutex_unlock(&gLock);

    if (active) return spoofed;

    if (DIMOriginalOperatingSystemVersion) {
        return DIMOriginalOperatingSystemVersion(self, selector);
    }

    NSOperatingSystemVersion empty = {0, 0, 0};
    return empty;
}

static NSString *DIMOperatingSystemVersionString(id self, SEL selector) {
    NSString *value = nil;

    pthread_mutex_lock(&gLock);
    DIMEnsureProfileLocked();

    if (gProfile.iosActive && gProfile.version[0]) {
        value = [NSString stringWithFormat:@"Version %s (Build %s)",
                 gProfile.version, gProfile.build];
    }

    pthread_mutex_unlock(&gLock);

    if (value) return value;

    return DIMOriginalOperatingSystemVersionString
        ? DIMOriginalOperatingSystemVersionString(self, selector) : @"";
}

static BOOL DIMIsOperatingSystemAtLeastVersion(
    id self, SEL selector, NSOperatingSystemVersion requested
) {
    BOOL active = NO;
    NSOperatingSystemVersion current = {0, 0, 0};

    pthread_mutex_lock(&gLock);
    DIMEnsureProfileLocked();

    if (gProfile.iosActive && gProfile.version[0]) {
        current = DIMParseSystemVersion(gProfile.version);
        active = YES;
    }

    pthread_mutex_unlock(&gLock);

    if (!active) {
        return DIMOriginalIsOperatingSystemAtLeastVersion
            ? DIMOriginalIsOperatingSystemAtLeastVersion(self, selector, requested)
            : NO;
    }

    if (current.majorVersion != requested.majorVersion)
        return current.majorVersion > requested.majorVersion;

    if (current.minorVersion != requested.minorVersion)
        return current.minorVersion > requested.minorVersion;

    return current.patchVersion >= requested.patchVersion;
}

// ------------------------------------------------------------
// MOBILEGESTALT
// ------------------------------------------------------------
//
// Через MobileGestalt модель читают App Store приложения (AIDA64, банки, антифрод).
// Без этих хуков hw.machine подменяется, а MGGetStringAnswer("ProductType")
// продолжает отдавать настоящий iPhone8,1.

typedef enum {
    DIMGMProductType = 0,
    DIMGMHWModel,
    DIMGMDeviceClass,
    DIMGMProductVersion,
    DIMGMBuildVersion,
    DIMGMCount
} DIMGMIndex;

static const char *DIMQuestionNames[DIMGMCount] = {
    "ProductType",
    "HWModel",
    "DeviceClass",
    "ProductVersion",
    "BuildVersion"
};

static CFStringRef gMGQuestions[DIMGMCount];
static CFStringRef gMGAnswers[DIMGMCount];
static char gMGAnswerCache[DIMGMCount][64];

static const char *DIMValueForMGIndexLocked(DIMGMIndex index) {
    switch (index) {
        case DIMGMProductType:
            return gProfile.configActive ? gProfile.machine : NULL;
        case DIMGMHWModel:
            return gProfile.configActive ? gProfile.board : NULL;
        case DIMGMDeviceClass:
            return gProfile.configActive ? gProfile.family : NULL;
        case DIMGMProductVersion:
            return gProfile.iosActive ? gProfile.version : NULL;
        case DIMGMBuildVersion:
            return gProfile.iosActive ? gProfile.build : NULL;
        default:
            return NULL;
    }
}

static void DIMRefreshMGCacheLocked(void) {
    for (int i = 0; i < DIMGMCount; i++) {
        if (!gMGQuestions[i]) {
            gMGQuestions[i] =
                CFStringCreateWithCString(NULL, DIMQuestionNames[i],
                                          kCFStringEncodingUTF8);
        }

        const char *value = DIMValueForMGIndexLocked((DIMGMIndex)i);
        const char *desired = value ? value : "";

        if (strcmp(gMGAnswerCache[i], desired) == 0) continue;

        strlcpy(gMGAnswerCache[i], desired, sizeof(gMGAnswerCache[i]));

        // Старое значение намеренно не освобождаем: его могли уже отдать наружу.
        gMGAnswers[i] = desired[0]
            ? CFStringCreateWithCString(NULL, desired, kCFStringEncodingUTF8)
            : NULL;
    }
}

static CFStringRef DIMCachedMGAnswerLocked(CFStringRef question) {
    if (!question) return NULL;

    for (int i = 0; i < DIMGMCount; i++) {
        CFStringRef key = gMGQuestions[i];

        if (key && CFEqual(question, key)) return gMGAnswers[i];
    }

    return NULL;
}

static CFTypeRef DIMHookMGCopyAnswer(CFStringRef question) {
    CFStringRef answer = NULL;

    pthread_mutex_lock(&gLock);
    DIMEnsureProfileLocked();
    answer = DIMCachedMGAnswerLocked(question);
    pthread_mutex_unlock(&gLock);

    // MGCopyAnswer отдаёт объект во владение вызывающему (+1).
    if (answer) return CFRetain(answer);

    return DIMOriginalMGCopyAnswer ? DIMOriginalMGCopyAnswer(question) : NULL;
}

static CFStringRef DIMHookMGStringAnswer(CFStringRef question) {
    CFStringRef answer = NULL;

    pthread_mutex_lock(&gLock);
    DIMEnsureProfileLocked();
    answer = DIMCachedMGAnswerLocked(question);
    pthread_mutex_unlock(&gLock);

    // MGGetStringAnswer отдаёт объект без передачи владения (+0).
    if (answer) return answer;

    return DIMOriginalMGStringAnswer ? DIMOriginalMGStringAnswer(question) : NULL;
}

// ------------------------------------------------------------
// BEACON'Ы ДЛЯ CHECK
// ------------------------------------------------------------
//
// alive  — твик реально загрузился в процесс приложения.
// verify — хеш значений, которые приложение видит СЕЙЧАС (через те же хуки).

typedef struct {
    char name[192];
    int token;
} DIMBeaconSlot;

static DIMBeaconSlot gBeaconSlots[8];
static int gBeaconSlotCount = 0;

static int DIMTokenForNameLocked(const char *name) {
    for (int i = 0; i < gBeaconSlotCount; i++) {
        if (strcmp(gBeaconSlots[i].name, name) == 0) return gBeaconSlots[i].token;
    }

    if (gBeaconSlotCount >= 8) return 0;

    int token = 0;

    if (notify_register_check(name, &token) != NOTIFY_STATUS_OK) return 0;

    strlcpy(gBeaconSlots[gBeaconSlotCount].name, name,
            sizeof(gBeaconSlots[0].name));
    gBeaconSlots[gBeaconSlotCount].token = token;
    gBeaconSlotCount++;

    return token;
}

static uint64_t DIMObservedHash(void) {
    char machine[128] = {0};
    char build[64] = {0};
    char release[64] = {0};

    size_t size = sizeof(machine);
    sysctlbyname("hw.machine", machine, &size, NULL, 0);

    size = sizeof(build);
    sysctlbyname("kern.osversion", build, &size, NULL, 0);

    size = sizeof(release);
    sysctlbyname("kern.osrelease", release, &size, NULL, 0);

    struct utsname info;
    memset(&info, 0, sizeof(info));
    uname(&info);

    NSString *systemVersion = [UIDevice currentDevice].systemVersion ?: @"";

    NSString *signature =
        [NSString stringWithFormat:@"%s|%s|%s|%s|%@",
         machine, build, release, info.machine, systemVersion];

    return DIMFNV1a(signature.UTF8String);
}

static void DIMPublishBeacon(void) {
    if (!gBundleID[0]) return;

    char aliveName[192];
    char verifyName[192];

    snprintf(aliveName, sizeof(aliveName), "com.dim.alive.%s", gBundleID);
    snprintf(verifyName, sizeof(verifyName), "com.dim.verify.%s", gBundleID);

    uint64_t hash = DIMObservedHash();

    int aliveToken = 0;
    int verifyToken = 0;
    int lastToken = 0;

    pthread_mutex_lock(&gLock);
    aliveToken = DIMTokenForNameLocked(aliveName);
    verifyToken = DIMTokenForNameLocked(verifyName);
    lastToken = DIMTokenForNameLocked("com.dim.verify.last");
    pthread_mutex_unlock(&gLock);

    // Токены держим открытыми: иначе notifyd забудет состояние при выходе процесса.
    if (aliveToken) {
        notify_set_state(aliveToken, 1);
        notify_post(aliveName);
    }

    if (verifyToken) {
        notify_set_state(verifyToken, hash);
        notify_post(verifyName);
    }

    if (lastToken) {
        notify_set_state(lastToken, hash);
        notify_post("com.dim.verify.last");
    }

    NSLog(@"[DIM] beacon %@ machine=%s build=%s hash=%llu",
          [NSString stringWithUTF8String:gBundleID],
          gProfile.machine, gProfile.build,
          (unsigned long long)hash);
}

// ------------------------------------------------------------
// УСТАНОВКА ХУКОВ
// ------------------------------------------------------------

static void DIMInstallMobileGestaltHooks(void) {
    void *copyAnswer = dlsym(RTLD_DEFAULT, "MGCopyAnswer");
    void *stringAnswer = dlsym(RTLD_DEFAULT, "MGGetStringAnswer");

    if (!copyAnswer || !stringAnswer) {
        // Некоторые процессы не линкуют libMobileGestalt до первого запроса.
        void *handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);

        if (handle) {
            if (!copyAnswer) copyAnswer = dlsym(handle, "MGCopyAnswer");
            if (!stringAnswer) stringAnswer = dlsym(handle, "MGGetStringAnswer");
        }
    }

    if (copyAnswer) {
        MSHookFunction(copyAnswer, (void *)DIMHookMGCopyAnswer,
                       (void **)&DIMOriginalMGCopyAnswer);
    }

    if (stringAnswer) {
        MSHookFunction(stringAnswer, (void *)DIMHookMGStringAnswer,
                       (void **)&DIMOriginalMGStringAnswer);
    }
}

static void DIMInstallHooks(void) {
    static int installed = 0;

    if (installed) return;
    installed = 1;

    // Символы берём через dlsym: адрес &func в dylib может указывать на stub,
    // и тогда хук сработал бы только внутри твика, а не для всего процесса.
    void *sysctlByName = dlsym(RTLD_DEFAULT, "sysctlbyname");

    if (sysctlByName) {
        MSHookFunction(sysctlByName, (void *)DIMHookSysctlByName,
                       (void **)&DIMOriginalSysctlByName);
    }

    void *sysctlAddress = dlsym(RTLD_DEFAULT, "sysctl");

    if (sysctlAddress) {
        MSHookFunction(sysctlAddress, (void *)DIMTrampolineSysctl,
                       (void **)&DIMOriginalSysctl);
    }

    void *underscoreSysctl = dlsym(RTLD_DEFAULT, "__sysctl");

    if (underscoreSysctl) {
        MSHookFunction(underscoreSysctl, (void *)DIMTrampolineUnderscoreSysctl,
                       (void **)&DIMOriginalUnderscoreSysctl);
    }

    void *unameAddress = dlsym(RTLD_DEFAULT, "uname");

    if (unameAddress) {
        MSHookFunction(unameAddress, (void *)DIMHookUname,
                       (void **)&DIMOriginalUname);
    }

    Class deviceClass = objc_getClass("UIDevice");

    if (deviceClass) {
        MSHookMessageEx(deviceClass, @selector(model),
                        (IMP)DIMDeviceModel, (IMP *)&DIMOriginalDeviceModel);
        MSHookMessageEx(deviceClass, @selector(localizedModel),
                        (IMP)DIMDeviceLocalizedModel,
                        (IMP *)&DIMOriginalDeviceLocalizedModel);
        MSHookMessageEx(deviceClass, @selector(systemVersion),
                        (IMP)DIMDeviceSystemVersion,
                        (IMP *)&DIMOriginalDeviceSystemVersion);
    }

    Class processInfoClass = objc_getClass("NSProcessInfo");

    if (processInfoClass) {
        MSHookMessageEx(processInfoClass, @selector(operatingSystemVersion),
                        (IMP)DIMOperatingSystemVersion,
                        (IMP *)&DIMOriginalOperatingSystemVersion);

        MSHookMessageEx(processInfoClass, @selector(operatingSystemVersionString),
                        (IMP)DIMOperatingSystemVersionString,
                        (IMP *)&DIMOriginalOperatingSystemVersionString);

        MSHookMessageEx(processInfoClass,
                        @selector(isOperatingSystemAtLeastVersion:),
                        (IMP)DIMIsOperatingSystemAtLeastVersion,
                        (IMP *)&DIMOriginalIsOperatingSystemAtLeastVersion);
    }

    DIMInstallMobileGestaltHooks();
}

static void DIMSetupObservers(void) {
    static int configured = 0;

    if (configured) return;
    configured = 1;

    int token = 0;

    // Применение профиля в настройках -> приложение сразу перечитывает конфиг.
    notify_register_dispatch(DIM_RUNTIME_CHANGED, &token,
                             dispatch_get_main_queue(), ^(int registered) {
        DIMMarkDirty();
        DIMPublishBeacon();
    });

    // Приложение вернулось из фона: обновляем профиль и beacon.
    [[NSNotificationCenter defaultCenter]
        addObserverForName:@"UIApplicationDidBecomeActiveNotification"
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        DIMMarkDirty();
        DIMPublishBeacon();
    }];

    // Первые секунды после запуска: часть приложений читает модель ещё до того,
    // как UI успел появиться, поэтому обновляем состояние повторно.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        DIMMarkDirty();
        DIMPublishBeacon();
    });
}

// ------------------------------------------------------------
// INITIALIZATION
// ------------------------------------------------------------

__attribute__((constructor))
static void DIMInitialize(void) {
    @autoreleasepool {
        DIMInitLock();

        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];

        if (!bundleID.length) return;

        strlcpy(gBundleID, bundleID.UTF8String, sizeof(gBundleID));

        // Эти процессы не трогаем: иначе сломаем сам менеджер и систему.
        if ([bundleID isEqualToString:@"com.apple.springboard"] ||
            [bundleID isEqualToString:@"com.apple.Preferences"]) {
            return;
        }

        // Хуки ставим всегда: если профиль применят позже, приложению не нужен
        // перезапуск — значения подставятся при следующем обращении.
        DIMInstallHooks();

        DIMMarkDirty();
        DIMPublishBeacon();
        DIMSetupObservers();
    }
}
