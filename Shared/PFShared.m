#import "PFShared.h"
#import <CoreFoundation/CoreFoundation.h>
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

NSString * const PFRootDirectory = @"/var/mobile/Library/Application Support/PosterForge";
NSString * const PFLibraryDirectory = @"/var/mobile/Library/Application Support/PosterForge/Library";
NSString * const PFRequestsDirectory = @"/var/mobile/Library/Application Support/PosterForge/Requests";
NSString * const PFCompletedDirectory = @"/var/mobile/Library/Application Support/PosterForge/Completed";
NSString * const PFReloadNotification = @"com.posterforge.reload";

BOOL PFEnsureDirectories(NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *path in @[PFRootDirectory, PFLibraryDirectory, PFRequestsDirectory, PFCompletedDirectory]) {
        if (![fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0775} error:error]) return NO;
    }
    return YES;
}

NSString *PFNewIdentifier(void) { return NSUUID.UUID.UUIDString.uppercaseString; }

NSArray<NSDictionary *> *PFLoadItems(void) {
    PFEnsureDirectories(NULL);
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:PFLibraryDirectory error:NULL]) {
        NSString *manifest = [[PFLibraryDirectory stringByAppendingPathComponent:entry] stringByAppendingPathComponent:@"manifest.plist"];
        NSDictionary *item = [NSDictionary dictionaryWithContentsOfFile:manifest];
        if (item) [result addObject:item];
    }
    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"created"] compare:a[@"created"]];
    }];
    return result;
}

BOOL PFSaveItem(NSDictionary *item, NSError **error) {
    NSString *identifier = item[@"identifier"];
    if (!identifier.length || !PFEnsureDirectories(error)) return NO;
    NSString *dir = [PFLibraryDirectory stringByAppendingPathComponent:identifier];
    if (![NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0775} error:error]) return NO;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:item format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    return data && [data writeToFile:[dir stringByAppendingPathComponent:@"manifest.plist"] options:NSDataWritingAtomic error:error];
}

BOOL PFDeleteItem(NSString *identifier, NSError **error) {
    BOOL ok = [NSFileManager.defaultManager removeItemAtPath:[PFLibraryDirectory stringByAppendingPathComponent:identifier] error:error];
    PFQueueRequest(@{@"action":@"remove", @"identifier":identifier}, NULL);
    return ok;
}

BOOL PFQueueRequest(NSDictionary *request, NSError **error) {
    if (!PFEnsureDirectories(error)) return NO;
    NSMutableDictionary *payload = request.mutableCopy;
    payload[@"requestID"] = PFNewIdentifier();
    payload[@"created"] = NSDate.date;
    NSString *path = [PFRequestsDirectory stringByAppendingPathComponent:[payload[@"requestID"] stringByAppendingString:@".plist"]];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:payload format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:error]) return NO;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)PFReloadNotification, NULL, NULL, true);
    return YES;
}

static void PFAppendDiagnostic(NSMutableArray<NSString *> *diagnostics, NSString *line) {
    // Keep process identity plus a bounded tail; the full trace still goes to NSLog.
    if(diagnostics.count>=256)[diagnostics removeObjectAtIndex:1];
    [diagnostics addObject:line];
}

static void PFLogPath(NSString *path, NSMutableArray<NSString *> *diagnostics) {
    struct stat st;
    NSString *line;
    if (lstat(path.fileSystemRepresentation, &st) != 0) {
        int code = errno;
        line = [NSString stringWithFormat:@"lstat %@: errno=%d (%s)", path, code, strerror(code)];
    } else {
        NSMutableArray *checks = [NSMutableArray array];
        for (NSNumber *mode in @[@(R_OK), @(W_OK), @(X_OK)]) {
            int rc = access(path.fileSystemRepresentation, mode.intValue);
            int code = rc == 0 ? 0 : errno;
            [checks addObject:[NSString stringWithFormat:@"access(%d)=%d errno=%d", mode.intValue, rc, code]];
        }
        line = [NSString stringWithFormat:@"%@ uid=%u gid=%u mode=%04o type=%o %@", path,
                (unsigned)st.st_uid, (unsigned)st.st_gid, (unsigned)(st.st_mode & 07777),
                (unsigned)(st.st_mode & S_IFMT), [checks componentsJoinedByString:@" "]];
    }
    PFAppendDiagnostic(diagnostics,line);
    NSLog(@"[PosterForge container] %@", line);
}

