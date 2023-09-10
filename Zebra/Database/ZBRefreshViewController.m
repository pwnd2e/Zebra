//
//  ZBRefreshViewController.m
//  Zebra
//
//  Created by Wilson Styres on 11/30/18.
//  Copyright © 2018 Wilson Styres. All rights reserved.
//

#import "ZBRefreshViewController.h"

#import "ZBTabBarController.h"
#import "ZBDevice.h"
#import "ZBAppDelegate.h"
#import "UIFont+Zebra.h"
#import "ZBDatabaseManager.h"
#import "ZBDownloadManager.h"
#import "ZBThemeManager.h"
#import "ZBSourceManager.h"
#import "parsel.h"

typedef enum {
    ZBStateCancel = 0,
    ZBStateDone
} ZBRefreshButtonState;

@interface ZBRefreshViewController () {
    ZBDatabaseManager *databaseManager;
    BOOL hadAProblem;
    ZBRefreshButtonState buttonState;
    NSMutableArray *imaginarySources;
}
@property (strong, nonatomic) IBOutlet UIButton *completeOrCancelButton;
@property (strong, nonatomic) IBOutlet UITextView *consoleView;
@end

@implementation ZBRefreshViewController

@synthesize delegate;
@synthesize messages;
@synthesize completeOrCancelButton;
@synthesize consoleView;

#pragma mark - Initializers

- (id)init {
    UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"Main" bundle:nil];
    self = [super init];
    self = [storyboard instantiateViewControllerWithIdentifier:@"refreshController"];
    
    if (self) {
        self.messages = NULL;
        self.dropTables = NO;
        self.baseSources = NULL;
    }
    
    return self;
}

- (id)initWithMessages:(NSArray *)messages {
    self = [self init];
    
    if (self) {
        self.messages = messages;
    }
    
    return self;
}

- (id)initWithDropTables:(BOOL)dropTables {
    self = [self init];
    
    if (self) {
        self.dropTables = dropTables;
    }
    
    return self;
}

- (id)initWithBaseSources:(NSSet<ZBBaseSource *> *)baseSources delegate:(id <ZBSourceVerificationDelegate>)delegate {
    self = [self init];
    
    if (self) {
        NSMutableSet *validSources = [NSMutableSet new];
        
        for (ZBBaseSource *source in baseSources) {
            if (source.verificationStatus == ZBSourceExists) {
                [validSources addObject:source];
            }
            else {
                if (!imaginarySources) imaginarySources = [NSMutableArray new];
                [imaginarySources addObject:source];
            }
        }
        
        self.baseSources = validSources;
        self.delegate = delegate;
    }
    
    return self;
}

- (id)initWithMessages:(NSArray *)messages dropTables:(BOOL)dropTables {
    self = [self init];
    
    if (self) {
        self.messages = messages;
        self.dropTables = dropTables;
    }
    
    return self;
}

- (id)initWithMessages:(NSArray *)messages baseSources:(NSSet <ZBBaseSource *> *)baseSources {
    self = [self init];
    
    if (self) {
        self.messages = messages;
        self.baseSources = baseSources;
    }
    
    return self;
}

- (id)initWithDropTables:(BOOL)dropTables baseSources:(NSSet <ZBBaseSource *> *)baseSources {
    self = [self init];
    
    if (self) {
        self.dropTables = dropTables;
        self.baseSources = baseSources;
    }
    
    return self;
}

- (id)initWithMessages:(NSArray *)messages dropTables:(BOOL)dropTables baseSources:(NSSet <ZBBaseSource *> *)baseSources {
    self = [self init];
    
    if (self) {
        self.messages = messages;
        self.dropTables = dropTables;
        self.baseSources = baseSources;
    }
    
    return self;
}

#pragma mark - View Controller Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    if (_dropTables) {
        [self setCompleteOrCancelButtonHidden:YES];
    } else {
        [self updateCompleteOrCancelButtonText:NSLocalizedString(@"Cancel", @"")];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(disableCancelButton) name:@"disableCancelRefresh" object:nil];
    [self.view setBackgroundColor:[UIColor blackColor]];
    [consoleView setBackgroundColor:[UIColor blackColor]];
    
    ZBAccentColor color = [ZBSettings accentColor];
    ZBInterfaceStyle style = [ZBSettings interfaceStyle];
    if (color == ZBAccentColorMonochrome) {
        //Flip the colors for readability
        [[self completeOrCancelButton] setBackgroundColor:[UIColor whiteColor]];
        [[self completeOrCancelButton] setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    }
    else {
        [[self completeOrCancelButton] setBackgroundColor:[ZBThemeManager getAccentColor:color forInterfaceStyle:style] ?: [UIColor systemBlueColor]];
    }
}

