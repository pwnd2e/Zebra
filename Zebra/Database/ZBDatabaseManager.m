//
//  ZBDatabaseManager.m
//  Zebra
//
//  Created by Wilson Styres on 11/30/18.
//  Copyright © 2018 Wilson Styres. All rights reserved.
//

#import "ZBDatabaseManager.h"
#import "ZBDependencyResolver.h"

#import "ZBLog.h"
#import "ZBDevice.h"
#import "ZBSettings.h"
#import "parsel.h"
#import "vercmp.h"
#import "ZBAppDelegate.h"
#import "ZBBaseSource.h"
#import "ZBSource.h"
#import "ZBPackage.h"
#import "ZBDownloadManager.h"
#import "ZBColumn.h"
#import "ZBQueue.h"
#import "ZBProxyPackage.h"
#import "NSURLSession+Zebra.h"

@interface ZBDatabaseManager () {
    int numberOfDatabaseUsers;
    int numberOfUpdates;
    NSMutableArray *completedSources;
    NSMutableArray *installedPackageIDs;
    NSMutableArray *upgradePackageIDs;
    BOOL databaseBeingUpdated;
    BOOL haltDatabaseOperations;
}
@end

@implementation ZBDatabaseManager

@synthesize needsToPresentRefresh;
@synthesize database;

+ (id)sharedInstance {
    static ZBDatabaseManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [ZBDatabaseManager new];
        instance.databaseDelegates = [NSMutableArray new];
    });
    return instance;
}

+ (BOOL)needsMigration {
    if (![[NSFileManager defaultManager] fileExistsAtPath:[ZBAppDelegate databaseLocation]]) {
        return YES;
    }

    ZBDatabaseManager *databaseManager = [ZBDatabaseManager sharedInstance];
    [databaseManager openDatabase];

    // Checks to see if any of the databases have differing schemes and sets to update them if need be.
    BOOL migration = (needsMigration(databaseManager.database, 0) != 0 || needsMigration(databaseManager.database, 1) != 0 || needsMigration(databaseManager.database, 2) != 0);

    [databaseManager closeDatabase];

    return migration;
}

+ (NSDate *)lastUpdated {
    NSDate *lastUpdatedDate = (NSDate *)[[NSUserDefaults standardUserDefaults] objectForKey:@"lastUpdatedDate"];
    return lastUpdatedDate != NULL ? lastUpdatedDate : [NSDate distantPast];
}

+ (struct ZBBaseSource)baseSourceStructFromSource:(ZBBaseSource *)source {
    struct ZBBaseSource sourceStruct;
    sourceStruct.archiveType = [source.archiveType UTF8String];
    sourceStruct.repositoryURI = [source.repositoryURI UTF8String];
    sourceStruct.distribution = [source.distribution UTF8String];
    sourceStruct.components = [[[source components] componentsJoinedByString:@" "] UTF8String];
    sourceStruct.baseFilename = [source.baseFilename UTF8String];

    return sourceStruct;
}

- (id)init {
    self = [super init];

    if (self) {
        numberOfUpdates = 0;
    }

    return self;
}

#pragma mark - Helpers

- (NSString *)_escapeSQLString:(NSString *)string {
    return [[string stringByReplacingOccurrencesOfString:@"'" withString:@"''"]
            stringByReplacingOccurrencesOfString:@"\0" withString:@""];
}

- (NSString *)_escapeLikeString:(NSString *)string {
    return [string stringByReplacingOccurrencesOfString:@"([%_\\\\])"
                                             withString:@"\\\\$1"
                                                options:NSRegularExpressionSearch
                                                  range:NSMakeRange(0, string.length)];
}

- (NSString *)_installablePackageArchitectureClause {
    NSArray <NSString *> *allArchs = [ZBDevice allDebianArchitectures];

    NSMutableArray <NSString *> *archs = [NSMutableArray array];
    for (NSString *arch in allArchs) {
        [archs addObject:[NSString stringWithFormat:@"'%@'", [self _escapeSQLString:arch]]];
    }
    [archs insertObject:@"'all'" atIndex:1];

    return [NSString stringWithFormat:@"(ARCHITECTURE IN (%@))",
            [archs componentsJoinedByString:@","]];
}

- (NSString *)_userArchitectureFilteringClause {
    return [ZBSettings filterIncompatibleArchitectures] ? self._installablePackageArchitectureClause : @"(1=1)";
}

- (NSString *)_packageArchitectureWeightingClause {
    NSArray <NSString *> *allArchs = [ZBDevice allDebianArchitectures];

    NSMutableArray <NSString *> *foreignArchs = [NSMutableArray array];
    for (int i = 1; i < allArchs.count; i++) {
        [foreignArchs addObject:[NSString stringWithFormat:@"'%@'", [self _escapeSQLString:allArchs[i]]]];
    }

    return [NSString stringWithFormat:@"(CASE "
            // Native arch or all (APT treats all as equivalent to native)
            @"WHEN ARCHITECTURE IN ('%@', 'all') THEN 1 "
            // Foreign archs
            @"WHEN ARCHITECTURE IN (%@) THEN 2 "
            // Unsupported archs
            @"ELSE 3 "
            @"END) ASC",
            [self _escapeSQLString:allArchs.firstObject],
            [foreignArchs componentsJoinedByString:@","]];
}

- (NSInteger)_bindStringArray:(NSArray <NSString *> *)array toStatement:(sqlite3_stmt *)statement at:(NSInteger)startIndex {
    for (NSInteger i = 0; i < array.count; i++) {
        sqlite3_bind_text(statement, (int)(startIndex + i), array[i].UTF8String, -1, SQLITE_TRANSIENT);
    }
    return startIndex + array.count;
}

#pragma mark - Opening and Closing the Database

- (int)openDatabase {
    if (![self isDatabaseOpen] || !database) {
        assert(sqlite3_threadsafe());
        int result = sqlite3_open_v2([[ZBAppDelegate databaseLocation] UTF8String], &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_CREATE, NULL);
        if (result == SQLITE_OK) {
            [self increment];
        }
        return result;
    } else {
        [self increment];
        return SQLITE_OK;
    }
}

- (void)increment {
    @synchronized(self) {
        ++numberOfDatabaseUsers;
    }
}

- (void)decrement {
    @synchronized(self) {
        --numberOfDatabaseUsers;
    }
}

- (int)closeDatabase {
    @synchronized(self) {
        if (numberOfDatabaseUsers == 0) {
            return SQLITE_ERROR;
        }
    }

    if (--numberOfDatabaseUsers == 0 && [self isDatabaseOpen]) {
        int result = sqlite3_close(database);
        database = NULL;
        return result;
    }
    return SQLITE_OK;
}

- (BOOL)isDatabaseBeingUpdated {
    return databaseBeingUpdated;
}

- (void)setDatabaseBeingUpdated:(BOOL)updated {
    databaseBeingUpdated = updated;
}

- (BOOL)isDatabaseOpen {
    @synchronized(self) {
        return numberOfDatabaseUsers > 0 || database != NULL;
    }
}

- (void)printDatabaseError {
    databaseBeingUpdated = NO;
    const char *error = sqlite3_errmsg(database);
    if (error) {
        NSLog(@"[Zebra] Database Error: %s", error);
    }
}

- (void)addDatabaseDelegate:(id <ZBDatabaseDelegate>)delegate {
    if (![self.databaseDelegates containsObject:delegate]) {
        [self.databaseDelegates addObject:delegate];
    }
}

- (void)removeDatabaseDelegate:(id <ZBDatabaseDelegate>)delegate {
    [self.databaseDelegates removeObject:delegate];
}

- (void)bulkDatabaseStartedUpdate {
    for (int i = 0; i < self.databaseDelegates.count; ++i) {
        id <ZBDatabaseDelegate> delegate = self.databaseDelegates[i];
        [delegate databaseStartedUpdate];
    }
}

- (void)bulkDatabaseCompletedUpdate:(int)updates {
    databaseBeingUpdated = NO;
    for (int i = 0; i < self.databaseDelegates.count; ++i) {
        id <ZBDatabaseDelegate> delegate = self.databaseDelegates[i];
        [delegate databaseCompletedUpdate:updates];
    }
}

- (void)bulkPostStatusUpdate:(NSString *)status atLevel:(ZBLogLevel)level {
    for (int i = 0; i < self.databaseDelegates.count; ++i) {
        id <ZBDatabaseDelegate> delegate = self.databaseDelegates[i];
        if ([delegate respondsToSelector:@selector(postStatusUpdate:atLevel:)]) {
            [delegate postStatusUpdate:status atLevel:level];
        }
    }
}

- (void)bulkSetSource:(NSString *)bfn busy:(BOOL)busy {
    for (int i = 0; i < self.databaseDelegates.count; ++i) {
        id <ZBDatabaseDelegate> delegate = self.databaseDelegates[i];
        if ([delegate respondsToSelector:@selector(setSource:busy:)]) {
            [delegate setSource:bfn busy:busy];
        }
    }
}

#pragma mark - Populating the database

- (void)updateDatabaseUsingCaching:(BOOL)useCaching userRequested:(BOOL)requested {
    if (databaseBeingUpdated)
        return;
    databaseBeingUpdated = YES;

    BOOL needsUpdate = NO;
    if (requested && haltDatabaseOperations) { //Halt database operations may need to be rethought
        [self setHaltDatabaseOperations:NO];
    }

    if (!requested && [ZBSettings wantsAutoRefresh]) {
        NSDate *currentDate = [NSDate date];
        NSDate *lastUpdatedDate = [ZBDatabaseManager lastUpdated];

        if (lastUpdatedDate != NULL) {
            NSCalendar *gregorian = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
            NSUInteger unitFlags = NSCalendarUnitMinute;
            NSDateComponents *components = [gregorian components:unitFlags fromDate:lastUpdatedDate toDate:currentDate options:0];

            needsUpdate = ([components minute] >= 30);
        } else {
            needsUpdate = YES;
        }
    }

    if (requested || needsUpdate) {
        [self bulkDatabaseStartedUpdate];

        NSError *readError = NULL;
        NSSet <ZBBaseSource *> *baseSources = [ZBBaseSource baseSourcesFromList:[ZBAppDelegate sourcesListURL] error:&readError];
        if (readError) {
            //oh no!
            return;
        }

        [self bulkPostStatusUpdate:NSLocalizedString(@"Updating Sources", @"") atLevel:ZBLogLevelInfo];
        [self bulkPostStatusUpdate:[NSString stringWithFormat:NSLocalizedString(@"A total of %lu files will be downloaded", @""), (unsigned long)[baseSources count] * 2] atLevel:ZBLogLevelDescript];
        [self updateSources:baseSources useCaching:useCaching];
    } else {
        [self importLocalPackagesAndCheckForUpdates:YES sender:self];
    }
}

- (void)updateSource:(ZBBaseSource *)source useCaching:(BOOL)useCaching {
    [self updateSources:[NSSet setWithArray:@[source]] useCaching:useCaching];
}

- (void)updateSources:(NSSet <ZBBaseSource *> *)sources useCaching:(BOOL)useCaching {
    [self bulkDatabaseStartedUpdate];
    if (!self.downloadManager) {
        self.downloadManager = [[ZBDownloadManager alloc] initWithDownloadDelegate:self];
    }

    [self bulkPostStatusUpdate:NSLocalizedString(@"Starting Download", @"") atLevel:ZBLogLevelInfo];
    [self.downloadManager downloadSources:sources useCaching:useCaching];
}

- (void)setHaltDatabaseOperations:(BOOL)halt {
    haltDatabaseOperations = halt;
}

