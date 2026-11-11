
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "DIMRuntime.h"

static NSString * const DIMDomain = @"com.dim.manager";

@interface DIMRootListController : PSListController
@end

@implementation DIMRootListController

- (NSUserDefaults *)prefs {
    return [[NSUserDefaults alloc] initWithSuiteName:DIMDomain];
}

- (NSString *)labelForSpecifier:(PSSpecifier *)specifier {
    NSString *label = [specifier propertyForKey:@"label"];
    if (![label isKindOfClass:NSString.class] || !label.length) {
        label = [specifier name];
    }
    return [label isKindOfClass:NSString.class] ? label : @"";
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;

    NSArray *all =
        [self loadSpecifiersFromPlistName:@"Root" target:self];

    NSUserDefaults *defaults = [self prefs];

    BOOL dimEnabled = YES;
    if ([defaults objectForKey:@"Enabled"]) {
        dimEnabled = [defaults boolForKey:@"Enabled"];
    }

    BOOL deviceEnabled = [defaults boolForKey:@"DeviceEnabled"];

    NSMutableArray *filtered = [NSMutableArray array];

    for (PSSpecifier *specifier in all) {
        NSString *key = [specifier propertyForKey:@"key"];
        NSString *label = [self labelForSpecifier:specifier];

        if ([key isEqualToString:@"Enabled"] ||
            [label isEqualToString:@"GENERAL"]) {
            [filtered addObject:specifier];
            continue;
        }

        if (!dimEnabled) continue;

        if ([label isEqualToString:@"DEVICE"] ||
            [label isEqualToString:@"Configure Device Identity"]) {
            if (deviceEnabled) {
                [filtered addObject:specifier];
            }
            continue;
        }

        [filtered addObject:specifier];
    }

    _specifiers = [filtered copy];
    return _specifiers;
}

- (void)setPreferenceValue:(id)value
                 specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];

    NSString *key = [specifier propertyForKey:@"key"];

    if (key.length && value) {
        [[self prefs] setObject:value forKey:key];
    }

    [[self prefs] synchronize];
    DIMWriteRuntime([self prefs]);

    _specifiers = nil;
    [self reloadSpecifiers];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    DIMWriteRuntime([self prefs]);

    _specifiers = nil;
    [self reloadSpecifiers];
}

@end
