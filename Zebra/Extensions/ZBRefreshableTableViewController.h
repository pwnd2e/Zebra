//
//  ZBRefreshableTableViewController.h
//  Zebra
//
//  Created by Thatchapon Unprasert on 17/6/2019
//  Copyright © 2019 Wilson Styres. All rights reserved.
//

#import "ZBTableViewController.h"

#import "ZBDatabaseDelegate.h"
#import "ZBDatabaseManager.h"

NS_ASSUME_NONNULL_BEGIN

@interface ZBRefreshableTableViewController : ZBTableViewController <ZBDatabaseDelegate>
@property (nonatomic, strong) ZBDatabaseManager *databaseManager;
- (void)setSourceRefreshIndicatorVisible:(BOOL)visible;
- (void)didEndRefreshing;
- (void)layoutNavigationButtons;
- (void)layoutNavigationButtonsNormal;
- (void)layoutNavigationButtonsRefreshing;
@end

NS_ASSUME_NONNULL_END
