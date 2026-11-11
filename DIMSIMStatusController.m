
#import "DIMSIMStatusController.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import "DIMRuntime.h"

static NSString * const DIMSIMDomain = @"com.dim.manager";

@implementation DIMSIMStatusController

- (NSUserDefaults *)prefs {
    return [[NSUserDefaults alloc] initWithSuiteName:DIMSIMDomain];
}

- (PSSpecifier *)group:(NSString *)name {
    return [PSSpecifier preferenceSpecifierNamed:name
        target:self
        set:nil
        get:nil
        detail:nil
        cell:PSGroupCell
        edit:nil];
}

- (PSSpecifier *)switchSpec:(NSString *)name key:(NSString *)key {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name
        target:self
        set:@selector(setValue:specifier:)
        get:@selector(readValue:)
        detail:nil
        cell:PSSwitchCell
        edit:nil];

    [s setProperty:key forKey:@"key"];
    [s setProperty:DIMSIMDomain forKey:@"defaults"];
    [s setProperty:@NO forKey:@"default"];
    return s;
}

- (PSSpecifier *)textSpec:(NSString *)name key:(NSString *)key {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name
        target:self
        set:@selector(setValue:specifier:)
        get:@selector(readValue:)
        detail:nil
        cell:PSEditTextCell
        edit:nil];

    [s setProperty:key forKey:@"key"];
    [s setProperty:DIMSIMDomain forKey:@"defaults"];
    return s;
}

- (PSSpecifier *)listSpec:(NSString *)name
                      key:(NSString *)key
                   values:(NSArray *)values
                   titles:(NSArray *)titles {

    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name
        target:self
        set:@selector(setValue:specifier:)
        get:@selector(readValue:)
        detail:nil
        cell:PSListItemCell
        edit:nil];

    [s setProperty:key forKey:@"key"];
    [s setProperty:DIMSIMDomain forKey:@"defaults"];
    [s setProperty:values forKey:@"values"];
    [s setProperty:titles forKey:@"titles"];
    return s;
}

- (id)readValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    return [[self prefs] objectForKey:key];
}

- (void)setValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];

    if (key.length && value) {
        [[self prefs] setObject:value forKey:key];
    }

    [[self prefs] synchronize];
    DIMWriteRuntime([self prefs]);
    [self reloadSpecifiers];
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;

    NSMutableArray *items = [NSMutableArray array];

    [items addObject:[self group:@"SIM STATUS"]];

    [items addObject:
        [self switchSpec:@"Enable SIM Spoofing"
                     key:DIM_SIM_ENABLED_KEY]];

    [items addObject:[self group:@"SIGNAL"]];

    [items addObject:
        [self listSpec:@"Signal Mode"
                   key:DIM_SIM_MODE_KEY
                values:@[@"Static", @"Dynamic"]
                titles:@[@"Static", @"Dynamic"]]];

    [items addObject:
        [self listSpec:@"Signal Strength"
                   key:DIM_SIM_STRENGTH_KEY
                values:@[@1, @2, @3, @4]
                titles:@[@"1 Bar", @"2 Bars", @"3 Bars", @"4 Bars"]]];

    [items addObject:[self group:@"CARRIER"]];

    [items addObject:
        [self textSpec:@"Operator Name"
                   key:DIM_SIM_CARRIER_KEY]];

    [items addObject:
        [self textSpec:@"Country"
                   key:DIM_SIM_COUNTRY_KEY]];

    [items addObject:[self group:@"INFORMATION"]];

    PSSpecifier *info = [PSSpecifier preferenceSpecifierNamed:
        @"SIM spoofing only changes the visual status bar. It does not create a real SIM or cellular connection."
        target:nil set:nil get:nil detail:nil
        cell:PSStaticTextCell edit:nil];

    [items addObject:info];

    _specifiers = [items copy];
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    DIMWriteRuntime([self prefs]);
}

@end
