//
//  ZBSettingsSelectionTableViewController.m
//  Zebra
//
//  Created by Louis on 02/11/2019.
//  Copyright © 2019 Wilson Styres. All rights reserved.
//

#import "ZBSettingsSelectionTableViewController.h"
#import "ZBSettings.h"
#import "ZBDevice.h"
#import "UIColor+GlobalColors.h"

@interface ZBSettingsSelectionTableViewController () {
    NSString *selectedOption;
    NSIndexPath *selectedIndex;
    SEL settingsGetter;
    SEL settingsSetter;
    NSInteger selectedValue;
}
@end

@implementation ZBSettingsSelectionTableViewController

@synthesize settingChanged;

@synthesize settingsKey;
@synthesize footerText;
@synthesize options;

- (id)initWithOptions:(NSArray *)selectionOptions getter:(SEL)getter setter:(SEL)setter settingChangedCallback:(void (^)(void))callback {
    self = [super initWithStyle:UITableViewStyleGrouped];
    
    if (self) {
        options = selectionOptions;
        
        settingsGetter = getter;
        settingsSetter = setter;
        
        settingChanged = callback;
    }
    
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = NSLocalizedString(self.title, @"");

    selectedValue = (NSInteger)[ZBSettings performSelector:settingsGetter];

    NSIndexPath *selectedIndex = [NSIndexPath indexPathForRow:selectedValue inSection:0];
    NSString *selectedOption = selectedValue < 0 ? nil : options[selectedValue];
    
    self->selectedIndex = selectedIndex;
    self->selectedOption = selectedOption;
    
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"settingsOptionCell"];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    
    if (selectedIndex.row != selectedValue && settingChanged) self.settingChanged();
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return options.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"settingsOptionCell" forIndexPath:indexPath];
    
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.text = NSLocalizedString(options[indexPath.row], @"");
    cell.tintColor = [UIColor accentColor];
    cell.textLabel.textColor = [UIColor primaryTextColor];
    
    cell.accessoryType = [selectedIndex isEqual:indexPath] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;

    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NSMutableArray *localize = [NSMutableArray new];
    for (NSString *string in footerText) {
        [localize addObject:NSLocalizedString(string, @"")];
    }
    return [localize componentsJoinedByString:@"\n\n"];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    if (![selectedIndex isEqual:indexPath]) {
        self->selectedIndex = indexPath;
        self->selectedOption = options[indexPath.row];
        
        [ZBSettings performSelector:settingsSetter withObject:@(selectedIndex.row)];
        
        [[self tableView] reloadData];
    }
}

@end
