//
//  ZBDownloadManager.m
//  Zebra
//
//  Created by Wilson Styres on 4/14/19.
//  Copyright © 2019 Wilson Styres. All rights reserved.
//

#import "ZBDownloadManager.h"

#import "ZBDevice.h"
#import "ZBLog.h"
#import "ZBSettings.h"
#import "ZBAppDelegate.h"
#import "ZBPackage.h"
#import "ZBBaseSource.h"
#import "ZBSource.h"
#import "ZBSourceManager.h"
#import "ZBPaymentVendor.h"
#import "NSURLSession+Zebra.h"

#import <bzlib.h>
#import <zlib.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <compression.h>

@interface ZBDownloadManager () {
    BOOL ignore;
    int failedTasks;
    NSMutableDictionary <NSNumber *, ZBPackage *> *packageTasksMap;
    NSMutableDictionary <NSNumber *, ZBBaseSource *> *sourceTasksMap;
}
@end

@implementation ZBDownloadManager

@synthesize downloadDelegate;
@synthesize session;

#pragma mark - Initializers

+ (NSDictionary *)headers {
    //For tweak compatibility...ugh...Going to remove in 1.2 betas
    return [NSURLSession zbra_downloadSession].configuration.HTTPAdditionalHeaders;
}

+ (NSError *)errorForHTTPStatusCode:(NSUInteger)statusCode forFile:(nullable NSString *)file {
    NSString *reasonPhrase = [[NSHTTPURLResponse localizedStringForStatusCode:statusCode] localizedCapitalizedString];
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:statusCode userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%lu %@%@%@", (unsigned long)statusCode, reasonPhrase, file ? @": " : @"", file ?: @""]
    }];

    return error;
}

- (NSDictionary *)headers {
    //For tweak compatibility...ugh...Going to remove in 1.2 betas
    return [NSURLSession zbra_downloadSession].configuration.HTTPAdditionalHeaders;
}

- (id)init {
    self = [super init];
    
    if (self) {
        packageTasksMap = [NSMutableDictionary new];
        sourceTasksMap = [NSMutableDictionary new];
    }
    
    return self;
}

- (id)initWithDownloadDelegate:(id <ZBDownloadDelegate>)delegate {
    self = [self init];
    
    if (self) {
        downloadDelegate = delegate;
    }
    
    return self;
}

#pragma mark - Downloading Sources

- (void)downloadSources:(NSSet <ZBBaseSource *> *_Nonnull)sources useCaching:(BOOL)useCaching {
    self->ignore = !useCaching;
    [downloadDelegate startedDownloads];
    
    NSURLSessionConfiguration *configuration = [[NSURLSession zbra_downloadSession].configuration copy];
    if (!configuration.HTTPAdditionalHeaders) {
        [self postStatusUpdate:[NSString stringWithFormat:@"%@\n", NSLocalizedString(@"Could not determine device information.", @"")] atLevel:ZBLogLevelError];
        return;
    }
    configuration.timeoutIntervalForRequest = [ZBSettings sourceRefreshTimeout];

    session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    for (ZBBaseSource *source in sources) {
        NSURLSessionTask *releaseTask = [session downloadTaskWithURL:source.releaseURL];
        
        source.releaseTaskIdentifier = releaseTask.taskIdentifier;
        [sourceTasksMap setObject:source forKey:@(releaseTask.taskIdentifier)];
        [releaseTask resume];
        
        [self downloadPackagesFileWithExtension:@"bz2" fromSource:source ignoreCaching:ignore];
        
        [downloadDelegate startedSourceDownload:source];
    }
}

- (void)downloadPackagesFileWithExtension:(NSString *_Nullable)extension fromSource:(ZBBaseSource *)source ignoreCaching:(BOOL)ignore {
    self->ignore = ignore;
    
    if ([extension isEqualToString:@""]) extension = nil;
    
    NSString *filename = (extension) ? [NSString stringWithFormat:@"Packages.%@", extension] : @"Packages";
    NSURL *url = [source.packagesDirectoryURL URLByAppendingPathComponent:filename];
    
    NSMutableURLRequest *packagesRequest = [[NSMutableURLRequest alloc] initWithURL:url];
    if (!ignore) {
        [packagesRequest setValue:[self lastModifiedDateForFile:[self saveNameForURL:url]] forHTTPHeaderField:@"If-Modified-Since"];
    }
    
    NSURLSessionTask *packagesTask = [session downloadTaskWithRequest:packagesRequest];

    source.packagesTaskIdentifier = packagesTask.taskIdentifier;
    [sourceTasksMap setObject:source forKey:@(packagesTask.taskIdentifier)];
    [packagesTask resume];
}

#pragma mark - Downloading Packages

- (void)downloadPackage:(ZBPackage *)package {
    [self downloadPackages:@[package]];
}