- (void)parseSources:(NSArray <ZBBaseSource *> *)sources {
    NSLog(@"Parsing Sources");
    [[NSNotificationCenter defaultCenter] postNotificationName:@"disableCancelRefresh" object:nil];
    if (haltDatabaseOperations) {
        NSLog(@"[Zebra] Database operations halted");
        [self bulkDatabaseCompletedUpdate:numberOfUpdates];
        return;
    }
    [self bulkPostStatusUpdate:NSLocalizedString(@"Download Completed", @"") atLevel:ZBLogLevelInfo];
    self.downloadManager = nil;

    if ([self openDatabase] == SQLITE_OK) {
        createTable(database, 0);
        createTable(database, 1);
        sqlite3_exec(database, "CREATE TABLE PACKAGES_SNAPSHOT AS SELECT PACKAGE, VERSION, REPOID, LASTSEEN FROM PACKAGES WHERE REPOID > 0", NULL, 0, NULL);
        sqlite3_exec(database, "CREATE INDEX tag_PACKAGEVERSION_SNAPSHOT ON PACKAGES_SNAPSHOT (PACKAGE, VERSION)", NULL, 0, NULL);
        sqlite3_int64 currentDate = (sqlite3_int64)[[NSDate date] timeIntervalSince1970];

//        dispatch_queue_t queue = dispatch_queue_create("xyz.willy.Zebra.repoParsing", NULL);
        for (ZBBaseSource *source in sources) {
//            dispatch_async(queue, ^{
                [self bulkSetSource:[source baseFilename] busy:YES];
                [self bulkPostStatusUpdate:[NSString stringWithFormat:NSLocalizedString(@"Parsing %@", @""), [source repositoryURI]] atLevel:ZBLogLevelDescript];

                //Deal with the source first
                int sourceID = [self sourceIDFromBaseFileName:[source baseFilename]];
                if (!source.releaseFilePath && source.packagesFilePath) { //We need to create a dummy source (for sources with no Release file)
                    if (sourceID == -1) {
                        sourceID = [self nextSourceID];
                        createDummySource([ZBDatabaseManager baseSourceStructFromSource:source], self->database, sourceID);
                    }
                }
                else if (source.releaseFilePath) {
                    if (sourceID == -1) { // Source does not exist in database, create it.
                        sourceID = [self nextSourceID];
                        if (importSourceToDatabase([ZBDatabaseManager baseSourceStructFromSource:source], [source.releaseFilePath UTF8String], self->database, sourceID) != PARSEL_OK) {
                            [self bulkPostStatusUpdate:[NSString stringWithFormat:@"%@ %@\n", NSLocalizedString(@"Error while opening file:", @""), source.releaseFilePath] atLevel:ZBLogLevelError];
                        }
                    } else {
                        if (updateSourceInDatabase([ZBDatabaseManager baseSourceStructFromSource:source], [source.releaseFilePath UTF8String], self->database, sourceID) != PARSEL_OK) {
                            [self bulkPostStatusUpdate:[NSString stringWithFormat:@"%@ %@\n", NSLocalizedString(@"Error while opening file:", @""), source.releaseFilePath] atLevel:ZBLogLevelError];
                        }
                    }

                    if ([source.repositoryURI hasPrefix:@"https"]) {
                        NSURL *url = [NSURL URLWithString:[source.repositoryURI stringByAppendingPathComponent:@"payment_endpoint"]];

                        NSURLSessionDataTask *task = [[NSURLSession zbra_standardSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *) response;
                            NSString *endpoint = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                            endpoint = [endpoint stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                            if ([endpoint length] != 0 && (long)[httpResponse statusCode] == 200) {
                                if ([endpoint hasPrefix:@"https"]) {
                                    [self bulkPostStatusUpdate:[NSString stringWithFormat:NSLocalizedString(@"Adding Payment Vendor URL for %@", @""), source.repositoryURI] atLevel:ZBLogLevelDescript];
                                    if ([self openDatabase] == SQLITE_OK) {
                                        addPaymentEndpointForSource([endpoint UTF8String], self->database, sourceID);
                                        [self closeDatabase];
                                    }
                                }
                            }
                        }];

                        [task resume];
                    }
                }

                //Deal with the packages
                if (source.packagesFilePath && updatePackagesInDatabase([source.packagesFilePath UTF8String], self->database, sourceID, currentDate) != PARSEL_OK) {
                    [self bulkPostStatusUpdate:[NSString stringWithFormat:@"%@ %@\n", NSLocalizedString(@"Error while opening file:", @""), source.packagesFilePath] atLevel:ZBLogLevelError];
                }

                [self bulkSetSource:[source baseFilename] busy:NO];
//            });
        }

        sqlite3_exec(database, "DROP TABLE PACKAGES_SNAPSHOT", NULL, 0, NULL);

        [self bulkPostStatusUpdate:NSLocalizedString(@"Done", @"") atLevel:ZBLogLevelInfo];

        [self importLocalPackagesAndCheckForUpdates:YES sender:self];
        [self updateLastUpdated];
        [self bulkDatabaseCompletedUpdate:numberOfUpdates];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ZBDatabaseCompletedUpdate" object:nil];
        [self closeDatabase];
    } else {
        [self printDatabaseError];
    }
}