- (void)disableCancelButton {
    buttonState = ZBStateDone;
    [self setCompleteOrCancelButtonHidden:YES];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    self.view.backgroundColor = [UIColor blackColor];
    consoleView.backgroundColor = [UIColor blackColor];
    
    if (!messages) {
        databaseManager = [ZBDatabaseManager sharedInstance];
        [databaseManager addDatabaseDelegate:self];
        
        if (_dropTables) {
            [databaseManager dropTables];
        }
        
        if (self.baseSources.count) {
            // Update only the sources specified
            [databaseManager updateSources:self.baseSources useCaching:NO];
        } else {
            // Update every source
            [databaseManager updateDatabaseUsingCaching:NO userRequested:YES];
        }
    } else {
        hadAProblem = YES;
        for (NSString *message in messages) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self writeToConsole:message atLevel:ZBLogLevelError];
            });
        }
        [consoleView setNeedsLayout];
        buttonState = ZBStateDone;
        [self clearProblems];
    }
}

- (IBAction)completeOrCancelButton:(id)sender {
    if (buttonState == ZBStateDone) {
        [self goodbye];
    }
    else {
        if (_dropTables) {
            return;
        }
        [databaseManager cancelUpdates:self];
        [((ZBTabBarController *)self.tabBarController) clearSources];
        [self writeToConsole:@"Refresh cancelled\n" atLevel:ZBLogLevelInfo]; // TODO: localization
        
        buttonState = ZBStateDone;
        [self setCompleteOrCancelButtonHidden:NO];
        [self updateCompleteOrCancelButtonText:NSLocalizedString(@"Done", @"")];
    }
}

- (void)clearProblems {
    messages = nil;
    hadAProblem = NO;
    [self clearConsoleText];
}

- (void)goodbye {
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(goodbye) withObject:nil waitUntilDone:NO];
    } else {
        [self clearProblems];
        ZBTabBarController *controller = (ZBTabBarController *)[self presentingViewController];
        if (controller) {
            [self dismissViewControllerAnimated:YES completion:^{
                if (self->delegate) {
                    [self->delegate finishedSourceVerification:NULL imaginarySources:self->imaginarySources];
                }
                if ([controller isKindOfClass:[ZBTabBarController class]] && controller.forwardToPackageID != NULL) {
                    [controller forwardToPackage];
                }
            }];
        }
        else {
            [[[UIApplication sharedApplication] windows][0] setRootViewController:[[ZBTabBarController alloc] init]];
        }
    }
}

#pragma mark - UI Updates

- (void)setCompleteOrCancelButtonHidden:(BOOL)hidden {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->completeOrCancelButton setHidden:hidden];
    });
}

- (void)updateCompleteOrCancelButtonText:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.completeOrCancelButton setTitle:text forState:UIControlStateNormal];
    });
}

- (void)clearConsoleText {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->consoleView setText:nil];
    });
}

- (void)writeToConsole:(NSString *)str atLevel:(ZBLogLevel)level {
    if (str == nil)
        return;
    if (![str hasSuffix:@"\n"])
        str = [str stringByAppendingString:@"\n"];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        UIColor *color = [UIColor whiteColor];
        UIFont *font;
        switch (level) {
            case ZBLogLevelDescript:
                font = UIFont.monospaceFont;
            case ZBLogLevelInfo: {
                if ([ZBSettings interfaceStyle] < ZBInterfaceStyleDark) {
                    color = [UIColor whiteColor];
                }
                font = font ?: UIFont.boldMonospaceFont;
                break;
            }
            case ZBLogLevelError: {
                color = [UIColor systemRedColor];
                font = UIFont.boldMonospaceFont;
                break;
            }
            case ZBLogLevelWarning: {
                color = [UIColor systemYellowColor];
                font = UIFont.monospaceFont;
                break;
            }
            default:
                break;
        }

        NSDictionary *attrs = @{ NSForegroundColorAttributeName: color, NSFontAttributeName: font };
        
        [self->consoleView.textStorage appendAttributedString:[[NSAttributedString alloc] initWithString:str attributes:attrs]];

        if (self->consoleView.text.length) {
            NSRange bottom = NSMakeRange(self->consoleView.text.length - 1, 1);
            [self->consoleView scrollRangeToVisible:bottom];
        }
    });
}

#pragma mark - Database Delegate

- (void)databaseStartedUpdate {
    hadAProblem = NO;
}

- (void)databaseCompletedUpdate:(int)packageUpdates {
//    ZBTabBarController *tabController = [ZBAppDelegate tabBarController];
//    if (packageUpdates != -1) {
//        [tabController setPackageUpdateBadgeValue:packageUpdates];
//    }
    [databaseManager removeDatabaseDelegate:self];
    if (!hadAProblem) {
        [self goodbye];
    } else {
        [self setCompleteOrCancelButtonHidden:NO];
        [self updateCompleteOrCancelButtonText:NSLocalizedString(@"Done", @"")];
    }
    [[ZBSourceManager sharedInstance] needRecaching];
}

- (void)postStatusUpdate:(NSString *)status atLevel:(ZBLogLevel)level {
    if (level == ZBLogLevelError || level == ZBLogLevelWarning) {
        hadAProblem = YES;
    }
    [self writeToConsole:status atLevel:level];
}

@end