- (void)downloadPackages:(NSArray <ZBPackage *> *)packages {
    [downloadDelegate startedDownloads];

    session = [NSURLSession sessionWithConfiguration:[NSURLSession zbra_downloadSession].configuration delegate:self delegateQueue:nil];
    for (ZBPackage *package in packages) {
        ZBSource *source = [package source];
        NSString *filename = [package filename];
        
        if (source == nil || filename == nil) {
            if ([downloadDelegate respondsToSelector:@selector(postStatusUpdate:atLevel:)]) {
                [downloadDelegate postStatusUpdate:[NSString stringWithFormat:@"%@ %@ (%@)\n", NSLocalizedString(@"Could not find a download URL for", @""), package.name, package.identifier] atLevel:ZBLogLevelWarning];
            }
            ++failedTasks;
            continue;
        }
        
        NSString *baseURL = [source repositoryURI];
        NSURL *url = [NSURL URLWithString:filename];
        
        NSArray *comps = [baseURL componentsSeparatedByString:@"dists"];
        NSURL *base = [NSURL URLWithString:comps[0]];
        
        if (url && url.host && url.scheme) {
            NSURLSessionDownloadTask *downloadTask = [session downloadTaskWithURL:url];
            [downloadTask resume];
            
            [packageTasksMap setObject:package forKey:@(downloadTask.taskIdentifier)];
            [downloadDelegate startedPackageDownload:package];
        } else if (package.requiresAuthorization) {
            [self postStatusUpdate:[NSString stringWithFormat:NSLocalizedString(@"Authorizing Download for %@", @""), package.name] atLevel:ZBLogLevelDescript];
            [package.source.paymentVendor authorizeDownloadForPackage:package.identifier
                                                               params:@{
                @"version": package.version,
                @"architecture": package.architecture,
                @"repo": source.repositoryURI
            }
                                                           completion:^(NSURL * _Nullable url, NSError * _Nullable error) {
                if (url && !error) {
                    NSURLSessionDownloadTask *downloadTask = [self->session downloadTaskWithURL:url];
                    [downloadTask resume];
                    
                    [self->packageTasksMap setObject:package forKey:@(downloadTask.taskIdentifier)];
                    [self->downloadDelegate startedPackageDownload:package];
                }
                else {
                    [self postStatusUpdate:[NSString stringWithFormat:NSLocalizedString(@"Couldn't authorize download for %@.", @""), package.name] atLevel:ZBLogLevelError];
                    [self postStatusUpdate:[NSString stringWithFormat:NSLocalizedString(@"Reason: %@", @""), error.localizedDescription] atLevel:ZBLogLevelError];
                }
            }];
        } else {
            NSString *baseString = [base absoluteString];
            if ([baseString characterAtIndex:baseString.length - 1] != '/') baseString = [baseString stringByAppendingString:@"/"];
            baseString = [baseString stringByAppendingString:filename]; //Avoid URL encoding with characters like '?'
                
            base = [NSURL URLWithString:baseString];
            
            NSURLSessionTask *downloadTask = [session downloadTaskWithURL:base];
            [downloadTask resume];
            
            [self->packageTasksMap setObject:package forKey:@(downloadTask.taskIdentifier)];
            [downloadDelegate startedPackageDownload:package];
        }
    }
    
    if (failedTasks == packages.count) {
        failedTasks = 0;
        [self->downloadDelegate finishedAllDownloads];
    }
}

#pragma mark - Handling Downloaded Files