NSString *PFFindPosterBoardContainer(NSString *base, NSError **error) {
    if (error) *error = nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *diagnostics = [NSMutableArray array];
    NSString *identity = [NSString stringWithFormat:@"pid=%d uid=%u euid=%u gid=%u egid=%u base=%@ resolved=%@",
                         getpid(), getuid(), geteuid(), getgid(), getegid(), base, base.stringByResolvingSymlinksInPath];
    [diagnostics addObject:identity]; NSLog(@"[PosterForge container] %@", identity);
    PFLogPath(base, diagnostics);
    NSError *enumerationError = nil;
    NSArray *entries = [fm contentsOfDirectoryAtPath:base error:&enumerationError];
    NSMutableArray<NSString *> *matches = [NSMutableArray array];
    NSError *firstReadError = nil;
    NSUInteger candidates = 0, readFailures = 0, invalidMetadata = 0;
    for (NSString *uuid in [entries sortedArrayUsingSelector:@selector(compare:)]) @autoreleasepool {
        if (![[NSUUID alloc] initWithUUIDString:uuid]) {
            NSLog(@"[PosterForge container] skip non-UUID entry %@", uuid); continue;
        }
        candidates++;
        NSString *root = [base stringByAppendingPathComponent:uuid];
        PFLogPath(root, diagnostics);
        struct stat st;
        if (lstat(root.fileSystemRepresentation, &st) != 0) {
            int code=errno;readFailures++;
            if(!firstReadError)firstReadError=[NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:@{NSFilePathErrorKey:root}];
            NSLog(@"[PosterForge container] candidate lstat failed %@ errno=%d",root,code);continue;
        }
        if (!S_ISDIR(st.st_mode)) {
            NSLog(@"[PosterForge container] skip inaccessible/non-directory candidate %@", root); continue;
        }
        NSString *metadataPath = [root stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSError *readError = nil;
        NSData *data = [NSData dataWithContentsOfFile:metadataPath options:0 error:&readError];
        if (!data) {
            readFailures++; if (!firstReadError) firstReadError = readError;
            PFLogPath(metadataPath, diagnostics);
            NSString *line = [NSString stringWithFormat:@"metadata read %@: %@", metadataPath, readError];
            PFAppendDiagnostic(diagnostics,line); NSLog(@"[PosterForge container] %@", line); continue;
        }
        id meta = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:&readError];
        if (![meta isKindOfClass:NSDictionary.class]) {
            invalidMetadata++; if (!firstReadError) firstReadError = readError;
            NSString *line = [NSString stringWithFormat:@"invalid metadata %@: %@", metadataPath, readError ?: @"expected dictionary"];
            PFAppendDiagnostic(diagnostics,line); NSLog(@"[PosterForge container] %@", line); continue;
        }
        id identifier = meta[@"MCMMetadataIdentifier"];
        NSLog(@"[PosterForge container] metadata %@ bytes=%lu MCMMetadataIdentifier=%@", metadataPath, (unsigned long)data.length, identifier);
        if ([identifier isKindOfClass:NSString.class] && [identifier isEqualToString:@"com.apple.PosterBoard"]) [matches addObject:root];
    }
    NSString *summary = [NSString stringWithFormat:@"entries=%lu UUID-candidates=%lu read-failures=%lu invalid-metadata=%lu matches=%lu",
                        (unsigned long)entries.count, (unsigned long)candidates, (unsigned long)readFailures,
                        (unsigned long)invalidMetadata, (unsigned long)matches.count];
    PFAppendDiagnostic(diagnostics,summary); NSLog(@"[PosterForge container] %@", summary);
    if (matches.count == 1) { NSLog(@"[PosterForge container] selected %@", matches.firstObject); return matches.firstObject; }
    NSString *message = enumerationError ? @"Cannot enumerate app data containers; check daemon entitlements and sandbox access" :
        matches.count > 1 ? @"Multiple PosterBoard containers match metadata; refusing to choose one" :
        readFailures ? @"PosterBoard container lookup incomplete: container metadata could not be read" :
        invalidMetadata ? @"PosterBoard container not found; invalid container metadata was encountered" :
        @"PosterBoard container was not found in readable app container metadata";
    NSMutableDictionary *info = [@{NSLocalizedDescriptionKey:message, NSFilePathErrorKey:base, @"diagnostics":diagnostics} mutableCopy];
    NSError *underlying = enumerationError ?: firstReadError;
    if (underlying) info[NSUnderlyingErrorKey] = underlying;
    if (error) *error = [NSError errorWithDomain:@"com.posterforge.container" code:enumerationError ? 1 : matches.count > 1 ? 4 : readFailures ? 2 : 3 userInfo:info];
    return nil;
}

NSString *PFPosterBoardContainerWithError(NSError **error) {
    return PFFindPosterBoardContainer(@"/var/mobile/Containers/Data/Application", error);
}

NSString *PFPosterBoardContainer(void) { return PFPosterBoardContainerWithError(NULL); }