- (void)importLocalPackagesAndCheckForUpdates:(BOOL)checkForUpdates sender:(id)sender {
    if (haltDatabaseOperations) {
        NSLog(@"[Zebra] Database operations halted");
        return;
    }

    BOOL needsDelegateStart = !([sender isKindOfClass:[ZBDatabaseManager class]]);
    if (needsDelegateStart) {
        [self bulkDatabaseStartedUpdate];
    }
    NSLog(@"[Zebra] Importing local packages");
    [self importLocalPackages];
    if (checkForUpdates) {
        [self checkForPackageUpdates];
    }
    if (needsDelegateStart) {
        [self bulkDatabaseCompletedUpdate:numberOfUpdates];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ZBDatabaseCompletedUpdate" object:nil];
    databaseBeingUpdated = NO;
}

- (void)importLocalPackages {
    if (haltDatabaseOperations) {
        NSLog(@"[Zebra] Database operations halted");
        return;
    }

    NSString *installedPath;
    if ([ZBDevice needsSimulation]) { // If the target is a simlator, load a demo list of installed packages
        installedPath = [[NSBundle mainBundle] pathForResource:@"Installed" ofType:@"pack"];
    } else { // Otherwise, load the actual file
        installedPath = @INSTALL_PREFIX @"/var/lib/dpkg/status";
    }

    if ([self openDatabase] == SQLITE_OK) {
        // Delete packages from local sources (-1 and 0)
        sqlite3_exec(database, "DELETE FROM PACKAGES WHERE REPOID = 0", NULL, 0, NULL);
        sqlite3_exec(database, "DELETE FROM PACKAGES WHERE REPOID = -1", NULL, 0, NULL);

        // Import packages from the installedPath
        importPackagesToDatabase([installedPath UTF8String], database, 0);

        [self closeDatabase];
    } else {
        [self printDatabaseError];
    }
}

- (void)checkForPackageUpdates {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *installedPackages = [NSMutableArray new];

        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, "SELECT * FROM PACKAGES WHERE REPOID = 0", -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                ZBPackage *package = [[ZBPackage alloc] initWithSQLiteStatement:statement];
                [installedPackages addObject:package];
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);

        // Check for updates
        NSLog(@"[Zebra] Checking for updates…");
        NSMutableArray *found = [NSMutableArray new];

        createTable(database, 2);

        numberOfUpdates = 0;
        upgradePackageIDs = [NSMutableArray new];
        for (ZBPackage *package in installedPackages) {
            if ([found containsObject:package.identifier]) {
                ZBLog(@"[Zebra] I already checked %@, skipping", package.identifier);
                continue;
            }

            ZBPackage *topPackage = [self topVersionForPackage:package filteringArch:YES];
            NSComparisonResult compare = [package compare:topPackage];
            if (compare == NSOrderedAscending) {
                ZBLog(@"[Zebra] Installed package %@ is less than top package %@, it needs an update", package, topPackage);

                BOOL ignoreUpdates = [topPackage ignoreUpdates];
                if (!ignoreUpdates) ++numberOfUpdates;

                char *query = "REPLACE INTO UPDATES (PACKAGE, VERSION, IGNORE) "
                              "VALUES (?, ?, ?)";
                if (sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK) {
                    sqlite3_bind_text(statement, 1, [topPackage.identifier UTF8String], -1, SQLITE_TRANSIENT);
                    sqlite3_bind_text(statement, 2, [topPackage.version UTF8String], -1, SQLITE_TRANSIENT);
                    sqlite3_bind_int(statement, 3, ignoreUpdates ? 1 : 0);

                    while (sqlite3_step(statement) == SQLITE_ROW) {
                        break;
                    }
                } else {
                    [self printDatabaseError];
                }
                sqlite3_finalize(statement);

                [upgradePackageIDs addObject:[topPackage identifier]];
            } else if (compare == NSOrderedSame) {
                char *query;
                BOOL packageIgnoreUpdates = [package ignoreUpdates];
                if (packageIgnoreUpdates) {
                    // This package has no update and the user actively ignores updates from it, we update the latest version here
                    query = "REPLACE INTO UPDATES (PACKAGE, VERSION, IGNORE) "
                            "VALUES (?, ?, 1)";
                } else {
                    // This package has no update and the user does not ignore updates from it, having the record in the database is waste of space
                    query = "DELETE FROM UPDATES WHERE PACKAGE = ?";
                }

                if (sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK) {
                    if (packageIgnoreUpdates) {
                        sqlite3_bind_text(statement, 1, [package.identifier UTF8String], -1, SQLITE_TRANSIENT);
                        sqlite3_bind_text(statement, 2, [package.version UTF8String], -1, SQLITE_TRANSIENT);
                    } else {
                        sqlite3_bind_text(statement, 1, [package.identifier UTF8String], -1, SQLITE_TRANSIENT);
                    }
                    while (sqlite3_step(statement) == SQLITE_ROW) {
                        break;
                    }
                } else {
                    [self printDatabaseError];
                }
                sqlite3_finalize(statement);
            }
            [found addObject:package.identifier];
        }

        //In order to make this easy, we're going to check for "Essential" packages that aren't installed and mark them as updates
        NSMutableArray *essentials = [NSMutableArray new];
        sqlite3_stmt *essentialStatement; //v important statement
        NSString *query = [NSString stringWithFormat:@"SELECT PACKAGE, VERSION FROM PACKAGES "
                           @"WHERE REPOID > 0 AND ESSENTIAL = 'yes' COLLATE NOCASE AND %@",
                           self._installablePackageArchitectureClause];
        if (sqlite3_prepare_v2(database, query.UTF8String, -1, &essentialStatement, nil) == SQLITE_OK) {
            while (sqlite3_step(essentialStatement) == SQLITE_ROW) {
                const char *identifierChars = (const char *)sqlite3_column_text(essentialStatement, 0);
                const char *versionChars = (const char *)sqlite3_column_text(essentialStatement, 1);

                NSString *packageIdentifier = [NSString stringWithUTF8String:identifierChars];
                NSString *version = [NSString stringWithUTF8String:versionChars];

                if (![self packageIDIsInstalled:packageIdentifier version:NULL]) {
                    NSDictionary *essentialPackage = @{@"id": packageIdentifier, @"version": version};
                    [essentials addObject:essentialPackage];
                }
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(essentialStatement);

        for (NSDictionary *essentialPackage in essentials) {
            NSString *identifier = [essentialPackage objectForKey:@"id"];
            NSString *version = [essentialPackage objectForKey:@"version"];

            BOOL ignoreUpdates = [self areUpdatesIgnoredForPackageIdentifier:[essentialPackage objectForKey:@"id"]];
            if (!ignoreUpdates) ++numberOfUpdates;

            char *query = "REPLACE INTO UPDATES (PACKAGE, VERSION, IGNORE) "
                          "VALUES (?, ?, ?)";
            if (sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK) {
                sqlite3_bind_text(statement, 1, [identifier UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(statement, 2, [version UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_bind_int(statement, 3, ignoreUpdates ? 1 : 0);
                while (sqlite3_step(statement) == SQLITE_ROW) {
                    break;
                }
            } else {
                [self printDatabaseError];
            }
            sqlite3_finalize(statement);

            [upgradePackageIDs addObject:identifier];
        }

        [self closeDatabase];
    } else {
        [self printDatabaseError];
    }
}

- (void)dropTables {
    if ([self openDatabase] == SQLITE_OK) {
        sqlite3_exec(database, "DROP TABLE PACKAGES", NULL, 0, NULL);
        sqlite3_exec(database, "DROP TABLE REPOS", NULL, 0, NULL);

        // Update UPDATES table schema while retaining user data
        sqlite3_exec(database, "DELETE FROM UPDATES WHERE IGNORE != 1", NULL, 0, NULL);
        sqlite3_exec(database, "CREATE TABLE UPDATES_SNAPSHOT AS SELECT PACKAGE, VERSION, IGNORE FROM UPDATES", NULL, 0, NULL);
        sqlite3_exec(database, "DROP TABLE UPDATES", NULL, 0, NULL);
        createTable(database, 2);
        sqlite3_exec(database, "INSERT INTO UPDATES SELECT PACKAGE, VERSION, IGNORE FROM UPDATES_SNAPSHOT", NULL, 0, NULL);
        sqlite3_exec(database, "DROP TABLE UPDATES_SNAPSHOT", NULL, 0, NULL);

        [self closeDatabase];
    } else {
        [self printDatabaseError];
    }
}

- (void)updateLastUpdated {
    [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:@"lastUpdatedDate"];
}

#pragma mark - Source management

- (int)sourceIDFromBaseFileName:(NSString *)bfn {
    if ([self openDatabase] == SQLITE_OK) {
        sqlite3_stmt *statement = NULL;
        int sourceID = -1;
        if (sqlite3_prepare_v2(database, "SELECT REPOID FROM REPOS WHERE BASEFILENAME = ?", -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_text(statement, 1, [bfn UTF8String], -1, SQLITE_TRANSIENT);
            while (sqlite3_step(statement) == SQLITE_ROW) {
                sourceID = sqlite3_column_int(statement, 0);
                break;
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);

        [self closeDatabase];
        return sourceID;
    } else {
        [self printDatabaseError];
    }
    return -1;
}

- (int)sourceIDFromBaseURL:(NSString *)baseURL strict:(BOOL)strict {
    if ([self openDatabase] == SQLITE_OK) {
        char *query = strict
            ? "SELECT REPOID FROM REPOS WHERE URI = ?"
            : "SELECT REPOID FROM REPOS WHERE URI LIKE ? ESCAPE '\\'";
        sqlite3_stmt *statement = NULL;
        int sourceID = -1;
        if (sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK) {
            if (strict) {
                sqlite3_bind_text(statement, 1, [baseURL UTF8String], -1, SQLITE_TRANSIENT);
            } else {
                NSString *baseURLLike = [self _escapeLikeString:baseURL];
                sqlite3_bind_text(statement, 1, [NSString stringWithFormat:@"%%%@%%", baseURLLike].UTF8String, -1, SQLITE_TRANSIENT);
            }
            while (sqlite3_step(statement) == SQLITE_ROW) {
                sourceID = sqlite3_column_int(statement, 0);
                break;
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);

        [self closeDatabase];
        return sourceID;
    } else {
        [self printDatabaseError];
    }
    return -1;
}

- (ZBSource * _Nullable)sourceFromBaseURL:(NSString *)burl {
    NSRange dividerRange = [burl rangeOfString:@"://"];
    NSUInteger divide = NSMaxRange(dividerRange);
    NSString *baseFilename = divide > [burl length] ? burl : [burl substringFromIndex:divide];
    baseFilename = [baseFilename stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [self sourceFromBaseFilename:baseFilename];
}

- (ZBSource * _Nullable)sourceFromBaseFilename:(NSString *)baseFilename {
    if ([self openDatabase] == SQLITE_OK) {
        sqlite3_stmt *statement = NULL;
        ZBSource *source = nil;
        if (sqlite3_prepare_v2(database, "SELECT * FROM REPOS WHERE BASEFILENAME = ?", -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_text(statement, 1, [baseFilename UTF8String], -1, SQLITE_TRANSIENT);
            while (sqlite3_step(statement) == SQLITE_ROW) {
                source = [[ZBSource alloc] initWithSQLiteStatement:statement];
                break;
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        [self closeDatabase];

        return source;
    } else {
        [self printDatabaseError];
    }
    return nil;
}

- (int)nextSourceID {
    if ([self openDatabase] == SQLITE_OK) {
        char *query = "SELECT REPOID FROM REPOS "
                      "ORDER BY REPOID "
                      "DESC LIMIT 1";
        sqlite3_stmt *statement = NULL;
        int sourceID = 0;
        if (sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                sourceID = sqlite3_column_int(statement, 0);
                break;
            }
        } else {
            [self printDatabaseError];
        }

        sqlite3_finalize(statement);

        [self closeDatabase];
        return sourceID + 1;
    } else {
        [self printDatabaseError];
    }
    return -1;
}

- (int)numberOfPackagesInSource:(ZBSource * _Nullable)source section:(NSString * _Nullable)section enableFiltering:(BOOL)enableFiltering {
    if ([self openDatabase] == SQLITE_OK) {
        // FIXME: Use NSUserDefaults
        int packages = 0;
        NSString *query = nil;
        NSString *sourcePart = source ? @"= ?" : @"> 0";
        if (section != NULL) {
            query = [NSString stringWithFormat:@"SELECT COUNT(DISTINCT PACKAGE) FROM PACKAGES "
                     @"WHERE SECTION = ? AND REPOID %@ AND %@",
                     sourcePart,
                     self._userArchitectureFilteringClause];
        } else {
            query = [NSString stringWithFormat:@"SELECT SECTION, AUTHORNAME, AUTHOREMAIL, REPOID FROM PACKAGES "
                     @"WHERE REPOID %@ AND %@ "
                     @"GROUP BY PACKAGE",
                     sourcePart,
                     self._userArchitectureFilteringClause];
        }

        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            int i = 0;
            if (section) {
                sqlite3_bind_text(statement, ++i, [section UTF8String], -1, SQLITE_TRANSIENT);
            }
            if (source) {
                sqlite3_bind_int(statement, ++i, source.sourceID);
            }

            while (sqlite3_step(statement) == SQLITE_ROW) {
                if (section == NULL) {
                    if (!enableFiltering) {
                        ++packages;
                    } else {
                        const char *packageSection = (const char *)sqlite3_column_text(statement, 1);
                        const char *packageAuthor = (const char *)sqlite3_column_text(statement, 2);
                        const char *packageAuthorEmail = (const char *)sqlite3_column_text(statement, 3);
                        if (packageSection != 0 && packageAuthor != 0 && packageAuthorEmail != 0) {
                            int sourceID = sqlite3_column_int(statement, 3);
                            if (![ZBSettings isSectionFiltered:[NSString stringWithUTF8String:packageSection] forSource:[ZBSource sourceMatchingSourceID:sourceID]] && ![ZBSettings isAuthorBlocked:[NSString stringWithUTF8String:packageAuthor] email:[NSString stringWithUTF8String:packageAuthorEmail]])
                                ++packages;
                        }
                        else {
                            ++packages; // We can't filter this package as it has no section or no author
                        }
                    }
                } else {
                    packages = sqlite3_column_int(statement, 0);
                    break;
                }
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);

        [self closeDatabase];
        return packages;
    } else {
        [self printDatabaseError];
    }
    return -1;
}

- (int)numberOfPackagesInSource:(ZBSource * _Nullable)source section:(NSString * _Nullable)section {
    return [self numberOfPackagesInSource:source section:section enableFiltering:NO];
}

- (NSSet <ZBSource *> *)sources {
    if ([self openDatabase] == SQLITE_OK) {
        NSError *readError = NULL;
        NSMutableSet *baseSources = [[ZBBaseSource baseSourcesFromList:[ZBAppDelegate sourcesListURL] error:&readError] mutableCopy];
        NSMutableSet *sources = [NSMutableSet new];

        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, "SELECT * FROM REPOS", -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                ZBSource *source = [[ZBSource alloc] initWithSQLiteStatement:statement];
                for (ZBBaseSource *baseSource in [baseSources copy]) {
                    if ([baseSource isEqual:source]) {
                        [sources addObject:source];
                        [baseSources removeObject:baseSource];
                        break;
                    }
                }
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        [self closeDatabase];

        return [sources setByAddingObjectsFromSet:baseSources];
    }

    [self printDatabaseError];
    return NULL;
}

- (ZBSource *)sourceFromSourceID:(int)sourceID {
    if ([self openDatabase] == SQLITE_OK) {
        ZBSource *source;

        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, "SELECT * FROM REPOS WHERE REPOID = ?", -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_int(statement, 1, sourceID);
            while (sqlite3_step(statement) == SQLITE_ROW) {
                ZBSource *potential = [[ZBSource alloc] initWithSQLiteStatement:statement];
                if (potential) source = potential;
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        [self closeDatabase];

        return source;
    }

    [self printDatabaseError];
    return NULL;
}

- (NSSet <ZBSource *> * _Nullable)sourcesWithPaymentEndpoint {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableSet *sources = [NSMutableSet new];

        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, "SELECT * FROM REPOS WHERE VENDOR NOT NULL", -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                ZBSource *source = [[ZBSource alloc] initWithSQLiteStatement:statement];

                [sources addObject:source];
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        [self closeDatabase];

        return sources;
    }

    [self printDatabaseError];
    return NULL;
}

- (void)deleteSource:(ZBSource *)source {
    if ([self openDatabase] == SQLITE_OK) {
        NSString *packageQuery = [NSString stringWithFormat:@"DELETE FROM PACKAGES WHERE REPOID = %d", [source sourceID]];
        NSString *sourceQuery = [NSString stringWithFormat:@"DELETE FROM REPOS WHERE REPOID = %d", [source sourceID]];

        sqlite3_exec(database, "BEGIN TRANSACTION", NULL, NULL, NULL);
        sqlite3_exec(database, [packageQuery UTF8String], NULL, NULL, NULL);
        sqlite3_exec(database, [sourceQuery UTF8String], NULL, NULL, NULL);
        sqlite3_exec(database, "COMMIT TRANSACTION", NULL, NULL, NULL);

        [self closeDatabase];
    } else {
        [self printDatabaseError];
    }
}

- (void)cancelUpdates:(id <ZBDatabaseDelegate>)delegate {
    [self setDatabaseBeingUpdated:NO];
    [self setHaltDatabaseOperations:YES];
//    [self.downloadManager stopAllDownloads];
    [self bulkDatabaseCompletedUpdate:-1];
    [self removeDatabaseDelegate:delegate];
}

- (NSArray * _Nullable)sectionReadout {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *sections = [NSMutableArray new];
        char *query = "SELECT SECTION FROM PACKAGES "
                      "GROUP BY SECTION "
                      "ORDER BY SECTION";

        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                const char *sectionChars = (const char *)sqlite3_column_text(statement, 0);
                if (sectionChars != 0) {
                    NSString *section = [[NSString stringWithUTF8String:sectionChars] stringByReplacingOccurrencesOfString:@"_" withString:@" "];
                    if (section) [sections addObject:section];
                }
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);

        [self closeDatabase];
        return sections;
    } else {
        [self printDatabaseError];
    }
    return NULL;
}

- (NSDictionary * _Nullable)sectionReadoutForSource:(ZBSource *)source {
    if (![source respondsToSelector:@selector(sourceID)]) return NULL;

    if ([self openDatabase] == SQLITE_OK) {
        NSMutableDictionary *sectionReadout = [NSMutableDictionary new];

        NSString *query = [NSString stringWithFormat:@"SELECT SECTION, COUNT(DISTINCT PACKAGE) AS SECTION_COUNT FROM PACKAGES "
                           @"WHERE REPOID = ? AND %@ "
                           @"GROUP BY SECTION "
                           @"ORDER BY SECTION",
                           self._userArchitectureFilteringClause];

        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_int(statement, 1, source.sourceID);

            while (sqlite3_step(statement) == SQLITE_ROW) {
                const char *sectionChars = (const char *)sqlite3_column_text(statement, 0);
                if (sectionChars != 0) {
                    NSString *section = [[NSString stringWithUTF8String:sectionChars] stringByReplacingOccurrencesOfString:@"_" withString:@" "];
                    [sectionReadout setObject:[NSNumber numberWithInt:sqlite3_column_int(statement, 1)] forKey:section];
                }
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);

        [self closeDatabase];
        return sectionReadout;
    } else {
        [self printDatabaseError];
    }
    return NULL;
}

- (NSURL * _Nullable)paymentVendorURLForSource:(ZBSource *)source {
    if ([self openDatabase] == SQLITE_OK) {
        char *query = "SELECT VENDOR FROM REPOS "
                      "WHERE REPOID = ?";
        sqlite3_stmt *statement = NULL;

        NSString *vendorURL = nil;
        if (sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_int(statement, 1, source.sourceID);
            sqlite3_step(statement);

            const char *vendorChars = (const char *)sqlite3_column_text(statement, 0);
            vendorURL = vendorChars ? [NSString stringWithUTF8String:vendorChars] : NULL;
        }
        else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);

        [self closeDatabase];
        if (vendorURL) {
            return [NSURL URLWithString:vendorURL];
        }
    }
    return NULL;
}

#pragma mark - Package management

- (NSArray <ZBPackage *> * _Nullable)packagesFromSource:(ZBSource * _Nullable)source inSection:(NSString * _Nullable)section numberOfPackages:(int)limit startingAt:(int)start enableFiltering:(BOOL)enableFiltering {

    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *packages = [NSMutableArray new];
        NSString *query = nil;
        NSString *cleanedSection;

        if (section == NULL) {
            NSString *sourcePart = source ? [NSString stringWithFormat:@"= %d", [source sourceID]] : @"> 0";
            query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES "
                     @"WHERE REPOID %@ AND %@ "
                     @"ORDER BY %@, LASTSEEN DESC "
                     @"LIMIT %d "
                     @"OFFSET %d",
                     sourcePart,
                     self._userArchitectureFilteringClause,
                     self._packageArchitectureWeightingClause,
                     limit, start];
        } else {
            NSString *sourcePart = source ? [NSString stringWithFormat:@"= %d", [source sourceID]] : @"> 0";

            cleanedSection = [section containsString:@"_"]
                ? [section stringByReplacingOccurrencesOfString:@"_" withString:@" "]
                : [section stringByReplacingOccurrencesOfString:@" " withString:@"_"];

            query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES "
                     @"WHERE (SECTION = ? OR SECTION = ?) AND REPOID %@ AND %@ "
                     @"ORDER BY %@ "
                     @"LIMIT %d "
                     @"OFFSET %d",
                     sourcePart,
                     self._userArchitectureFilteringClause,
                     self._packageArchitectureWeightingClause,
                     limit, start];
        }

        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            if (section) {
                sqlite3_bind_text(statement, 1, [section UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(statement, 2, [cleanedSection UTF8String], -1, SQLITE_TRANSIENT);
            }

            while (sqlite3_step(statement) == SQLITE_ROW) {
                ZBPackage *package = [[ZBPackage alloc] initWithSQLiteStatement:statement];

                if (section == NULL && enableFiltering && [ZBSettings isPackageFiltered:package])
                    continue;

                [packages addObject:package];
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        [self closeDatabase];

        return [self cleanUpDuplicatePackages:packages];
    } else {
        [self printDatabaseError];
    }
    return NULL;
}

- (NSArray <ZBPackage *> * _Nullable)packagesFromSource:(ZBSource * _Nullable)source inSection:(NSString * _Nullable)section numberOfPackages:(int)limit startingAt:(int)start {
    return [self packagesFromSource:source inSection:section numberOfPackages:limit startingAt:start enableFiltering:NO];
}

- (NSMutableArray <ZBPackage *> * _Nullable)installedPackages:(BOOL)includeVirtualDependencies {
    if ([self openDatabase] == SQLITE_OK) {
        installedPackageIDs = [NSMutableArray new];
        NSMutableArray *installedPackages = [NSMutableArray new];

        NSString *query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES WHERE REPOID %@",
                           includeVirtualDependencies ? @"< 1" : @"= 0"];

        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                const char *packageIDChars =        (const char *)sqlite3_column_text(statement, ZBPackageColumnPackage);
                const char *versionChars =          (const char *)sqlite3_column_text(statement, ZBPackageColumnVersion);
                NSString *packageID = [NSString stringWithUTF8String:packageIDChars];
                NSString *packageVersion = [NSString stringWithUTF8String:versionChars];
                ZBPackage *package = [self packageForID:packageID equalVersion:packageVersion];
                if (package) {
                    package.version = packageVersion;
                    [installedPackageIDs addObject:package.identifier];
                    [installedPackages addObject:package];
                }
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        [self closeDatabase];

        return installedPackages;
    } else {
        [self printDatabaseError];
    }
    return NULL;
}

- (NSDictionary <NSString *, NSArray <NSDictionary *> *> *)installedPackagesList {
    NSMutableArray *installedPackages = [NSMutableArray new];
    NSMutableArray *virtualPackages = [NSMutableArray new];

    for (ZBPackage *package in [self installedPackages:YES]) {
        NSDictionary *installedPackage = @{@"identifier": [package identifier], @"version": [package version]};
        [installedPackages addObject:installedPackage];

        for (NSString *virtualPackageLine in [package provides]) {
            NSArray *comps = [ZBDependencyResolver separateVersionComparison:virtualPackageLine];
            NSDictionary *virtualPackage = @{@"identifier": comps[0], @"version": comps[2]};

            [virtualPackages addObject:virtualPackage];
        }
    }

    return @{@"installed": installedPackages, @"virtual": virtualPackages};
}

- (NSMutableArray <ZBPackage *> *)packagesWithIgnoredUpdates {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray <ZBPackage *> *packagesWithIgnoredUpdates = [NSMutableArray new];
        NSMutableArray <NSString *> *irrelevantPackages = [NSMutableArray new];

        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, "SELECT * FROM UPDATES WHERE IGNORE = 1", -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                const char *identifierChars = (const char *)sqlite3_column_text(statement, ZBUpdateColumnID);
                const char *versionChars = (const char *)sqlite3_column_text(statement, ZBUpdateColumnVersion);
                NSString *identifier = [NSString stringWithUTF8String:identifierChars];
                ZBPackage *package = nil;
                if (versionChars != 0) {
                    NSString *version = [NSString stringWithUTF8String:versionChars];

                    package = [self packageForID:identifier equalVersion:version];
                    if (package != NULL) {
                        [packagesWithIgnoredUpdates addObject:package];
                    }
                }
                if (![self packageIDIsInstalled:identifier version:nil]) {
                    // We don't need ignored updates from packages we don't have them installed
                    [irrelevantPackages addObject:identifier];
                    if (package) {
                        [packagesWithIgnoredUpdates removeObject:package];
                    }
                }
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);

        if (irrelevantPackages.count) {
            NSMutableArray <NSString *> *packageTemplates = [NSMutableArray array];
            for (int i = 0; i < irrelevantPackages.count; i++) {
                [packageTemplates addObject:@"?"];
            }

            NSString *query = [NSString stringWithFormat:@"DELETE FROM UPDATES WHERE PACKAGE IN (%@)", [packageTemplates componentsJoinedByString:@","]];
            if (sqlite3_prepare_v2(database, query.UTF8String, -1, &statement, nil) == SQLITE_OK) {
                for (int i = 0; i < irrelevantPackages.count; i++) {
                    sqlite3_bind_text(statement, i + 1, irrelevantPackages[i].UTF8String, -1, SQLITE_TRANSIENT);
                }
                sqlite3_step(statement);
            }
            sqlite3_finalize(statement);
        }

        [self closeDatabase];

        return packagesWithIgnoredUpdates;
    } else {
        [self printDatabaseError];
    }
    return NULL;
}

- (NSMutableArray <ZBPackage *> * _Nullable)packagesWithUpdates {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *packagesWithUpdates = [NSMutableArray new];

        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, "SELECT * FROM UPDATES WHERE IGNORE = 0", -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                const char *identifierChars = (const char *)sqlite3_column_text(statement, ZBUpdateColumnID);
                const char *versionChars = (const char *)sqlite3_column_text(statement, ZBUpdateColumnVersion);
                NSString *identifier = [NSString stringWithUTF8String:identifierChars];
                if (versionChars != 0) {
                    NSString *version = [NSString stringWithUTF8String:versionChars];

                    ZBPackage *package = [self packageForID:identifier equalVersion:version];
                    if (package != NULL && [upgradePackageIDs containsObject:package.identifier]) {
                        [packagesWithUpdates addObject:package];
                    }
                } else if ([upgradePackageIDs containsObject:identifier]) {
                    [upgradePackageIDs removeObject:identifier];
                }
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);

        [self closeDatabase];
        return packagesWithUpdates;
    } else {
        [self printDatabaseError];
    }
    return NULL;
}

- (NSArray * _Nullable)searchForPackageName:(NSString *)name fullSearch:(BOOL)fullSearch {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *searchResults = [NSMutableArray new];
        NSString *columns = fullSearch ? @"*" : @"PACKAGE, NAME, VERSION, ARCHITECTURE, REPOID, SECTION, ICONURL";
        NSString *limit = fullSearch ? @"" : @"LIMIT 30";
        NSString *query = [NSString stringWithFormat:@"SELECT %@ FROM PACKAGES "
                           @"WHERE NAME LIKE ? ESCAPE '\\' AND REPOID > -1 "
                           @"ORDER BY %@, (CASE "
                                @"WHEN NAME = ? THEN 1 "
                                @"WHEN NAME LIKE ? ESCAPE '\\' THEN 2 "
                                @"ELSE 3 "
                                @"END"
                           @"), NAME COLLATE NOCASE "
                           @"%@",
                           columns, self._packageArchitectureWeightingClause, limit];

        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            NSString *nameLike = [self _escapeLikeString:name];
            sqlite3_bind_text(statement, 1, [[NSString stringWithFormat:@"%%%@%%", nameLike] UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 2, [name UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 3, [[NSString stringWithFormat:@"%@%%", nameLike] UTF8String], -1, SQLITE_TRANSIENT);

            while (sqlite3_step(statement) == SQLITE_ROW) {
                if (fullSearch) {
                    ZBPackage *package = [[ZBPackage alloc] initWithSQLiteStatement:statement];

                    [searchResults addObject:package];
                }
                else {
                    ZBProxyPackage *proxyPackage = [[ZBProxyPackage alloc] initWithSQLiteStatement:statement];

                    const char *sectionChars = (const char *)sqlite3_column_text(statement, 5);
                    const char *iconURLChars = (const char *)sqlite3_column_text(statement, 6);

                    NSString *section = sectionChars != 0 ? [NSString stringWithUTF8String:sectionChars] : NULL;
                    NSString *iconURLString = iconURLChars != 0 ? [NSString stringWithUTF8String:iconURLChars] : NULL;
                    NSURL *iconURL = [NSURL URLWithString:iconURLString];

                    if (section) proxyPackage.section = section;
                    if (iconURL) proxyPackage.iconURL = iconURL;

                    [searchResults addObject:proxyPackage];
                }
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        [self closeDatabase];

        return [self cleanUpDuplicatePackages:searchResults];
    } else {
        [self printDatabaseError];
    }
    return NULL;
}

- (NSArray <NSArray <NSString *> *> * _Nullable)searchForAuthorName:(NSString *)authorName fullSearch:(BOOL)fullSearch {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *searchResults = [NSMutableArray new];
        NSString *limit = fullSearch ? @"" : @"LIMIT 30";
        NSString *query = [NSString stringWithFormat:@"SELECT AUTHORNAME, AUTHOREMAIL FROM PACKAGES "
                           @"WHERE AUTHORNAME LIKE ? ESCAPE '\\' AND REPOID > -1 "
                           @"GROUP BY AUTHORNAME "
                           @"ORDER BY %@, (CASE "
                                @"WHEN AUTHORNAME = ? THEN 1 "
                                @"WHEN AUTHORNAME LIKE ? ESCAPE '\\' THEN 2 "
                                @"ELSE 3 "
                                @"END"
                           @") COLLATE NOCASE "
                           @"%@",
                           self._packageArchitectureWeightingClause, limit];

        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            NSString *authorNameLike = [self _escapeLikeString:authorName];
            sqlite3_bind_text(statement, 1, [[NSString stringWithFormat:@"%%%@%%", authorNameLike] UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 2, [authorName UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 3, [[NSString stringWithFormat:@"%@%%", authorNameLike] UTF8String], -1, SQLITE_TRANSIENT);

            while (sqlite3_step(statement) == SQLITE_ROW) {
                const char *authorChars = (const char *)sqlite3_column_text(statement, 0);
                const char *emailChars = (const char *)sqlite3_column_text(statement, 1);

                NSString *author = authorChars != 0 ? [NSString stringWithUTF8String:authorChars] : NULL;
                NSString *email = emailChars != 0 ? [NSString stringWithUTF8String:emailChars] : NULL;

                if (author || email) {
                    [searchResults addObject:@[author ?: email, email ?: author]];
                }
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        [self closeDatabase];

        return searchResults;
    } else {
        [self printDatabaseError];
    }
    return NULL;
}

- (NSArray <NSString *> * _Nullable)searchForAuthorFromEmail:(NSString *)authorEmail fullSearch:(BOOL)fullSearch {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *searchResults = [NSMutableArray new];
        NSString *limit = fullSearch ? @"" : @" LIMIT 30";
        NSString *query = [NSString stringWithFormat:@"SELECT AUTHORNAME, AUTHOREMAIL FROM PACKAGES "
                           @"WHERE AUTHOREMAIL = ? AND REPOID > -1 "
                           @"GROUP BY AUTHORNAME COLLATE NOCASE "
                           @"ORDER BY %@ "
                           @"%@",
                           self._packageArchitectureWeightingClause, limit];

        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_text(statement, 1, [authorEmail UTF8String], -1, SQLITE_TRANSIENT);

            while (sqlite3_step(statement) == SQLITE_ROW) {
                const char *authorChars = (const char *)sqlite3_column_text(statement, 0);
                const char *emailChars = (const char *)sqlite3_column_text(statement, 1);

                NSString *author = authorChars != 0 ? [NSString stringWithUTF8String:authorChars] : NULL;
                NSString *email = emailChars != 0 ? [NSString stringWithUTF8String:emailChars] : NULL;

                if (author && email) {
                    [searchResults addObject:@[author, email]];
                }
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        [self closeDatabase];

        return searchResults;
    } else {
        [self printDatabaseError];
    }
    return NULL;
}

- (NSArray <ZBPackage *> * _Nullable)packagesFromIdentifiers:(NSArray <NSString *> *)requestedPackages {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *packages = [NSMutableArray new];
        NSMutableArray *inTemplates = [NSMutableArray new];
        for (int i = 0; i < requestedPackages.count; i++) {
            [inTemplates addObject:@"?"];
        }

        NSString *query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES "
                           @"WHERE PACKAGE IN (%@) "
                           @"ORDER BY %@, NAME COLLATE NOCASE ASC",
                           [inTemplates componentsJoinedByString:@","], self._packageArchitectureWeightingClause];
        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            for (int i = 0; i < requestedPackages.count; i++) {
                sqlite3_bind_text(statement, i + 1, [requestedPackages[i] UTF8String], -1, SQLITE_TRANSIENT);
            }

            while (sqlite3_step(statement) == SQLITE_ROW) {
                ZBPackage *package = [[ZBPackage alloc] initWithSQLiteStatement:statement];

                [packages addObject:package];
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        [self closeDatabase];

        return [self cleanUpDuplicatePackages:packages];
    } else {
        [self printDatabaseError];
    }
    return NULL;
}

- (ZBPackage * _Nullable)packageFromProxy:(ZBProxyPackage *)proxy {
    if ([self openDatabase] == SQLITE_OK) {
        NSString *query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES "
                           @"WHERE PACKAGE = ? AND VERSION = ? AND REPOID = ? "
                           @"ORDER BY %@ "
                           @"LIMIT 1",
                           self._packageArchitectureWeightingClause];

        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, query.UTF8String, -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_text(statement, 1, [proxy.identifier UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 2, [proxy.version UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_int(statement, 3, proxy.sourceID);

            sqlite3_step(statement);

            ZBPackage *package = [[ZBPackage alloc] initWithSQLiteStatement:statement];
            sqlite3_finalize(statement);
            [self closeDatabase];

            return package;
        }
        else {
            [self printDatabaseError];
            sqlite3_finalize(statement);
            [self closeDatabase];
        }
    }
    else {
        [self printDatabaseError];
    }
    return NULL;
}

#pragma mark - Package status

- (BOOL)packageIDHasUpdate:(NSString *)packageIdentifier {
    if ([upgradePackageIDs count] != 0) {
        return [upgradePackageIDs containsObject:packageIdentifier];
    } else {
        if ([self openDatabase] == SQLITE_OK) {
            BOOL packageIsInstalled = NO;
            NSString *query = @"SELECT PACKAGE FROM UPDATES "
                              @"WHERE PACKAGE = ? AND IGNORE = 0 "
                              @"LIMIT 1";
            sqlite3_stmt *statement = NULL;
            if (sqlite3_prepare_v2(database, query.UTF8String, -1, &statement, nil) == SQLITE_OK) {
                sqlite3_bind_text(statement, 1, [packageIdentifier UTF8String], -1, SQLITE_TRANSIENT);
                while (sqlite3_step(statement) == SQLITE_ROW) {
                    packageIsInstalled = YES;
                    break;
                }
            } else {
                [self printDatabaseError];
            }
            sqlite3_finalize(statement);
            [self closeDatabase];

            return packageIsInstalled;
        } else {
            [self printDatabaseError];
        }
        return NO;
    }
}

- (BOOL)packageHasUpdate:(ZBPackage *)package {
    return [self packageIDHasUpdate:package.identifier];
}

- (BOOL)packageIDIsInstalled:(NSString *)packageIdentifier version:(NSString *_Nullable)version {
    if (version == NULL && [installedPackageIDs count] != 0) {
        BOOL packageIsInstalled = [[installedPackageIDs copy] containsObject:packageIdentifier];
        ZBLog(@"[Zebra] [installedPackageIDs] Is %@ (version: %@) installed? : %d", packageIdentifier, version, packageIsInstalled);
        if (packageIsInstalled) {
            return packageIsInstalled;
        }
    }
    if ([self openDatabase] == SQLITE_OK) {
        NSString *versionQuery = version ? @"AND VERSION = ?" : @"";
        NSString *query = [NSString stringWithFormat:@"SELECT PACKAGE FROM PACKAGES "
                           @"WHERE PACKAGE = ? %@ AND REPOID < 1 "
                           @"ORDER BY %@ "
                           @"LIMIT 1",
                           versionQuery, self._packageArchitectureWeightingClause];

        BOOL packageIsInstalled = NO;
        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_text(statement, 1, [packageIdentifier UTF8String], -1, SQLITE_TRANSIENT);
            if (version) {
                sqlite3_bind_text(statement, 2, [version UTF8String], -1, SQLITE_TRANSIENT);
            }

            while (sqlite3_step(statement) == SQLITE_ROW) {
                packageIsInstalled = YES;
                break;
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        [self closeDatabase];

        ZBLog(@"[Zebra] Is %@ (version: %@) installed? : %d", packageIdentifier, version, packageIsInstalled);
        return packageIsInstalled;
    } else {
        [self printDatabaseError];
    }
    return NO;
}

- (BOOL)packageIsInstalled:(ZBPackage *)package versionStrict:(BOOL)strict {
    return [self packageIDIsInstalled:package.identifier version:strict ? package.version : NULL];
}

- (BOOL)packageIDIsAvailable:(NSString *)packageIdentifier version:(NSString *_Nullable)version {
    if ([self openDatabase] == SQLITE_OK) {
        BOOL packageIsAvailable = NO;
        NSString *query = [NSString stringWithFormat:@"SELECT PACKAGE FROM PACKAGES "
                           @"WHERE PACKAGE = ? AND REPOID > 0 "
                           @"ORDER BY %@ "
                           @"LIMIT 1",
                           self._packageArchitectureWeightingClause];
        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, query.UTF8String, -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_text(statement, 1, [packageIdentifier UTF8String], -1, SQLITE_TRANSIENT);
            while (sqlite3_step(statement) == SQLITE_ROW) {
                packageIsAvailable = YES;
                break;
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);

        [self closeDatabase];
        return packageIsAvailable;
    } else {
        [self printDatabaseError];
    }
    return NO;
}

- (BOOL)packageIsAvailable:(ZBPackage *)package versionStrict:(BOOL)strict {
    return [self packageIDIsAvailable:package.identifier version:strict ? package.version : NULL];
}

- (ZBPackage * _Nullable)packageForID:(NSString *)identifier equalVersion:(NSString *)version {
    if ([self openDatabase] == SQLITE_OK) {
        ZBPackage *package = nil;
        NSString *query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES "
                           @"WHERE PACKAGE = ? AND VERSION = ? "
                           @"ORDER BY %@ "
                           @"LIMIT 1",
                           self._packageArchitectureWeightingClause];
        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, query.UTF8String, -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_text(statement, 1, [identifier UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 2, [version UTF8String], -1, SQLITE_TRANSIENT);
            while (sqlite3_step(statement) == SQLITE_ROW) {
                package = [[ZBPackage alloc] initWithSQLiteStatement:statement];
                break;
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);

        [self closeDatabase];
        return package;
    } else {
        [self printDatabaseError];
    }
    return nil;
}

- (BOOL)areUpdatesIgnoredForPackage:(ZBPackage *)package {
    return [self areUpdatesIgnoredForPackageIdentifier:[package identifier]];
}

- (BOOL)areUpdatesIgnoredForPackageIdentifier:(NSString *)identifier {
    if ([self openDatabase] == SQLITE_OK) {
        BOOL ignored = NO;
        char *query = "SELECT IGNORE FROM UPDATES "
                      "WHERE PACKAGE = ? "
                      "LIMIT 1";
        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_text(statement, 1, [identifier UTF8String], -1, SQLITE_TRANSIENT);
            while (sqlite3_step(statement) == SQLITE_ROW) {
                if (sqlite3_column_int(statement, 0) == 1)
                    ignored = YES;
                break;
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);

        [self closeDatabase];
        return ignored;
    } else {
        [self printDatabaseError];
    }
    return NO;
}

- (void)setUpdatesIgnored:(BOOL)ignore forPackage:(ZBPackage *)package {
    if ([self openDatabase] == SQLITE_OK) {
        char *query = "REPLACE INTO UPDATES (PACKAGE, VERSION, IGNORE) "
                      "VALUES (?, ?, ?)";

        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_text(statement, 1, [package.identifier UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 2, [package.version UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_int(statement, 3, ignore ? 1 : 0);

            while (sqlite3_step(statement) == SQLITE_ROW) {
                break;
            }
        } else {
            NSLog(@"[Zebra] Error preparing setting package ignore updates statement: %s", sqlite3_errmsg(database));
        }
        sqlite3_finalize(statement);

        [self closeDatabase];
    } else {
        [self printDatabaseError];
    }
}

#pragma mark - Package lookup

- (ZBPackage * _Nullable)packageThatProvides:(NSString *)identifier thatSatisfiesComparison:(NSString *)comparison ofVersion:(NSString *)version {
    return [self packageThatProvides:identifier thatSatisfiesComparison:comparison ofVersion:version thatIsNot:NULL];
}

- (ZBPackage * _Nullable)packageThatProvides:(NSString *)packageIdentifier thatSatisfiesComparison:(NSString *)comparison ofVersion:(NSString *)version thatIsNot:(ZBPackage * _Nullable)exclude {
    if ([self openDatabase] == SQLITE_OK) {
        packageIdentifier = [packageIdentifier lowercaseString];
        NSString *packageIDLike = [self _escapeLikeString:packageIdentifier];
        const char *firstSearchTerm   = [[NSString stringWithFormat:@"%%, %@ (%%", packageIDLike] UTF8String];
        const char *secondSearchTerm  = [[NSString stringWithFormat:@"%%, %@, %%", packageIDLike] UTF8String];
        const char *thirdSearchTerm   = [[NSString stringWithFormat:@"%@ (%%",     packageIDLike] UTF8String];
        const char *fourthSearchTerm  = [[NSString stringWithFormat:@"%@, %%",     packageIDLike] UTF8String];
        const char *fifthSearchTerm   = [[NSString stringWithFormat:@"%%, %@",     packageIDLike] UTF8String];
        const char *sixthSearchTerm   = [[NSString stringWithFormat:@"%%| %@",     packageIDLike] UTF8String];
        const char *seventhSearchTerm = [[NSString stringWithFormat:@"%%, %@ |%%", packageIDLike] UTF8String];
        const char *eighthSearchTerm  = [[NSString stringWithFormat:@"%@ |%%",     packageIDLike] UTF8String];

        NSString *excludeQuery = exclude ? @"PACKAGE != ? AND" : @"";
        NSString *query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES "
                           @"WHERE %@ REPOID > 0 AND ("
                                @"PROVIDES LIKE ? ESCAPE '\\' OR PROVIDES LIKE ? ESCAPE '\\' OR PROVIDES LIKE ? ESCAPE '\\' OR PROVIDES LIKE ? ESCAPE '\\' OR PROVIDES LIKE ? ESCAPE '\\' OR PROVIDES LIKE ? ESCAPE '\\' OR PROVIDES LIKE ? ESCAPE '\\' OR PROVIDES LIKE ? ESCAPE '\\'"
                           @") AND %@ "
                           @"ORDER BY %@ "
                           @"LIMIT 1",
                           excludeQuery, self._installablePackageArchitectureClause, self._packageArchitectureWeightingClause];

        NSMutableArray <ZBPackage *> *packages = [NSMutableArray new];
        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, query.UTF8String, -1, &statement, nil) == SQLITE_OK) {
            int offset = exclude ? 1 : 0;
            if (exclude) {
                sqlite3_bind_text(statement, 1, [packageIdentifier UTF8String], -1, SQLITE_TRANSIENT);
            }
            sqlite3_bind_text(statement, offset + 1, firstSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, offset + 2, secondSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, offset + 3, thirdSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, offset + 4, fourthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, offset + 5, fifthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, offset + 6, sixthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, offset + 7, seventhSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, offset + 8, eighthSearchTerm, -1, SQLITE_TRANSIENT);

            while (sqlite3_step(statement) == SQLITE_ROW) {
                const char *providesLine = (const char *)sqlite3_column_text(statement, ZBPackageColumnProvides);
                if (providesLine != 0) {
                    NSString *provides = [[NSString stringWithUTF8String:providesLine] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    NSArray *virtualPackages = [provides componentsSeparatedByString:@","];

                    for (NSString *virtualPackage in virtualPackages) {
                        NSArray *versionComponents = [ZBDependencyResolver separateVersionComparison:[virtualPackage stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
                        if ([versionComponents[0] isEqualToString:packageIdentifier] &&
                            ([versionComponents[2] isEqualToString:@"0:0"] || [ZBDependencyResolver doesVersion:versionComponents[2] satisfyComparison:comparison ofVersion:version])) {
                            ZBPackage *package = [[ZBPackage alloc] initWithSQLiteStatement:statement];
                            [packages addObject:package];
                            break;
                        }
                    }
                }
            }
        } else {
            [self printDatabaseError];
            return NULL;
        }
        sqlite3_finalize(statement);

        [self closeDatabase];
        return [packages count] ? packages[0] : NULL; //Returns the first package in the array, we could use interactive dependency resolution in the future
    } else {
        [self printDatabaseError];
    }
    return NULL;
}

- (ZBPackage * _Nullable)installedPackageThatProvides:(NSString *)identifier thatSatisfiesComparison:(NSString *)comparison ofVersion:(NSString *)version {
    return [self installedPackageThatProvides:identifier thatSatisfiesComparison:comparison ofVersion:version thatIsNot:NULL];
}

- (ZBPackage * _Nullable)installedPackageThatProvides:(NSString *)packageIdentifier thatSatisfiesComparison:(NSString *)comparison ofVersion:(NSString *)version thatIsNot:(ZBPackage *_Nullable)exclude {
    if ([self openDatabase] == SQLITE_OK) {
        NSString *excludeQuery = exclude ? @"PACKAGE != ? AND" : @"";
        NSString *query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES "
                           @"WHERE %@ REPOID = 0 AND ("
                                @"PROVIDES LIKE ? ESCAPE '\\' OR PROVIDES LIKE ? ESCAPE '\\' OR PROVIDES LIKE ? ESCAPE '\\' OR PROVIDES LIKE ? ESCAPE '\\' OR PROVIDES LIKE ? ESCAPE '\\' OR PROVIDES LIKE ? ESCAPE '\\' OR PROVIDES LIKE ? ESCAPE '\\' OR PROVIDES LIKE ? ESCAPE '\\'"
                           @") "
                           @"LIMIT 1",
                           excludeQuery];

        NSString *packageIDLike = [self _escapeLikeString:packageIdentifier];
        const char *firstSearchTerm   = [[NSString stringWithFormat:@"%%, %@ (%%", packageIDLike] UTF8String];
        const char *secondSearchTerm  = [[NSString stringWithFormat:@"%%, %@, %%", packageIDLike] UTF8String];
        const char *thirdSearchTerm   = [[NSString stringWithFormat:@"%@ (%%",     packageIDLike] UTF8String];
        const char *fourthSearchTerm  = [[NSString stringWithFormat:@"%@, %%",     packageIDLike] UTF8String];
        const char *fifthSearchTerm   = [[NSString stringWithFormat:@"%%, %@",     packageIDLike] UTF8String];
        const char *sixthSearchTerm   = [[NSString stringWithFormat:@"%%| %@",     packageIDLike] UTF8String];
        const char *seventhSearchTerm = [[NSString stringWithFormat:@"%%, %@ |%%", packageIDLike] UTF8String];
        const char *eighthSearchTerm  = [[NSString stringWithFormat:@"%@ |%%",     packageIDLike] UTF8String];

        NSMutableArray <ZBPackage *> *packages = [NSMutableArray new];
        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, query.UTF8String, -1, &statement, nil) == SQLITE_OK) {
            int offset = exclude ? 1 : 0;
            if (exclude) {
                sqlite3_bind_text(statement, 1, [packageIdentifier UTF8String], -1, SQLITE_TRANSIENT);
            }
            sqlite3_bind_text(statement, offset + 1, firstSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, offset + 2, secondSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, offset + 3, thirdSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, offset + 4, fourthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, offset + 5, fifthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, offset + 6, sixthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, offset + 7, seventhSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, offset + 8, eighthSearchTerm, -1, SQLITE_TRANSIENT);

            while (sqlite3_step(statement) == SQLITE_ROW) {
                ZBPackage *package = [[ZBPackage alloc] initWithSQLiteStatement:statement];
                [packages addObject:package];
            }
        } else {
            [self printDatabaseError];
            return NULL;
        }
        sqlite3_finalize(statement);

        for (ZBPackage *package in packages) {
            //If there is a comparison and a version then we return the first package that satisfies this comparison, otherwise we return the first package we see
            //(this also sets us up better later for interactive dependency resolution)
            if (comparison && version && [ZBDependencyResolver doesPackage:package satisfyComparison:comparison ofVersion:version]) {
                [self closeDatabase];
                return package;
            }
            else if (!comparison || !version) {
                [self closeDatabase];
                return package;
            }
        }

        [self closeDatabase];
    } else {
        [self printDatabaseError];
    }
    return NULL;
}

- (ZBPackage * _Nullable)packageForIdentifier:(NSString *)identifier thatSatisfiesComparison:(NSString * _Nullable)comparison ofVersion:(NSString * _Nullable)version {
    return [self packageForIdentifier:identifier thatSatisfiesComparison:comparison ofVersion:version includeVirtualPackages:YES];
}

- (ZBPackage * _Nullable)packageForIdentifier:(NSString *)identifier thatSatisfiesComparison:(NSString * _Nullable)comparison ofVersion:(NSString * _Nullable)version includeVirtualPackages:(BOOL)checkVirtual {
    if ([self openDatabase] == SQLITE_OK) {
        ZBPackage *package = nil;
        NSString *query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES "
                           @"WHERE PACKAGE = ? COLLATE NOCASE AND REPOID > 0 "
                           @"ORDER BY %@ "
                           @"LIMIT 1",
                           self._packageArchitectureWeightingClause];
        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, query.UTF8String, -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_text(statement, 1, [identifier UTF8String], -1, SQLITE_TRANSIENT);
            while (sqlite3_step(statement) == SQLITE_ROW) {
                package = [[ZBPackage alloc] initWithSQLiteStatement:statement];
                break;
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);

        // Only try to resolve "Provides" if we can't resolve the normal package.
        if (checkVirtual && package == NULL) {
            package = [self packageThatProvides:identifier thatSatisfiesComparison:comparison ofVersion:version]; //there is a scenario here where two packages that provide a package could be found (ex: anemone, snowboard, and ithemer all provide winterboard) we need to ask the user which one to pick.
        }

        if (package != NULL) {
            NSArray *otherVersions = [self allVersionsForPackage:package];
            if (version != NULL && comparison != NULL) {
                if ([otherVersions count] > 1) {
                    for (ZBPackage *package in otherVersions) {
                        if ([ZBDependencyResolver doesPackage:package satisfyComparison:comparison ofVersion:version]) {
                            [self closeDatabase];
                            return package;
                        }
                    }

                    [self closeDatabase];
                    return NULL;
                }
                [self closeDatabase];
                return [ZBDependencyResolver doesPackage:otherVersions[0] satisfyComparison:comparison ofVersion:version] ? otherVersions[0] : NULL;
            }
            return otherVersions.firstObject;
        }

        [self closeDatabase];
    } else {
        [self printDatabaseError];
    }
    return NULL;
}

- (ZBPackage * _Nullable)installedPackageForIdentifier:(NSString *)identifier thatSatisfiesComparison:(NSString * _Nullable)comparison ofVersion:(NSString * _Nullable)version {
    return [self installedPackageForIdentifier:identifier thatSatisfiesComparison:comparison ofVersion:version includeVirtualPackages:YES thatIsNot:NULL];
}

- (ZBPackage * _Nullable)installedPackageForIdentifier:(NSString *)identifier thatSatisfiesComparison:(NSString * _Nullable)comparison ofVersion:(NSString * _Nullable)version includeVirtualPackages:(BOOL)checkVirtual {
    return [self installedPackageForIdentifier:identifier thatSatisfiesComparison:comparison ofVersion:version includeVirtualPackages:checkVirtual thatIsNot:NULL];
}

- (ZBPackage * _Nullable)installedPackageForIdentifier:(NSString *)identifier thatSatisfiesComparison:(NSString * _Nullable)comparison ofVersion:(NSString * _Nullable)version includeVirtualPackages:(BOOL)checkVirtual thatIsNot:(ZBPackage *_Nullable)exclude {
    if ([self openDatabase] == SQLITE_OK) {
        NSString *excludeQuery = exclude ? @"AND PACKAGE != ?" : @"";
        NSString *query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES "
                           @"WHERE PACKAGE = ? COLLATE NOCASE AND REPOID = 0 %@ "
                           @"LIMIT 1",
                           excludeQuery];

        ZBPackage *package;
        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_text(statement, 1, [identifier UTF8String], -1, SQLITE_TRANSIENT);
            if (exclude) {
                sqlite3_bind_text(statement, 2, [exclude.identifier UTF8String], -1, SQLITE_TRANSIENT);
            }

            while (sqlite3_step(statement) == SQLITE_ROW) {
                package = [[ZBPackage alloc] initWithSQLiteStatement:statement];
                break;
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);

        // Only try to resolve "Provides" if we can't resolve the normal package.
        if (checkVirtual && package == NULL) {
            package = [self installedPackageThatProvides:identifier thatSatisfiesComparison:comparison ofVersion:version thatIsNot:exclude]; //there is a scenario here where two packages that provide a package could be found (ex: anemone, snowboard, and ithemer all provide winterboard) we need to ask the user which one to pick.
        }

        if (package != NULL) {
            [self closeDatabase];
            if (version != NULL && comparison != NULL) {
                return [ZBDependencyResolver doesPackage:package satisfyComparison:comparison ofVersion:version] ? package : NULL;
            }
            return package;
        }

        [self closeDatabase];
    } else {
        [self printDatabaseError];
    }
    return NULL;
}

- (NSArray * _Nullable)allVersionsForPackage:(ZBPackage *)package {
    return [self allVersionsForPackageID:package.identifier inSource:NULL];
}

- (NSArray * _Nullable)allVersionsForPackageID:(NSString *)packageIdentifier {
    return [self allVersionsForPackageID:packageIdentifier inSource:NULL];
}

- (NSArray * _Nullable)allVersionsForPackage:(ZBPackage *)package inSource:(ZBSource *_Nullable)source {
    return [self allVersionsForPackageID:package.identifier inSource:source];
}

- (NSArray * _Nullable)allVersionsForPackageID:(NSString *)packageIdentifier inSource:(ZBSource *_Nullable)source {
    return [self allVersionsForPackageID:packageIdentifier inSource:source filteringArchitectures:YES];
}

- (NSArray * _Nullable)allVersionsForPackageID:(NSString *)packageIdentifier inSource:(ZBSource *_Nullable)source filteringArchitectures:(BOOL)filteringArchitectures {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *allVersions = [NSMutableArray new];

        NSString *repoQuery = source ? @"AND REPOID = ?" : @"";
        NSString *query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES "
                           @"WHERE PACKAGE = ? %@ AND %@ "
                           @"ORDER BY %@",
                           repoQuery,
                           filteringArchitectures ? self._userArchitectureFilteringClause : @"(1=1)",
                           self._packageArchitectureWeightingClause];
        sqlite3_stmt *statement = NULL;

        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_text(statement, 1, [packageIdentifier UTF8String], -1, SQLITE_TRANSIENT);
            if (source != NULL) {
                sqlite3_bind_int(statement, 2, [source sourceID]);
            }
        }
        while (sqlite3_step(statement) == SQLITE_ROW) {
            ZBPackage *package = [[ZBPackage alloc] initWithSQLiteStatement:statement];

            [allVersions addObject:package];
        }
        sqlite3_finalize(statement);

        NSSortDescriptor *sort = [NSSortDescriptor sortDescriptorWithKey:@"self" ascending:NO];
        NSArray *sorted = [allVersions sortedArrayUsingDescriptors:@[sort]];
        [self closeDatabase];

        return sorted;
    } else {
        [self printDatabaseError];
    }
    return NULL;
}

- (NSArray * _Nullable)otherVersionsForPackage:(ZBPackage *)package {
    return [self otherVersionsForPackageID:package.identifier version:package.version];
}

- (NSArray * _Nullable)otherVersionsForPackageID:(NSString *)packageIdentifier version:(NSString *)version {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *otherVersions = [NSMutableArray new];

        NSString *query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES "
                           @"WHERE PACKAGE = ? AND VERSION != ? AND %@"
                           @"ORDER BY %@",
                           self._userArchitectureFilteringClause,
                           self._packageArchitectureWeightingClause];
        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, query.UTF8String, -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_text(statement, 1, [packageIdentifier UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 2, [version UTF8String], -1, SQLITE_TRANSIENT);
        }
        while (sqlite3_step(statement) == SQLITE_ROW) {
            int sourceID = sqlite3_column_int(statement, ZBPackageColumnSourceID);
            if (sourceID > 0) {
                ZBPackage *package = [[ZBPackage alloc] initWithSQLiteStatement:statement];

                [otherVersions addObject:package];
            }
        }
        sqlite3_finalize(statement);

        NSSortDescriptor *sort = [NSSortDescriptor sortDescriptorWithKey:@"self" ascending:NO];
        NSArray *sorted = [otherVersions sortedArrayUsingDescriptors:@[sort]];
        [self closeDatabase];

        return sorted;
    } else {
        [self printDatabaseError];
    }
    return NULL;
}