- (void)task:(NSURLSessionTask *_Nonnull)task completedDownloadedForFile:(NSString *_Nullable)path fromSource:(ZBBaseSource *_Nonnull)source withError:(NSError *_Nullable)error {
    if (error) { //An error occured, we should handle it accordingly
        if (error.code == NSURLErrorTimedOut && (task.taskIdentifier == source.releaseTaskIdentifier || task.taskIdentifier == source.packagesTaskIdentifier)) { // If one of these files times out, the source is likely down. We're going to cancel the entire task.
            
            [self cancelTasksForSource:source]; // Cancel the other task for this source.
            [downloadDelegate finishedSourceDownload:source withErrors:@[error]];
        }
        else if (task.taskIdentifier == source.releaseTaskIdentifier) { //This is a Release file that failed. We don't really care that much about the Release file (since we can function without one) but we should at least *warn* the user so that they might bug the source maintainer :)
            NSString *description = [NSString stringWithFormat:NSLocalizedString(@"Could not download Release file from %@. Reason: %@", @""), source.repositoryURI, error.localizedDescription];
            
            source.releaseTaskCompleted = YES;
            source.releaseFilePath = nil;
            [self postStatusUpdate:description atLevel:ZBLogLevelWarning];
        }
        else if (task.taskIdentifier == source.packagesTaskIdentifier) { //This is a packages file that failed, we should be able to try again with a Packages.gz or a Packages file
            NSURL *url = [[task originalRequest] URL];
            if (![url pathExtension]) { //No path extension, Packages file download failed :(
                NSString *filename = [[task response] suggestedFilename];
                if ([filename pathExtension] != nil) {
                    filename = [filename stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@".%@", [filename pathExtension]] withString:@""]; //Remove path extension
                }
                
                NSString *description = [NSString stringWithFormat:NSLocalizedString(@"Could not download Packages file from %@. Reason: %@", @""), source.repositoryURI, error.localizedDescription];
                
                source.packagesTaskCompleted = YES;
                source.packagesFilePath = nil;
                
                [self postStatusUpdate:description atLevel:ZBLogLevelError];
                [self cancelTasksForSource:source];
                
                [downloadDelegate finishedSourceDownload:source withErrors:@[error]];
            }
            else { //Tries to download another filetype
                NSArray *options = @[@"bz2", @"gz", @"xz", @"lzma", @""];
                NSUInteger nextIndex = [options indexOfObject:[url pathExtension]] + 1;
                if (nextIndex < options.count) {
                    [self downloadPackagesFileWithExtension:[options objectAtIndex:nextIndex] fromSource:source ignoreCaching:ignore];
                }
                else { //Should never happen but lets catch the error just in case
                    NSString *description = [NSString stringWithFormat:NSLocalizedString(@"Could not download Packages file from %@. Reason: %@", @""), source.repositoryURI, error.localizedDescription];
                    
                    source.packagesTaskCompleted = YES;
                    source.packagesFilePath = nil;
                    
                    [self postStatusUpdate:description atLevel:ZBLogLevelWarning];
                    [self cancelTasksForSource:source];
                    
                    [downloadDelegate finishedSourceDownload:source withErrors:@[error]];
                }
            }
        }
        else { //Since we cannot determine which task this is, we need to cancel the entire source download :( (luckily this should never happen)
            NSString *description = [NSString stringWithFormat:NSLocalizedString(@"Could not download one or more files from %@. Reason: %@", @""), source.repositoryURI, error.localizedDescription];
            
            source.packagesTaskCompleted = YES;
            source.packagesFilePath = nil;
            source.releaseTaskCompleted = YES;
            source.releaseFilePath = nil;
            
            [self postStatusUpdate:description atLevel:ZBLogLevelError];
            [self cancelTasksForSource:source];
            
            [downloadDelegate finishedSourceDownload:source withErrors:@[error]];
        }
    }
    else {
        if (task.taskIdentifier == source.packagesTaskIdentifier) {
            source.packagesTaskCompleted = YES;
            source.packagesFilePath = path;
        }
        else if (task.taskIdentifier == source.releaseTaskIdentifier) {
            source.releaseTaskCompleted = YES;
            source.releaseFilePath = path;
        }
        
        if (source.releaseTaskCompleted && source.packagesTaskCompleted) {
            [downloadDelegate finishedSourceDownload:source withErrors:nil];
        }
    }
    
    //Remove task identifiers
    if (task.taskIdentifier == source.packagesTaskIdentifier) {
        source.packagesTaskIdentifier = -1;
    }
    else if (task.taskIdentifier == source.releaseTaskIdentifier) {
        source.releaseTaskIdentifier = -1;
    }
    
    [sourceTasksMap removeObjectForKey:@(task.taskIdentifier)];
    
    if (!sourceTasksMap.count) {
        [downloadDelegate finishedAllDownloads];
    }
}

- (void)handleDownloadedFile:(NSString *)path forPackage:(ZBPackage *)package withError:(NSError *)error {
    NSLog(@"Final Path: %@ Package: %@", path, package);
}

- (void)moveFileFromLocation:(NSURL *)location to:(NSString *)finalPath completion:(void (^)(NSError *error))completion {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    BOOL movedFileSuccess = NO;
    NSError *fileManagerError = nil;
    if ([fileManager fileExistsAtPath:finalPath]) {
        movedFileSuccess = [fileManager removeItemAtPath:finalPath error:&fileManagerError];
        
        if (!movedFileSuccess && completion) {
            completion(fileManagerError);
            return;
        }
    }
    
    movedFileSuccess = [fileManager moveItemAtURL:location toURL:[NSURL fileURLWithPath:finalPath] error:&fileManagerError];
    
    if (completion) {
        completion(fileManagerError);
    }
}

- (void)cancelAllTasksForSession:(NSURLSession *)session {
    [session getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        if (!dataTasks || !dataTasks.count) {
            return;
        }
        for (NSURLSessionTask *task in dataTasks) {
            [task cancel];
        }
    }];
    [packageTasksMap removeAllObjects];
    [sourceTasksMap removeAllObjects];
    [session invalidateAndCancel];
}

