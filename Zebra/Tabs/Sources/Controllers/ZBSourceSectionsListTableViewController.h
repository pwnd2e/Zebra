//
//  ZBSourceSectionsListTableViewController.h
//  Zebra
//
//  Created by Wilson Styres on 3/24/19.
//  Copyright © 2019 Wilson Styres. All rights reserved.
//

#import "ZBTableViewController.h"

@class ZBSource;
@class ZBDatabaseManager;

NS_ASSUME_NONNULL_BEGIN

@interface ZBSourceSectionsListTableViewController : ZBTableViewController <UICollectionViewDelegate, UICollectionViewDataSource>
@property (nonatomic, strong) ZBSource *source;
- (id)initWithSource:(ZBSource *)source;
- (void)accountButtonPressed:(id)sender;
@end

NS_ASSUME_NONNULL_END