- (NSArray * _Nullable)packagesByAuthorName:(NSString *)name email:(NSString *_Nullable)email fullSearch:(BOOL)fullSearch {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *searchResults = [NSMutableArray new];

        sqlite3_stmt *statement = NULL;
        NSString *columns = fullSearch ? @"*" : @"PACKAGE, NAME, VERSION, ARCHITECTURE, REPOID, SECTION, ICONURL";
        NSString *emailMatch = email ? @" AND AUTHOREMAIL = ?" : @"";
        NSString *limit = fullSearch ? @"" : @" LIMIT 30";
        NSString *query = [NSString stringWithFormat:@"SELECT %@ FROM PACKAGES "
                           @"WHERE AUTHORNAME = ? OR AUTHORNAME LIKE ? ESCAPE '\\' %@ "
                           @"ORDER BY %@ "
                           @"%@",
                           columns, emailMatch, self._packageArchitectureWeightingClause, limit];
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            NSString *nameLike = [self _escapeLikeString:name];
            sqlite3_bind_text(statement, 1, [name UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 2, [[NSString stringWithFormat:@"%%%@%%", nameLike] UTF8String], -1, SQLITE_TRANSIENT);
            if (email) sqlite3_bind_text(statement, 2, [email UTF8String], -1, SQLITE_TRANSIENT);

            while (sqlite3_step(statement) == SQLITE_ROW) {
                if (fullSearch) {
                    const char *packageIDChars = (const char *)sqlite3_column_text(statement, 0);
                    if (packageIDChars != 0) {
                        NSString *packageID = [NSString stringWithUTF8String:packageIDChars];
                        ZBPackage *package = [self topVersionForPackageID:packageID];
                        if (package) [searchResults addObject:package];
                    }
                }
                else {
                    ZBProxyPackage *proxyPackage = [[ZBProxyPackage alloc] initWithSQLiteStatement:statement];

                    const char *sectionChars = (const char *)sqlite3_column_text(statement, 5);
                    const char *iconURLChars = (const char *)sqlite3_column_text(statement, 6);

                    NSString *section = sectionChars != 0 ? [NSString stringWithUTF8String:sectionChars] : NULL;
                    NSString *iconURLString = iconURLChars != 0 ? [NSString stringWithUTF8String:iconURLChars] : NULL;
                    NSURL *iconURL = [NSURL URLWithString:iconURLString];

                    if (section) proxyPackage.section = section;
                    if (iconURL) proxyPackage.iconURL = iconURL;

                    [searchResults addObject:proxyPackage];
                }
            }
        }
        sqlite3_finalize(statement);

        [self closeDatabase];

        return [self cleanUpDuplicatePackages:searchResults];
    } else {
        [self printDatabaseError];
    }
    return NULL;
}