- (void)stopAllDownloads {
    [self cancelAllTasksForSession:session];
}

- (BOOL)isSessionOutOfTasks:(NSURLSession *)sesh {
    __block BOOL outOfTasks = NO;
    [sesh getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        outOfTasks = dataTasks.count == 0;
    }];
    
    return outOfTasks;
}

#pragma mark - Helper Methods

- (BOOL)checkForInvalidRepo:(NSString *)baseURL {
    NSURL *url = [NSURL URLWithString:baseURL];
    NSString *host = [url host];

    switch ([ZBDevice jailbreak]) {
    case ZBJailbreakOdyssey:
        return ([host isEqualToString:@"apt.saurik.com"] || [host isEqualToString:@"electrarepo64.coolstar.org"] || [host isEqualToString:@"repo.chimera.sh"] || [host isEqualToString:@"apt.bingner.com"]);
    case ZBJailbreakCheckra1n:
        return ([host isEqualToString:@"apt.saurik.com"] || [host isEqualToString:@"electrarepo64.coolstar.org"] || [host isEqualToString:@"repo.chimera.sh"]);
    case ZBJailbreakChimera:
        return ([host isEqualToString:@"checkra.in"] || [host isEqualToString:@"apt.bingner.com"] || [host isEqualToString:@"apt.saurik.com"] || [host isEqualToString:@"electrarepo64.coolstar.org"]);
    case ZBJailbreakUnc0ver:
        return ([host isEqualToString:@"checkra.in"] || [host isEqualToString:@"repo.chimera.sh"] || [host isEqualToString:@"apt.saurik.com"] || [host isEqualToString:@"electrarepo64.coolstar.org"]);
    case ZBJailbreakElectra:
        return ([host isEqualToString:@"checkra.in"] || [host isEqualToString:@"repo.chimera.sh"] || [host isEqualToString:@"apt.saurik.com"] || [host isEqualToString:@"apt.bingner.com"]);
    default:
        if ([[NSFileManager defaultManager] fileExistsAtPath:@INSTALL_PREFIX @"/Applications/Cydia.app"]) { // cydia
            return ([host isEqualToString:@"checkra.in"] || [host isEqualToString:@"repo.chimera.sh"] || [host isEqualToString:@"electrarepo64.coolstar.org"] || [host isEqualToString:@"apt.bingner.com"]);
        }
        return NO;
    }
}

- (NSString *)guessMIMETypeForFile:(NSString *)path {
    NSString *filename = [path lastPathComponent];
    
    NSString *pathExtension = [[filename lastPathComponent] pathExtension];
    if (pathExtension != nil && ![pathExtension isEqualToString:@""]) {
        NSString *extension = [filename pathExtension];
        
        if ([extension isEqualToString:@"txt"]) { //Likely Packages.txt or Release.txt
            return @"text/plain";
        }
        else if ([extension containsString:@"deb"]) { //A deb
            return @"application/x-deb";
        }
        else if ([extension isEqualToString:@"bz2"]) { //.bz2
            return @"application/x-bzip2";
        }
        else if ([extension isEqualToString:@"gz"]) { //.gz
            return @"application/x-gzip";
        }
        else if ([extension isEqualToString:@"xz"]) { //.xz
            return @"application/x-xz";
        }
        else if ([extension isEqualToString:@"lzma"]) { //.lzma
            return @"application/x-lzma";
        }
    }
    // We're going to assume this is a Release or uncompressed Packages file
    return @"text/plain";
}

- (NSString *)saveNameForURL:(NSURL *)url {
    NSString *filename = [url lastPathComponent]; //Releases
    NSString *schemeless = [[[[url URLByDeletingLastPathComponent] absoluteString] stringByReplacingOccurrencesOfString:[url scheme] withString:@""] substringFromIndex:3]; //Removes scheme and ://
    NSString *baseFilename = [schemeless stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [baseFilename stringByAppendingString:filename];
}

#pragma mark - Session Headers

- (NSString *)lastModifiedDateForFile:(NSString *)filename {
    NSString *path = [[[ZBAppDelegate listsLocation] stringByAppendingPathComponent:filename] stringByDeletingPathExtension];
    
    NSError *fileError = nil;
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&fileError];
    NSDate *date = fileError != nil ? [NSDate distantPast] : [attributes fileModificationDate];
    
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    NSTimeZone *gmt = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
    [formatter setTimeZone:gmt];
    [formatter setDateFormat:@"E, d MMM yyyy HH:mm:ss"];
    
    return [NSString stringWithFormat:@"%@ GMT", [formatter stringFromDate:date]];
}

