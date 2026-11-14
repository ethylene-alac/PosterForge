#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import "../Shared/PFShared.h"
#import "PFPosterBuilder.h"
#import <sys/stat.h>
#import <unistd.h>
#import <stdio.h>
#import <string.h>

static NSDictionary *PFErrorDetails(NSError *error) {
    NSMutableDictionary *details=[@{@"domain":error.domain,@"code":@(error.code),@"description":error.localizedDescription} mutableCopy];
    if(error.userInfo[NSFilePathErrorKey])details[@"path"]=error.userInfo[NSFilePathErrorKey];
    if(error.userInfo[@"diagnostics"])details[@"diagnostics"]=error.userInfo[@"diagnostics"];
    NSError *underlying=error.userInfo[NSUnderlyingErrorKey];if(underlying)details[@"underlying"]=PFErrorDetails(underlying);
    return details;
}

static void ProcessRequests(void) {
    @synchronized(PFPosterBuilder.class) {
    NSError *directoryError=nil;
    if(!PFEnsureDirectories(&directoryError)){NSLog(@"PosterForge queue directories: %@",directoryError);return;}
    PFPosterBuilder *builder=[PFPosterBuilder new]; NSFileManager *fm=NSFileManager.defaultManager;
    NSArray *requests=[fm contentsOfDirectoryAtPath:PFRequestsDirectory error:&directoryError];
    if(!requests){NSLog(@"PosterForge cannot enumerate requests: %@",directoryError);return;}
    for(NSString *name in requests) @autoreleasepool {
        if(![name.pathExtension isEqual:@"plist"])continue;
        NSString *path=[PFRequestsDirectory stringByAppendingPathComponent:name]; NSDictionary *request=[NSDictionary dictionaryWithContentsOfFile:path]; if(!request)continue;
        NSError *error=nil; BOOL ok=NO; NSString *action=request[@"action"];
        if([action isEqual:@"install"]) {
            NSString *identifier=request[@"identifier"];
            if([identifier isKindOfClass:NSString.class]&&[[NSUUID alloc]initWithUUIDString:identifier]) {
                NSDictionary *item=[NSDictionary dictionaryWithContentsOfFile:[[PFLibraryDirectory stringByAppendingPathComponent:identifier] stringByAppendingPathComponent:@"manifest.plist"]];
                ok=item&&[item[@"identifier"] isEqual:identifier]&&[builder installItem:item error:&error];
            }
        }
        else if([action isEqual:@"remove"]) ok=[builder removeIdentifier:request[@"identifier"] error:&error];
        else if([action isEqual:@"tendies"]) ok=[builder importTendiesAtPath:request[@"path"] error:&error];
        if(!ok&&!error)error=[NSError errorWithDomain:@"com.posterforge.request" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Invalid request, missing manifest, or unsupported action"}];
        NSMutableDictionary *result=request.mutableCopy; result[@"success"]=@(ok); result[@"finished"]=NSDate.date;
        if(error){result[@"error"]=error.localizedDescription;result[@"errorDetails"]=PFErrorDetails(error);}
        NSData *data=[NSPropertyListSerialization dataWithPropertyList:result format:NSPropertyListBinaryFormat_v1_0 options:0 error:&directoryError];
        if(!data||![data writeToFile:[PFCompletedDirectory stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:&directoryError]) {
            NSLog(@"PosterForge cannot save Completed result; keeping request %@: %@",name,directoryError);continue;
        }
        NSLog(@"PosterForge completed %@ action=%@ success=%d error=%@",name,action,ok,error);
        if(![fm removeItemAtPath:path error:&directoryError])NSLog(@"PosterForge cannot clear request %@: %@",name,directoryError);
    }
    }
}

static void NotificationCallback(CFNotificationCenterRef c,void *o,CFStringRef n,const void *obj,CFDictionaryRef info){ ProcessRequests(); }

int main(int argc,char **argv){ @autoreleasepool {
    umask(0022);
    if(argc==2&&strcmp(argv[1],"--diagnose-container")==0) {
        NSError *error=nil;NSString *container=PFPosterBoardContainerWithError(&error);
        NSDictionary *result=container?@{@"success":@YES,@"container":container}:@{@"success":@NO,@"errorDetails":PFErrorDetails(error)};
        NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL];
        fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);return container?0:1;
    }
    NSLog(@"PosterForge 0.1.1 daemon started uid=%u euid=%u",getuid(),geteuid()); ProcessRequests();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),NULL,NotificationCallback,(__bridge CFStringRef)PFReloadNotification,NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
    NSTimer *timer=[NSTimer timerWithTimeInterval:3 repeats:YES block:^(NSTimer *t){ProcessRequests();}]; [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes]; [NSRunLoop.mainRunLoop run];
} return 0; }