- (NSArray * _Nullable)packagesWithDescription:(NSString *)description fullSearch:(BOOL)fullSearch {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *searchResults = [NSMutableArray new];

        sqlite3_stmt *statement = NULL;
        NSString *columns = fullSearch ? @"*" : @"PACKAGE, NAME, VERSION, ARCHITECTURE, REPOID, SECTION, ICONURL";
        NSString *limit = fullSearch ? @"" : @" LIMIT 30";
        NSString *query = [NSString stringWithFormat:@"SELECT %@ FROM PACKAGES "
                           @"WHERE SHORTDESCRIPTION LIKE ? ESCAPE '\\' "
                           @"ORDER BY %@ "
                           @"%@",
                           columns, self._packageArchitectureWeightingClause, limit];
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            NSString *descriptionLike = [self _escapeLikeString:description];
            sqlite3_bind_text(statement, 1, [[NSString stringWithFormat:@"%%%@%%", descriptionLike] UTF8String], -1, SQLITE_TRANSIENT);

            while (sqlite3_step(statement) == SQLITE_ROW) {
                if (fullSearch) {
                    const char *packageIDChars = (const char *)sqlite3_column_text(statement, 0);
                    if (packageIDChars != 0) {
                        NSString *packageID = [NSString stringWithUTF8String:packageIDChars];
                        ZBPackage *package = [self topVersionForPackageID:packageID];
                        if (package) [searchResults addObject:package];
                    }
                }
                else {
                    ZBProxyPackage *proxyPackage = [[ZBProxyPackage alloc] initWithSQLiteStatement:statement];

                    const char *sectionChars = (const char *)sqlite3_column_text(statement, 5);
                    const char *iconURLChars = (const char *)sqlite3_column_text(statement, 6);

                    NSString *section = sectionChars != 0 ? [NSString stringWithUTF8String:sectionChars] : NULL;
                    NSString *iconURLString = iconURLChars != 0 ? [NSString stringWithUTF8String:iconURLChars] : NULL;
                    NSURL *iconURL = [NSURL URLWithString:iconURLString];

                    if (section) proxyPackage.section = section;
                    if (iconURL) proxyPackage.iconURL = iconURL;

                    [searchResults addObject:proxyPackage];
                }
            }
        }
        sqlite3_finalize(statement);

        [self closeDatabase];

        return [self cleanUpDuplicatePackages:searchResults];
    } else {
        [self printDatabaseError];
    }
    return NULL;
}