#pragma mark - URL Session Delegate

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
    NSURLResponse *response = [downloadTask response];
    NSInteger responseCode = [(NSHTTPURLResponse *)response statusCode];
    
    if (responseCode == 304) {
        //Since we should never get a 304 for a deb, we can assume this is from a source.
        ZBBaseSource *source = sourceTasksMap[@(downloadTask.taskIdentifier)];
        
        [self task:downloadTask completedDownloadedForFile:NULL fromSource:source withError:NULL];
        return;
    }
    
    NSString *MIMEType = [response MIMEType];
    NSString *requestedMIMEType = [self guessMIMETypeForFile:[[response URL] lastPathComponent]];
    NSArray *acceptableMIMETypes = @[@"text/plain", @"application/x-xz", @"application/x-bzip2", @"application/x-gzip", @"application/x-lzma", @"application/x-deb", @"application/x-debian-package"];
    NSUInteger index = [acceptableMIMETypes indexOfObject:MIMEType];
    if (packageTasksMap[@([downloadTask taskIdentifier])]) {
        MIMEType = @"application/x-deb";
        index = [acceptableMIMETypes indexOfObject:MIMEType];
    }
    else if (index == NSNotFound || ![requestedMIMEType isEqualToString:MIMEType]) {
        MIMEType = [self guessMIMETypeForFile:[[response URL] absoluteString]];
        index = [acceptableMIMETypes indexOfObject:MIMEType];
    }
    
    BOOL downloadFailed = (responseCode != 200 && responseCode != 304);
    switch (index) {
        case 0: { //Uncompressed Packages file or a Release file
            ZBBaseSource *source = sourceTasksMap[@(downloadTask.taskIdentifier)];
            if (source) {
                if (downloadFailed) {
                    NSString *suggestedFilename = [response suggestedFilename];
                    
                    NSError *error = NULL;
                    if (![MIMEType isEqualToString:requestedMIMEType]) {
                        error = [[NSError alloc] initWithDomain:NSURLErrorDomain code:1234 userInfo:@{NSLocalizedDescriptionKey: @"Requested MIME Type is not identical to MIME type received"}];
                    }
                    else {
                        error = [self.class errorForHTTPStatusCode:responseCode forFile:suggestedFilename];
                    }
                    
                    [self task:downloadTask completedDownloadedForFile:[[response URL] absoluteString] fromSource:source withError:error];
                }
                else {
                    //Move the file to the save name location
                    NSString *listsPath = [ZBAppDelegate listsLocation];
                    NSString *saveName = [self saveNameForURL:[response URL]];
                    NSString *finalPath = [listsPath stringByAppendingPathComponent:saveName];
                    NSString *originalPathExtension = [[response URL] pathExtension];
                    if (originalPathExtension != nil && ![originalPathExtension isEqualToString:@""]) {
                        finalPath = [finalPath stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@".%@", [finalPath pathExtension]] withString:@""]; //Remove path extension from Packages or Release
                    }
                
                    [self moveFileFromLocation:location to:finalPath completion:^(NSError *error) {
                        [self task:downloadTask completedDownloadedForFile:finalPath fromSource:source withError:error];
                    }];
                }
            }
            else {
                NSLog(@"[Zebra] Unable to determine ZBBaseRepo associated with %lu. This should be looked into.", (unsigned long)downloadTask.taskIdentifier);
            }
            break;
        }
        case 1:
        case 2:
        case 3:
        case 4: { //Compressed packages file (.xz, .bz2, .gz, or .lzma)
            ZBBaseSource *source = sourceTasksMap[@(downloadTask.taskIdentifier)];
            if (source) {
                if (downloadFailed) {
                    NSString *suggestedFilename = [response suggestedFilename];
                    NSError *error = [self.class errorForHTTPStatusCode:responseCode forFile:suggestedFilename];
                    
                    [self task:downloadTask completedDownloadedForFile:[[response URL] absoluteString] fromSource:source withError:error];
                }
                else {
                    //Move the file to the save name location
                    NSString *listsPath = [ZBAppDelegate listsLocation];
                    NSString *saveName = [self saveNameForURL:[response URL]];
                    NSString *finalPath = [listsPath stringByAppendingPathComponent:saveName];
                    [self moveFileFromLocation:location to:finalPath completion:^(NSError *error) {
                        if (error) {
                            [self task:downloadTask completedDownloadedForFile:finalPath fromSource:source withError:error];
                        }
                        else {
                            NSError *error = nil;
                            NSString *decompressedFilePath = [self decompressFile:finalPath error:&error];
                            
                            [self task:downloadTask completedDownloadedForFile:decompressedFilePath fromSource:source withError:error];
                        }
                    }];
                }
            }
            else {
                NSLog(@"[Zebra] Unable to determine ZBBaseSource associated with %lu.", (unsigned long)downloadTask.taskIdentifier);
            }
            break;
        }
        case 5:
        case 6: { //Package.deb
            ZBPackage *package = packageTasksMap[@(downloadTask.taskIdentifier)];
            NSLog(@"[Zebra] Successfully downloaded file for %@", package);
            
            NSString *suggestedFilename = [response suggestedFilename];
            if (downloadFailed) {
                NSError *error = [self.class errorForHTTPStatusCode:responseCode forFile:suggestedFilename];
                
                [downloadDelegate finishedPackageDownload:package withError:error];
                
                [self->packageTasksMap removeObjectForKey:@(downloadTask.taskIdentifier)];
                
                if (!self->packageTasksMap.count) {
                    [self->downloadDelegate finishedAllDownloads];
                }
            }
            else {
                NSString *debsPath = [ZBAppDelegate debsLocation];
                NSString *filename = [NSString stringWithFormat:@"%@_%@.deb", [package identifier], [package version]];
                if ([filename containsString:@":"]) filename = [filename stringByReplacingOccurrencesOfString:@":" withString:@"e"]; //Replace : with e (for epoch) because apt doesn't like colons much
                NSString *finalPath = [debsPath stringByAppendingPathComponent:filename];
                
                [self moveFileFromLocation:location to:finalPath completion:^(NSError *error) {
                    ZBPackage *package = self->packageTasksMap[@(downloadTask.taskIdentifier)];
                    if (error) {
                        [self cancelAllTasksForSession:self->session];
                        NSString *text = [NSString stringWithFormat:[NSString stringWithFormat:@"[Zebra] %@: %%@\n", NSLocalizedString(@"Error while moving file at %@ to %@", @"")], location, finalPath, error.localizedDescription];
                        [self->downloadDelegate postStatusUpdate:text atLevel:ZBLogLevelError];
                        
                        [self->downloadDelegate finishedPackageDownload:package withError:error];
                    } else {
                        package.debPath = finalPath;
                        
                        [self->downloadDelegate finishedPackageDownload:package withError:nil];
                    }
                    
                    [self->packageTasksMap removeObjectForKey:@(downloadTask.taskIdentifier)];
                    
                    if (![self->packageTasksMap count]) {
                        [self->downloadDelegate finishedAllDownloads];
                    }
                }];
            }
            break;
        }
        default: { //We couldn't determine the file
            NSString *text = [NSString stringWithFormat:NSLocalizedString(@"Could not parse %@ from %@", @""), [response suggestedFilename], [response URL]];
            [downloadDelegate postStatusUpdate:text atLevel:ZBLogLevelError];
            
            [downloadDelegate finishedAllDownloads];
            break;
        }
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
#if DEBUG
    NSURLRequest *request = task.currentRequest;
    NSHTTPURLResponse *response = (NSHTTPURLResponse *)task.response;
    NSDictionary *prefixes = @{
        @200: @"🆗",
        @304: @"👍",
        @404: @"🤷‍♀️"
    };
    NSLog(@"[DownloadManager] %@ %@ %@ → %li %@", prefixes[@(response.statusCode)] ?: @"❌", request.HTTPMethod, request.URL, response.statusCode, error ?: @"");
