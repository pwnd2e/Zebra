//
//  ZBFilterSettingsTableViewController.m
//  Zebra
//
//  Created by Wilson Styres on 3/12/20.
//  Copyright © 2020 Wilson Styres. All rights reserved.
//

@import SDWebImage;

#import "ZBFilterSettingsTableViewController.h"
#import "ZBSectionSelectorTableViewController.h"
#import "ZBAuthorSelectorTableViewController.h"

#import "ZBDatabaseManager.h"
#import "ZBPackageTableViewCell.h"
#import "ZBPackage.h"
#import "ZBSourceTableViewCell.h"
#import "ZBSource.h"
#import "ZBSourceSelectTableViewController.h"
#import "ZBSourceSectionsListTableViewController.h"

#import "UIColor+GlobalColors.h"
#import "UIImageView+Zebra.h"

@interface ZBFilterSettingsTableViewController () {
    NSMutableArray <ZBSource *> *sources;
    NSMutableDictionary <NSString *, NSArray *> *filteredSources;
    NSMutableArray <NSString *> *filteredSections;
    NSMutableDictionary <NSString *, NSString *> *blockedAuthors;
    NSMutableArray <ZBPackage *> *ignoredUpdates;
}
@end

@implementation ZBFilterSettingsTableViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self refreshTable];
    
    self.navigationItem.title = NSLocalizedString(@"Filters", @"");
    self.navigationItem.rightBarButtonItem = self.editButtonItem;
    
    [self.tableView registerNib:[UINib nibWithNibName:@"ZBSourceTableViewCell" bundle:nil] forCellReuseIdentifier:@"sourceTableViewCell"];
    [self.tableView registerNib:[UINib nibWithNibName:@"ZBPackageTableViewCell" bundle:nil] forCellReuseIdentifier:@"packageTableViewCell"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"filterCell"];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshTable];
}

- (void)refreshTable {
    filteredSections = [[ZBSettings filteredSections] mutableCopy];
    
    filteredSources = [[ZBSettings filteredSources] mutableCopy];
    NSArray *baseFilenames = [filteredSources allKeys];
    
    sources = [NSMutableArray new];
    NSMutableArray *outdatedFilteredSources = [NSMutableArray new];
    for (NSString *baseFilename in baseFilenames) {
        ZBSource *source = [ZBSource sourceFromBaseFilename:baseFilename];
        if (!source) {
            // This source has been removed after filtering sections in it, we need to remove this baseFilename
            [outdatedFilteredSources addObject:baseFilename];
            continue;
        };
        [sources addObject:source];
    }
    [sources sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"label" ascending:YES selector:@selector(localizedStandardCompare:)]]];
    if ([outdatedFilteredSources count]) {
        [filteredSources removeObjectsForKeys:outdatedFilteredSources];
        [ZBSettings setFilteredSources:filteredSources];
    }
    
    blockedAuthors = [[ZBSettings blockedAuthors] mutableCopy];
    
    ignoredUpdates = [[ZBDatabaseManager sharedInstance] packagesWithIgnoredUpdates];
    
    [self.tableView reloadData];
}