- (NSArray * _Nullable)packagesWithReachableIcon:(int)limit excludeFrom:(NSArray <ZBSource *> *_Nullable)blacklistedSources {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *packages = [NSMutableArray new];

        NSMutableArray *sourceTemplates = [NSMutableArray array];
        for (int i = 0; i < blacklistedSources.count; i++) {
            [sourceTemplates addObject:@"?"];
        }

        NSString *query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES "
                           @"WHERE REPOID NOT IN (-1, 0, %@) AND ICONURL IS NOT NULL AND %@ "
                           @"ORDER BY RANDOM() "
                           @"LIMIT %d",
                           [sourceTemplates componentsJoinedByString:@","], self._installablePackageArchitectureClause, limit];

        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            for (int i = 0; i < blacklistedSources.count; i++) {
                sqlite3_bind_int(statement, i + 1, blacklistedSources[i].sourceID);
            }

            while (sqlite3_step(statement) == SQLITE_ROW) {
                ZBPackage *package = [[ZBPackage alloc] initWithSQLiteStatement:statement];
                [packages addObject:package];
            }
        }
        [self closeDatabase];
        return [self cleanUpDuplicatePackages:packages];
    } else {
        [self printDatabaseError];
    }
    return NULL;
}

- (nullable ZBPackage *)topVersionForPackage:(ZBPackage *)package filteringArch:(Boolean)filteringArch {
    NSArray *allVersions = [self allVersionsForPackageID:package.identifier inSource:NULL filteringArchitectures:filteringArch];
    return allVersions.firstObject;
}