#endif

    NSNumber *taskIdentifier = @(task.taskIdentifier);
    if (error && error.code != NSURLErrorCancelled) {
        ZBPackage *package = packageTasksMap[taskIdentifier];
        if (package) {
            [downloadDelegate finishedPackageDownload:package withError:error];
            
            if (packageTasksMap.count - 1 == 0) {
                [downloadDelegate finishedAllDownloads];
            }
        }
        else { //This should be a source
            ZBBaseSource *source = sourceTasksMap[@(task.taskIdentifier)];
            [self task:task completedDownloadedForFile:nil fromSource:source withError:error];
        }
    }
    [packageTasksMap removeObjectForKey:@(task.taskIdentifier)];
    [sourceTasksMap removeObjectForKey:@(task.taskIdentifier)];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    if (totalBytesExpectedToWrite == -1) {
        return;
    }
    ZBPackage *package = packageTasksMap[@(downloadTask.taskIdentifier)];
    if (package) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            dispatch_sync(dispatch_get_main_queue(), ^{
                [self->downloadDelegate progressUpdate:((double)totalBytesWritten / totalBytesExpectedToWrite) forPackage:package];
            });
        });
    }
}

#pragma mark - Logging

- (void)postStatusUpdate:(NSString *)update atLevel:(ZBLogLevel)level {
    if (downloadDelegate && [downloadDelegate respondsToSelector:@selector(postStatusUpdate:atLevel:)]) {
        [downloadDelegate postStatusUpdate:update atLevel:level];
    }
}

#pragma mark - Decompression