#pragma mark - Table View Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return ignoredUpdates.count ? 5 : 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0:
            return 1;
        case 1:
            return filteredSections.count + 1;
        case 2:
            return filteredSources.count + 1;
        case 3:
            return blockedAuthors.count + 1;
        case 4:
            return ignoredUpdates.count;
        default:
            return 1;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case 0: {
            static NSString *cellIdentifier = @"settingsCell";
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
            if (cell == nil) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellIdentifier];
            }
            cell.backgroundColor = [UIColor cellBackgroundColor];
            cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
            UISwitch *enableSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
            enableSwitch.on = ![ZBSettings filterIncompatibleArchitectures];
            [enableSwitch addTarget:self action:@selector(toggleIncompatibleArchitectures:) forControlEvents:UIControlEventValueChanged];
            [enableSwitch setOnTintColor:[UIColor accentColor]];
            cell.accessoryView = enableSwitch;
            cell.textLabel.text = NSLocalizedString(@"Show Incompatible Packages", @"");
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.textColor = [UIColor primaryTextColor];
            return cell;
        }
        case 1: {
            if (indexPath.row < filteredSections.count) {
                UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"filterCell" forIndexPath:indexPath];
                cell.textLabel.text = filteredSections[indexPath.row];
                cell.textLabel.textColor = [UIColor primaryTextColor];

                cell.imageView.image = [ZBSource imageForSection:filteredSections[indexPath.row]];
                [cell.imageView resize:CGSizeMake(32, 32) applyRadius:YES];
                
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                
                return cell;
            }
            break;
        }
        case 2: {
            if (indexPath.row < filteredSources.count) {
                ZBSourceTableViewCell *sourceCell = [tableView dequeueReusableCellWithIdentifier:@"sourceTableViewCell" forIndexPath:indexPath];
                ZBSource *source = sources[indexPath.row];
                
                sourceCell.sourceLabel.text = [source label];
                sourceCell.sourceLabel.textColor = [UIColor primaryTextColor];
                
                unsigned long numberOfSections = (unsigned long)[filteredSources[[source baseFilename]] count];
                sourceCell.urlLabel.text = numberOfSections == 1 ? NSLocalizedString(@"1 Section Hidden", @"") : [NSString stringWithFormat:NSLocalizedString(@"%lu Sections Hidden", @""), numberOfSections];
                sourceCell.urlLabel.textColor = [UIColor secondaryTextColor];
                
                [sourceCell.iconImageView sd_setImageWithURL:[source iconURL] placeholderImage:[UIImage imageNamed:@"Unknown"]];
                
                return sourceCell;
            }
            break;
        }
        case 3: {
            if (indexPath.row < blockedAuthors.count) {
                UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"authorCell"];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                
                cell.textLabel.text = [blockedAuthors objectForKey:[blockedAuthors allKeys][indexPath.row]];
                cell.textLabel.textColor = [UIColor primaryTextColor];
                
                NSArray *aliases = [self listAllAuthorsFromMail:indexPath];
                if (aliases.count > 1) cell.accessoryType = UITableViewCellAccessoryDetailButton;
                
                NSString *email = [blockedAuthors allKeys][indexPath.row];
                if (![email isEqualToString:cell.textLabel.text]) {
                    cell.detailTextLabel.text = email;
                    cell.detailTextLabel.textColor = [UIColor secondaryTextColor];
                }
                
                cell.tintColor = [UIColor accentColor];
                return cell;
            }
            break;
        }
        case 4: {
            if (indexPath.row < ignoredUpdates.count) {
                ZBPackageTableViewCell *packageCell = [tableView dequeueReusableCellWithIdentifier:@"packageTableViewCell" forIndexPath:indexPath];
                ZBPackage *package = ignoredUpdates[indexPath.row];
                
                [packageCell updateData:package];
                [packageCell setColors];
                
                return packageCell;
            }
            break;
        }
    }
    
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"filterCell" forIndexPath:indexPath];
    cell.textLabel.text = NSLocalizedString(@"Add Filter", @"");
    cell.textLabel.textColor = [UIColor accentColor] ?: [UIColor systemBlueColor];
    cell.imageView.image = nil;
    
    return cell;
}

- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 3) {
        NSMutableString *message = [NSLocalizedString(@"This author also goes by the following names:", @"") mutableCopy];
        
        NSString *email = [blockedAuthors allKeys][indexPath.row];
        NSString *name = blockedAuthors[email];
        NSArray *aliases = [self listAllAuthorsFromMail:indexPath];
        for (NSArray *alias in aliases) {
            if (![alias[0] isEqual:name]) [message appendFormat:@"\n%@", alias[0]];
        }
        
        UIAlertController *aliasList = [UIAlertController alertControllerWithTitle:blockedAuthors[email] message:message preferredStyle:UIAlertControllerStyleAlert];
        
        UIAlertAction *ok = [UIAlertAction actionWithTitle:NSLocalizedString(@"OK", @"") style:UIAlertActionStyleDefault handler:nil];
        [aliasList addAction:ok];
        
        [self presentViewController:aliasList animated:YES completion:nil];
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0:
            return NSLocalizedString(@"Compatibility", @"");
        case 1:
            return NSLocalizedString(@"Sections", @"");
        case 2:
            return NSLocalizedString(@"Sources", @"");
        case 3:
            return NSLocalizedString(@"Authors", @"");
        case 4:
            return NSLocalizedString(@"Updates", @"");
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case 0:
            return NSLocalizedString(@"Display all packages, even if they can’t be installed on the current jailbreak.", @"");
        case 1:
            return NSLocalizedString(@"Hide packages in these sections.", @"");
        case 2:
            return NSLocalizedString(@"Hide packages in these sections from specific sources.", @"");
        case 3:
            return NSLocalizedString(@"Hide packages from these authors.", @"");
        case 4:
            return NSLocalizedString(@"Hide future updates from these packages.", @"");
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    NSUInteger rowCount = [tableView numberOfRowsInSection:indexPath.section];
    BOOL lastRow = indexPath.row == rowCount - 1;
    
    switch (indexPath.section) {
        case 0:
            break;
        case 1: {
            if (lastRow) {
                ZBSectionSelectorTableViewController *sectionPicker = [[ZBSectionSelectorTableViewController alloc] init];
                [sectionPicker setSectionsSelected:^(NSArray * _Nonnull selectedSections) {
                    [self->filteredSections addObjectsFromArray:selectedSections];
                    [ZBSettings setFilteredSections:self->filteredSections];
                    
                    [self refreshTable];
                    
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"ZBDatabaseCompletedUpdate" object:nil];
                }];
                
                UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:sectionPicker];
                
                [self presentViewController:nav animated:YES completion:nil];
            }
            break;
        }
        case 2: {
            if (!lastRow) {
                ZBSourceSectionsListTableViewController *sections = [[ZBSourceSectionsListTableViewController alloc] initWithSource:sources[indexPath.row]];
                
                [[self navigationController] pushViewController:sections animated:YES];
            }
            else {
                ZBSourceSelectTableViewController *sourcePicker = [[ZBSourceSelectTableViewController alloc] initWithSelectionType:ZBSourceSelectionTypeNormal limit:1];
                [sourcePicker setSourcesSelected:^(NSArray<ZBSource *> * _Nonnull selectedSources) {
                    NSMutableDictionary *sources = [self->filteredSources mutableCopy];
                    
                    for (ZBSource *source in selectedSources) {
                        [sources setObject:@[] forKey:[source baseFilename]];
                    }
                    
                    [ZBSettings setFilteredSources:sources];
                    [self refreshTable];
                }];
                
                UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:sourcePicker];
                
                [self presentViewController:nav animated:YES completion:nil];
            }
            break;
        }
        case 3:
            if (lastRow) {
                ZBAuthorSelectorTableViewController *authorPicker = [[ZBAuthorSelectorTableViewController alloc] init];
                [authorPicker setAuthorsSelected:^(NSDictionary * _Nonnull selectedAuthors) {
                    [self->blockedAuthors addEntriesFromDictionary:selectedAuthors];
                    [ZBSettings setBlockedAuthors:self->blockedAuthors];
                    
                    [self refreshTable];
                    
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"ZBDatabaseCompletedUpdate" object:nil];
                }];
                
                UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:authorPicker];
                
                [self presentViewController:nav animated:YES completion:nil];
            }
            break;
        case 4:
            break;
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 4) { // Ignored Packages
        return YES;
    }
    else {
        NSUInteger rowCount = [tableView numberOfRowsInSection:indexPath.section];
        return indexPath.row != rowCount - 1;
    }
}