- (nullable ZBPackage *)topVersionForPackage:(ZBPackage *)package {
    return [self topVersionForPackage:package inSource:NULL];
}

- (nullable ZBPackage *)topVersionForPackageID:(NSString *)packageIdentifier {
    return [self topVersionForPackageID:packageIdentifier inSource:NULL];
}

- (nullable ZBPackage *)topVersionForPackage:(ZBPackage *)package inSource:(ZBSource *_Nullable)source {
    return [self topVersionForPackageID:package.identifier inSource:source];
}

- (nullable ZBPackage *)topVersionForPackageID:(NSString *)packageIdentifier inSource:(ZBSource *_Nullable)source {
    NSArray *allVersions = [self allVersionsForPackageID:packageIdentifier inSource:source filteringArchitectures:NO];
    return allVersions.firstObject;
}

- (NSArray <ZBPackage *> * _Nullable)packagesThatDependOn:(ZBPackage *)package {
    return [self packagesThatDependOnPackageIdentifier:[package identifier] removedPackage:package];
}

- (NSArray <ZBPackage *> * _Nullable)packagesThatDependOnPackageIdentifier:(NSString *)packageIdentifier removedPackage:(ZBPackage *)package {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *packages = [NSMutableArray new];

        NSString *packageIDLike = [self _escapeLikeString:package.identifier];
        const char *firstSearchTerm   = [[NSString stringWithFormat:@"%%, %@ (%%", packageIDLike] UTF8String];
        const char *secondSearchTerm  = [[NSString stringWithFormat:@"%%, %@, %%", packageIDLike] UTF8String];
        const char *thirdSearchTerm   = [[NSString stringWithFormat:@"%@ (%%",     packageIDLike] UTF8String];
        const char *fourthSearchTerm  = [[NSString stringWithFormat:@"%@, %%",     packageIDLike] UTF8String];
        const char *fifthSearchTerm   = [[NSString stringWithFormat:@"%%, %@",     packageIDLike] UTF8String];
        const char *sixthSearchTerm   = [[NSString stringWithFormat:@"%%| %@",     packageIDLike] UTF8String];
        const char *seventhSearchTerm = [[NSString stringWithFormat:@"%%, %@ |%%", packageIDLike] UTF8String];
        const char *eighthSearchTerm  = [[NSString stringWithFormat:@"%@ |%%",     packageIDLike] UTF8String];

        const char *query = "SELECT * FROM PACKAGES WHERE ("
                "DEPENDS LIKE ? ESCAPE '\\' OR DEPENDS LIKE ? ESCAPE '\\' OR DEPENDS LIKE ? ESCAPE '\\' OR DEPENDS LIKE ? ESCAPE '\\' OR DEPENDS LIKE ? ESCAPE '\\' OR DEPENDS LIKE ? ESCAPE '\\' OR DEPENDS LIKE ? ESCAPE '\\' OR DEPENDS LIKE ? ESCAPE '\\' OR DEPENDS = ?"
            ") AND REPOID = 0";
        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_text(statement, 1, firstSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 2, secondSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 3, thirdSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 4, fourthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 5, fifthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 6, sixthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 7, seventhSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 8, eighthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 9, [packageIdentifier UTF8String], -1, SQLITE_TRANSIENT);

            while (sqlite3_step(statement) == SQLITE_ROW) {
                const char *dependsChars = (const char *)sqlite3_column_text(statement, ZBPackageColumnDepends);
                NSString *depends = dependsChars != 0 ? [NSString stringWithUTF8String:dependsChars] : NULL; //Depends shouldn't be NULL here but you know just in case because this can be weird
                NSArray *dependsOn = [depends componentsSeparatedByString:@", "];

                BOOL packageNeedsToBeRemoved = NO;
                for (NSString *dependsLine in dependsOn) {
                    NSError *error = NULL;
                    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"\\b%@\\b", [package identifier]] options:NSRegularExpressionCaseInsensitive error:&error];
                    if ([regex numberOfMatchesInString:dependsLine options:0 range:NSMakeRange(0, [dependsLine length])] && ![self willDependencyBeSatisfiedAfterQueueOperations:dependsLine]) { //Use regex to search with block words
                        packageNeedsToBeRemoved = YES;
                    }
                }

                if (packageNeedsToBeRemoved) {
                    ZBPackage *found = [[ZBPackage alloc] initWithSQLiteStatement:statement];
                    if ([[ZBQueue sharedQueue] locate:found] == ZBQueueTypeClear) {
                        [found setRemovedBy:package];

                        [packages addObject:found];
                    }
                }
            }
        }
        sqlite3_finalize(statement);
        [self closeDatabase];

        for (NSString *provided in [package provides]) { //If the package is removed and there is no other package that provides this dependency, we have to remove those as well
            if ([provided containsString:packageIdentifier]) continue;
            if (![[package identifier] isEqualToString:packageIdentifier] && [[package provides] containsObject:provided]) continue;
            if (![self willDependencyBeSatisfiedAfterQueueOperations:provided]) {
                [packages addObjectsFromArray:[self packagesThatDependOnPackageIdentifier:provided removedPackage:package]];
            }
        }

        return packages.count ? packages : nil;
    } else {
        [self printDatabaseError];
    }
    return NULL;
}