- (NSString * _Nullable)decompressFile:(NSString *)path error:(NSError **)error {
    //Since some servers and their MIME types are unreliable, we have to detemine the type of compression on our own...
    
    NSMutableArray *availableTypes = [@[@"xz", @"bz2", @"gz", @"lzma"] mutableCopy];
    
    //Move the path extension of our file to the start
    if ([availableTypes indexOfObject:[path pathExtension]] != NSNotFound) {
        [availableTypes removeObject:[path pathExtension]];
        
        [availableTypes insertObject:[path pathExtension] atIndex:0];
    }
    
    NSError *decompressionError = nil;
    for (NSString *compressionType in availableTypes) {
        NSString *decompressedPath = [self decompressFile:path compressionType:compressionType error:&decompressionError];
        
        if (decompressedPath) {
            *error = nil;
            
            return decompressedPath;
        }
    }
    
    if (decompressionError) {
        *error = decompressionError;
    }
    
    return NULL;
}

- (NSString * _Nullable)decompressFile:(NSString * _Nonnull)path compressionType:(NSString * _Nonnull)compressionType error:(NSError **)error {
    if (!compressionType) {
        compressionType = [self guessMIMETypeForFile:path];
    }
    
    NSArray *availableTypes = @[@"gz", @"bz2", @"xz", @"lzma"];
    switch ([availableTypes indexOfObject:compressionType]) {
        case 0: {
            NSData *data = [NSData dataWithContentsOfFile:path];
            if (![self validGZFile:data]) {
                NSError *invalidFileError = [NSError errorWithDomain:NSCocoaErrorDomain code:1337 userInfo:@{NSLocalizedDescriptionKey: @"Invalid .gz archive"}];
                *error = invalidFileError;
                
                return nil;
            }
            
            z_stream stream;
            stream.zalloc = Z_NULL;
            stream.zfree = Z_NULL;
            stream.avail_in = (uint)data.length;
            stream.next_in = (Bytef *)data.bytes;
            stream.total_out = 0;
            stream.avail_out = 0;
            
            NSMutableData *output = nil;
            if (inflateInit2(&stream, 47) == Z_OK) {
                int status = Z_OK;
                output = [NSMutableData dataWithCapacity:data.length * 2];
                while (status == Z_OK) {
                    if (stream.total_out >= output.length) {
                        output.length += data.length / 2;
                    }
                    stream.next_out = (uint8_t *)output.mutableBytes + stream.total_out;
                    stream.avail_out = (uInt)(output.length - stream.total_out);
                    status = inflate (&stream, Z_SYNC_FLUSH);
                }
                if (inflateEnd(&stream) == Z_OK && status == Z_STREAM_END) {
                    output.length = stream.total_out;
                }
            }
            
            [output writeToFile:[path stringByDeletingPathExtension] atomically:NO];
            
            NSError *removeError = nil;
            [[NSFileManager defaultManager] removeItemAtPath:path error:&removeError];
            if (removeError) {
                *error = removeError;
            }
            
            return [path stringByDeletingPathExtension];
        }
        case 1: {
            NSData *data = [NSData dataWithContentsOfFile:path];
            if (![self validBZ2File:data]) {
                NSError *invalidFileError = [NSError errorWithDomain:NSCocoaErrorDomain code:1337 userInfo:@{NSLocalizedDescriptionKey: @"Invalid .bz2 archive"}];
                *error = invalidFileError;
                
                return nil;
            }
            
            bz_stream stream;
            bzero(&stream, sizeof(stream));
            stream.next_in = (char *)[data bytes];
            stream.avail_in = (unsigned int)[data length];

            NSMutableData *buffer = [NSMutableData dataWithLength:1024];
            stream.next_out = [buffer mutableBytes];
            stream.avail_out = 1024;

            int status = BZ2_bzDecompressInit(&stream, 0, NO);
            if (status != BZ_OK) {
                *error = [NSError errorWithDomain:NSCocoaErrorDomain code:status userInfo:@{NSLocalizedDescriptionKey: @"Failed to initialize decompression stream"}];
                
                return nil;
            }

            NSMutableData *decompressedData = [NSMutableData data];
            
            //Have to do a do-while loop here in case the filesize is < 1024 bits
            do {
                status = BZ2_bzDecompress(&stream);
                if (status < BZ_OK) {
                    *error = [self errorForBZ2Code:status file:[path lastPathComponent]];
                    
                    return nil;
                }

                [decompressedData appendBytes:[buffer bytes] length:(1024 - stream.avail_out)];
                stream.next_out = [buffer mutableBytes];
                stream.avail_out = 1024;
            } while (status != BZ_STREAM_END);

            BZ2_bzDecompressEnd(&stream);
            
            NSString *finalPath = [path stringByDeletingPathExtension];
            [decompressedData writeToFile:finalPath atomically:NO];
            
            NSError *removeError = nil;
            [[NSFileManager defaultManager] removeItemAtPath:path error:&removeError];
            if (removeError) {
                *error = removeError;
            }
            
            return finalPath;
        }
        case 2:
        case 3: {
            compression_stream stream;
            compression_status status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA);
            if (status == COMPRESSION_STATUS_ERROR) {
                NSError *invalidFileError = [NSError errorWithDomain:NSCocoaErrorDomain code:1337 userInfo:@{NSLocalizedDescriptionKey: @"Invalid .lzma or .xz archive"}];
                *error = invalidFileError;
                
                return nil;
            }

            NSData *compressedData = [NSData dataWithContentsOfFile:path];
            stream.src_ptr = compressedData.bytes;
            stream.src_size = compressedData.length;

            size_t destinationBufferSize = 4096;
            uint8_t *destinationBuffer = malloc(destinationBufferSize);
            stream.dst_ptr = destinationBuffer;
            stream.dst_size = destinationBufferSize;
            
            NSMutableData *decompressedData = [NSMutableData new];

            do {
                status = compression_stream_process(&stream, 0);
                
                switch (status) {
                    case COMPRESSION_STATUS_OK:
                        if (stream.dst_size == 0) {
                            [decompressedData appendBytes:destinationBuffer length:destinationBufferSize];
                            
                            stream.dst_ptr = destinationBuffer;
                            stream.dst_size = destinationBufferSize;
                        }
                        break;
                        
                    case COMPRESSION_STATUS_END:
                        if (stream.dst_ptr > destinationBuffer) {
                            [decompressedData appendBytes:destinationBuffer length:stream.dst_ptr - destinationBuffer];
                        }
                        break;
                        
                    case COMPRESSION_STATUS_ERROR:
                        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:1337 userInfo:@{NSLocalizedDescriptionKey: @"Invalid .lzma or .xz archive"}];
                        compression_stream_destroy(&stream);
                        free(destinationBuffer);
                        return nil;
                    default:
                        break;
                }
            } while (status == COMPRESSION_STATUS_OK);

            compression_stream_destroy(&stream);
            [decompressedData writeToFile:[path stringByDeletingPathExtension] atomically:YES];
            free(destinationBuffer);
            
            NSError *removeError = nil;
            [[NSFileManager defaultManager] removeItemAtPath:path error:&removeError];
            if (removeError) {
                *error = removeError;
            }
            
            return [path stringByDeletingPathExtension];
        }
        default: { //Decompression of this file is not supported (ideally this should never happen but we'll keep it in case we support more compression types in the future)
            return path;
        }
    }
}