- (NSArray <UITableViewRowAction *> *)tableView:(UITableView *)tableView editActionsForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case 1:
        case 2:
        case 3: {
            UITableViewRowAction *deleteFilterAction = [UITableViewRowAction rowActionWithStyle:UITableViewRowActionStyleDestructive title:NSLocalizedString(@"Delete", @"") handler:^(UITableViewRowAction * _Nonnull action, NSIndexPath * _Nonnull indexPath) {
                switch (indexPath.section) {
                    case 1: {
                        NSString *section = self->filteredSections[indexPath.row];
                        [self->filteredSections removeObject:section];
                        
                        [ZBSettings setFilteredSections:self->filteredSections];
                        [tableView reloadSections:[NSIndexSet indexSetWithIndex:indexPath.section] withRowAnimation:UITableViewRowAnimationAutomatic];
                        break;
                    }
                    case 2: {
                        ZBSource *source = self->sources[indexPath.row];
                        [self->filteredSources removeObjectForKey:[source baseFilename]];
                        [self->sources removeObjectAtIndex:indexPath.row];
                        
                        [ZBSettings setFilteredSources:self->filteredSources];
                        [tableView reloadSections:[NSIndexSet indexSetWithIndex:indexPath.section] withRowAnimation:UITableViewRowAnimationAutomatic];
                        break;
                    }
                    case 3: {
                        NSString *author = [self->blockedAuthors allKeys][indexPath.row];
                        [self->blockedAuthors removeObjectForKey:author];

                        [ZBSettings setBlockedAuthors:self->blockedAuthors];
                        [tableView reloadSections:[NSIndexSet indexSetWithIndex:indexPath.section] withRowAnimation:UITableViewRowAnimationAutomatic];
                        break;
                    }
                }
            }];
            [deleteFilterAction setBackgroundColor:[UIColor systemRedColor]];
            
            return @[deleteFilterAction];
        }
        case 4: {
            UITableViewRowAction *deleteFilterAction = [UITableViewRowAction rowActionWithStyle:UITableViewRowActionStyleDestructive title:NSLocalizedString(@"Show Updates", @"") handler:^(UITableViewRowAction * _Nonnull action, NSIndexPath * _Nonnull indexPath) {
                ZBPackage *package = self->ignoredUpdates[indexPath.row];
                [self->ignoredUpdates removeObject:package];
                
                [package setIgnoreUpdates:NO];
                
                if (self->ignoredUpdates.count) {
                    [tableView reloadSections:[NSIndexSet indexSetWithIndex:indexPath.section] withRowAnimation:UITableViewRowAnimationAutomatic];
                }
                else {
                    [tableView deleteSections:[NSIndexSet indexSetWithIndex:indexPath.section] withRowAnimation:UITableViewRowAnimationAutomatic];
                }
            }];
            [deleteFilterAction setBackgroundColor:[UIColor systemGreenColor]];
            
            return @[deleteFilterAction];
        }
        default:
            return nil;
    }
}

- (NSArray *)listAllAuthorsFromMail:(NSIndexPath *)indexPath {
    ZBDatabaseManager *database = [ZBDatabaseManager sharedInstance];
    NSString *email = [blockedAuthors allKeys][indexPath.row];
    NSArray *aliases = [database searchForAuthorFromEmail:email fullSearch:YES];
    
    return aliases;
}

- (void)toggleIncompatibleArchitectures:(UISwitch *)sender {
    [ZBSettings setFilterIncompatibleArchitectures:!sender.isOn];
}

@end