- (NSArray <ZBPackage *> * _Nullable)packagesThatConflictWith:(ZBPackage *)package {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *packages = [NSMutableArray new];

        NSString *packageIDLike = [self _escapeLikeString:package.identifier];
        const char *firstSearchTerm   = [[NSString stringWithFormat:@"%%, %@ (%%", packageIDLike] UTF8String];
        const char *secondSearchTerm  = [[NSString stringWithFormat:@"%%, %@, %%", packageIDLike] UTF8String];
        const char *thirdSearchTerm   = [[NSString stringWithFormat:@"%@ (%%",     packageIDLike] UTF8String];
        const char *fourthSearchTerm  = [[NSString stringWithFormat:@"%@, %%",     packageIDLike] UTF8String];
        const char *fifthSearchTerm   = [[NSString stringWithFormat:@"%%, %@",     packageIDLike] UTF8String];
        const char *sixthSearchTerm   = [[NSString stringWithFormat:@"%%| %@",     packageIDLike] UTF8String];
        const char *seventhSearchTerm = [[NSString stringWithFormat:@"%%, %@ |%%", packageIDLike] UTF8String];
        const char *eighthSearchTerm  = [[NSString stringWithFormat:@"%@ |%%",     packageIDLike] UTF8String];

        const char *query = "SELECT * FROM PACKAGES WHERE ("
                "CONFLICTS LIKE ? ESCAPE '\\' OR CONFLICTS LIKE ? ESCAPE '\\' OR CONFLICTS LIKE ? ESCAPE '\\' OR CONFLICTS LIKE ? ESCAPE '\\' OR CONFLICTS LIKE ? ESCAPE '\\' OR CONFLICTS LIKE ? ESCAPE '\\' OR CONFLICTS LIKE ? ESCAPE '\\' OR CONFLICTS LIKE ? ESCAPE '\\' OR CONFLICTS = ?"
            ") AND REPOID = 0";
        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_text(statement, 1, firstSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 2, secondSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 3, thirdSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 4, fourthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 5, fifthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 6, sixthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 7, seventhSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 8, eighthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 9, [[package identifier] UTF8String], -1, SQLITE_TRANSIENT);
            while (sqlite3_step(statement) == SQLITE_ROW) {
                ZBPackage *found = [[ZBPackage alloc] initWithSQLiteStatement:statement];
                [packages addObject:found];
            }
        }

        for (ZBPackage *conflictingPackage in [packages copy]) {
            for (NSString *conflict in [conflictingPackage conflictsWith]) {
                if (([conflict containsString:@"("] || [conflict containsString:@")"]) && [conflict containsString:[package identifier]]) {
                    NSArray *versionComparison = [ZBDependencyResolver separateVersionComparison:conflict];
                    if (![ZBDependencyResolver doesPackage:package satisfyComparison:versionComparison[1] ofVersion:versionComparison[2]]) {
                        [packages removeObject:conflictingPackage];
                    }
                }
            }
        }

        sqlite3_finalize(statement);
        [self closeDatabase];
        return packages.count ? packages : nil;
    } else {
        [self printDatabaseError];
    }
    return NULL;
}

//- (BOOL)willDependency:(NSString *_Nonnull)dependency beSatisfiedAfterTheRemovalOf:(NSArray <ZBPackage *> *)packages {
//    NSMutableArray *array = [NSMutableArray new];
//    for (ZBPackage *package in packages) {
//        [array addObject:[NSString stringWithFormat:@"\'%@\'", [package identifier]]];
//    }
//    return [self willDependency:dependency beSatisfiedAfterTheRemovalOfPackageIdentifiers:array];
//}

- (BOOL)willDependencyBeSatisfiedAfterQueueOperations:(NSString *_Nonnull)dependency {
    if ([dependency containsString:@"|"]) {
        NSArray *components = [dependency componentsSeparatedByString:@"|"];
        for (NSString *dependency in components) {
            if ([self willDependencyBeSatisfiedAfterQueueOperations:[dependency stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]]) {
                return YES;
            }
        }
    }
    else if ([self openDatabase] == SQLITE_OK) {
        ZBQueue *queue = [ZBQueue sharedQueue];
        NSArray *addedPackages =   [queue packagesQueuedForAdddition]; //Packages that are being installed, upgraded, removed, downgraded, etc. (dependencies as well)
        NSArray *removedPackages = [queue packageIDsQueuedForRemoval]; //Just packageIDs that are queued for removal (conflicts as well)

        NSArray *versionComponents = [ZBDependencyResolver separateVersionComparison:dependency];
        NSString *packageIdentifier = versionComponents[0];
        BOOL needsVersionComparison = ![versionComponents[1] isEqualToString:@"<=>"] && ![versionComponents[2] isEqualToString:@"0:0"];

        NSMutableArray <NSString *> *excludes = [NSMutableArray array];
        for (int i = 0; i < removedPackages.count; i++) {
            [excludes addObject:@"?"];
        }

        NSString *packageIDLike = [self _escapeLikeString:packageIdentifier];
        const char *firstSearchTerm   = [[NSString stringWithFormat:@"%%, %@ (%%", packageIDLike] UTF8String];
        const char *secondSearchTerm  = [[NSString stringWithFormat:@"%%, %@, %%", packageIDLike] UTF8String];
        const char *thirdSearchTerm   = [[NSString stringWithFormat:@"%@ (%%",     packageIDLike] UTF8String];
        const char *fourthSearchTerm  = [[NSString stringWithFormat:@"%@, %%",     packageIDLike] UTF8String];
        const char *fifthSearchTerm   = [[NSString stringWithFormat:@"%%, %@",     packageIDLike] UTF8String];
        const char *sixthSearchTerm   = [[NSString stringWithFormat:@"%%| %@",     packageIDLike] UTF8String];
        const char *seventhSearchTerm = [[NSString stringWithFormat:@"%%, %@ |%%", packageIDLike] UTF8String];
        const char *eighthSearchTerm  = [[NSString stringWithFormat:@"%@ |%%",     packageIDLike] UTF8String];

        NSString *query = [NSString stringWithFormat:@"SELECT VERSION FROM PACKAGES "
                           @"WHERE PACKAGE NOT IN (%@) AND REPOID = 0 AND ("
                                @"PACKAGE = ? OR ("
                                    @"PROVIDES LIKE ? ESCAPE '\\' OR PROVIDES LIKE ? ESCAPE '\\' OR PROVIDES LIKE ? ESCAPE '\\' OR PROVIDES LIKE ? ESCAPE '\\' OR PROVIDES LIKE ? ESCAPE '\\' OR PROVIDES LIKE ? ESCAPE '\\' OR PROVIDES LIKE ? ESCAPE '\\' OR PROVIDES LIKE ? ESCAPE '\\'"
                                @")"
                           @") AND %@ "
                           @"LIMIT 1",
                           [excludes componentsJoinedByString:@","], self._installablePackageArchitectureClause];

        BOOL found = NO;
        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            for (int i = 0; i < removedPackages.count; i++) {
                sqlite3_bind_text(statement, i + 1, [removedPackages[i] UTF8String], -1, SQLITE_TRANSIENT);
            }

            sqlite3_bind_text(statement, (int)removedPackages.count + 2, [packageIdentifier UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, (int)removedPackages.count + 3, firstSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, (int)removedPackages.count + 4, secondSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, (int)removedPackages.count + 5, thirdSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, (int)removedPackages.count + 6, fourthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, (int)removedPackages.count + 7, fifthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, (int)removedPackages.count + 8, sixthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, (int)removedPackages.count + 9, seventhSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, (int)removedPackages.count + 10, eighthSearchTerm, -1, SQLITE_TRANSIENT);

            while (sqlite3_step(statement) == SQLITE_ROW) {
                if (needsVersionComparison) {
                    const char* foundVersion = (const char*)sqlite3_column_text(statement, 0);

                    if (foundVersion != 0) {
                        if ([ZBDependencyResolver doesVersion:[NSString stringWithUTF8String:foundVersion] satisfyComparison:versionComponents[1] ofVersion:versionComponents[2]]) {
                            found = YES;
                            break;
                        }
                    }
                }
                else {
                    found = YES;
                    break;
                }
            }

            if (!found) { //Search the array of packages that are queued for installation to see if one of them satisfies the dependency
                for (NSDictionary *package in addedPackages) {
                    if ([[package objectForKey:@"identifier"] isEqualToString:packageIdentifier]) {
                        // TODO: Condition check here is useless
//                        if (needsVersionComparison && [ZBDependencyResolver doesVersion:[package objectForKey:@"version"] satisfyComparison:versionComponents[1] ofVersion:versionComponents[2]]) {
//                            return YES;
//                        }
                        return YES;
                    }
                }
                return NO;
            }

            sqlite3_finalize(statement);
            [self closeDatabase];
            return found;
        } else {
            [self printDatabaseError];
        }
        [self closeDatabase];
    }
    else {
        [self printDatabaseError];
    }
    return NO;
}

#pragma mark - Download Delegate

- (void)startedDownloads {
    if (!completedSources) {
        completedSources = [NSMutableArray new];
    }
}

- (void)startedSourceDownload:(ZBBaseSource *)baseSource {
    [self bulkSetSource:[baseSource baseFilename] busy:YES];
    [self postStatusUpdate:[NSString stringWithFormat:NSLocalizedString(@"Downloading %@", @""), [baseSource repositoryURI]] atLevel:ZBLogLevelDescript];
}

- (void)progressUpdate:(CGFloat)progress forSource:(ZBBaseSource *)baseSource {
    //TODO: Implement
}

- (void)finishedSourceDownload:(ZBBaseSource *)baseSource withErrors:(NSArray <NSError *> *_Nullable)errors {
    [self bulkSetSource:[baseSource baseFilename] busy:NO];
    if (errors && [errors count]) {
        NSString *message = [NSString stringWithFormat:NSLocalizedString(@"Error while downloading %@: %@", @""), [baseSource repositoryURI], errors[0].localizedDescription];
        [self postStatusUpdate:message atLevel:ZBLogLevelError];
    }
    [self postStatusUpdate:[NSString stringWithFormat:NSLocalizedString(@"Done %@", @""), [baseSource repositoryURI]] atLevel:ZBLogLevelDescript];
    if (baseSource) [completedSources addObject:baseSource];
}

- (void)finishedAllDownloads {
    [self parseSources:[completedSources copy]];
    [completedSources removeAllObjects];
}

- (void)postStatusUpdate:(NSString *)status atLevel:(ZBLogLevel)level {
    [self bulkPostStatusUpdate:status atLevel:level];
}


#pragma mark - Helper methods

- (NSArray *)cleanUpDuplicatePackages:(NSArray <ZBPackage *> *)packageList {
    NSMutableDictionary *packageVersionDict = [[NSMutableDictionary alloc] init];
    NSMutableArray *results = [NSMutableArray array];

    for (ZBPackage *package in packageList) {
        ZBPackage *packageFromDict = packageVersionDict[package.identifier];
        if (packageFromDict == NULL) {
            packageVersionDict[package.identifier] = package;
            [results addObject:package];
            continue;
        }

        if ([package sameAs:packageFromDict]) {
            NSString *packageDictVersion = [packageFromDict version];
            NSString *packageVersion = package.version;
            int result = compare([packageVersion UTF8String], [packageDictVersion UTF8String]);

            if (result > 0) {
                NSUInteger index = [results indexOfObject:packageFromDict];
                packageVersionDict[package.identifier] = package;
                [results replaceObjectAtIndex:index withObject:package];
            }
        }
    }

    return results;
}

- (void)checkForZebraSource {
    NSError *readError = NULL;
    NSString *sources = [NSString stringWithContentsOfFile:[ZBAppDelegate sourcesListPath] encoding:NSUTF8StringEncoding error:&readError];
    if (readError != nil) {
        NSLog(@"[Zebra] Error while reading source list");
    }

    if (![sources containsString:@"deb https://getzbra.com/repo/ ./"]) {
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:[ZBAppDelegate sourcesListPath]];
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[@"\ndeb https://getzbra.com/repo/ ./\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    }
}

- (ZBPackage *)localVersionForPackage:(ZBPackage *)package {
    if ([[package source] sourceID] == 0) return package;
    if (![package isInstalled:NO]) return NULL;

    ZBPackage *localPackage = NULL;
    if ([self openDatabase] == SQLITE_OK) {
        char *query = "SELECT * FROM PACKAGES "
                      "WHERE PACKAGE = ? AND REPOID = 0";

        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_text(statement, 1, [package.identifier UTF8String], -1, SQLITE_TRANSIENT);

            while (sqlite3_step(statement) == SQLITE_ROW) {
                localPackage = [[ZBPackage alloc] initWithSQLiteStatement:statement];
                break;
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        [self closeDatabase];
    } else {
        [self printDatabaseError];
    }

    return localPackage;
}

- (NSString * _Nullable)installedVersionForPackage:(ZBPackage *)package {
    NSString *version = NULL;
    if ([self openDatabase] == SQLITE_OK) {
        char *query = "SELECT VERSION FROM PACKAGES "
                      "WHERE PACKAGE = ? AND REPOID = 0";

        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_text(statement, 1, [package.identifier UTF8String], -1, SQLITE_TRANSIENT);

            while (sqlite3_step(statement) == SQLITE_ROW) {
                const char *versionChars = (const char *)sqlite3_column_text(statement, 0);
                if (versionChars != 0) {
                    version = [NSString stringWithUTF8String:versionChars];
                }
                break;
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        [self closeDatabase];
    } else {
        [self printDatabaseError];
    }

    return version;
}

@end