- (BOOL)validBZ2File:(NSData *)data {
    const UInt8 *bytes = (const UInt8 *)data.bytes;
    return (data.length >= 3 && bytes[0] == 'B' && bytes[1] == 'Z' && bytes[2] == 'h');
}

- (BOOL)validGZFile:(NSData *)data {
    const UInt8 *bytes = (const UInt8 *)data.bytes;
    return (data.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b);
}


- (NSError *)errorForBZ2Code:(int)bzError file:(NSString *)file {
    switch (bzError) {
        case BZ_PARAM_ERROR:
            return [NSError errorWithDomain:NSPOSIXErrorDomain code:1337 userInfo:@{NSLocalizedDescriptionKey: @"One of the configured parameters is incorrect", @"Failing-File": file}];
        case BZ_DATA_ERROR:
            return [NSError errorWithDomain:NSPOSIXErrorDomain code:1337 userInfo:@{NSLocalizedDescriptionKey: @"A data integrity error was detected in the compressed stream", @"Failing-File": file}];
        case BZ_DATA_ERROR_MAGIC:
            return [NSError errorWithDomain:NSPOSIXErrorDomain code:1337 userInfo:@{NSLocalizedDescriptionKey: @"The compressed stream does not begin with the correct magic bytes", @"Failing-File": file}];
        case BZ_MEM_ERROR:
            return [NSError errorWithDomain:NSPOSIXErrorDomain code:1337 userInfo:@{NSLocalizedDescriptionKey: @"Insufficient memory is available", @"Failing-File": file}];
        default:
            return [NSError errorWithDomain:NSPOSIXErrorDomain code:1337 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unknown BZ2 Error (%d)", bzError], @"Failing-File": file}];
    }
}

- (void)cancelTasksForSource:(ZBBaseSource *)source {
    [session getAllTasksWithCompletionHandler:^(NSArray<__kindof NSURLSessionTask *> * _Nonnull tasks) {
        for (NSURLSessionTask *task in tasks) {
            if (task.taskIdentifier == source.packagesTaskIdentifier || task.taskIdentifier == source.releaseTaskIdentifier) {
                [task cancel];
            }
        }
    }];
}

@end
