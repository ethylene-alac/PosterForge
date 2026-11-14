#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import "../Shared/PFShared.h"
#import "PFPosterBuilder.h"
#import "PFMemory.h"
#import <sys/stat.h>
#import <unistd.h>
#import <stdio.h>
#import <string.h>
#import <stdlib.h>
#import <limits.h>

static NSDictionary *PFLimitsDictionary(PFMemoryLimits limits) {
    return @{@"activeMB":@(limits.activeMB),@"inactiveMB":@(limits.inactiveMB),
             @"activeAttributes":@(limits.activeAttributes),@"inactiveAttributes":@(limits.inactiveAttributes)};
}

static NSDictionary *PFMemoryReport(PFMemoryStatus status) {
    return @{@"targetPID":@(status.pid),@"callerPID":@(getpid()),@"callerEUID":@(geteuid()),
             @"requiredMinimumMB":@(PF_MEMORY_BUDGET_MB),@"budgetSatisfied":@(status.verified),
             @"before":PFLimitsDictionary(status.before),@"after":PFLimitsDictionary(status.after),
             @"beforeErrno":@(status.beforeError),@"setAttempted":@(status.attemptedSet),
             @"setErrno":@(status.setError),@"readbackErrno":@(status.afterError),
             @"callerFootprintBytes":@(PFCurrentFootprintBytes())};
}

static void PFPrintJSON(NSDictionary *result) {
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL];
    fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);
}

static NSDictionary *PFErrorDetails(NSError *error) {
    NSMutableDictionary *details=[@{@"domain":error.domain,@"code":@(error.code),@"description":error.localizedDescription} mutableCopy];
    if(error.userInfo[NSFilePathErrorKey])details[@"path"]=error.userInfo[NSFilePathErrorKey];
    if(error.userInfo[@"diagnostics"])details[@"diagnostics"]=error.userInfo[@"diagnostics"];
    NSError *underlying=error.userInfo[NSUnderlyingErrorKey];if(underlying)details[@"underlying"]=PFErrorDetails(underlying);
    return details;
}

static void ProcessRequests(void) {
    @autoreleasepool {
    @synchronized(PFPosterBuilder.class) {
    NSError *directoryError=nil;
    if(!PFEnsureDirectories(&directoryError)){NSLog(@"PosterForge queue directories: %@",directoryError);return;}
    NSFileManager *fm=NSFileManager.defaultManager;
    NSArray *requests=[fm contentsOfDirectoryAtPath:PFRequestsDirectory error:&directoryError];
    if(!requests){NSLog(@"PosterForge cannot enumerate requests: %@",directoryError);return;}
    if(!requests.count)return;
    PFMemoryStatus memory=PFConfigureCurrentProcessMemory();
    if(!memory.verified){NSLog(@"PosterForge leaving requests queued: memory budget not verified %@",PFMemoryReport(memory));return;}
    PFPosterBuilder *builder=[PFPosterBuilder new];
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
        NSLog(@"PosterForge post-request footprint=%llu bytes",(unsigned long long)PFCurrentFootprintBytes());
        if(![fm removeItemAtPath:path error:&directoryError])NSLog(@"PosterForge cannot clear request %@: %@",name,directoryError);
    }
    }
    }
}

static void NotificationCallback(CFNotificationCenterRef c,void *o,CFStringRef n,const void *obj,CFDictionaryRef info){ ProcessRequests(); }

int main(int argc,char **argv){
    // C-only: establish this PID's budget before creating Foundation objects.
    PFMemoryStatus startup={0};
    if(argc==1) {
        if(geteuid()!=0){fprintf(stderr,"posterforged must run as root in system/com.posterforge.daemon\n");return 77;}
        startup=PFConfigureCurrentProcessMemory();
    }
    @autoreleasepool {
    umask(0022);
    if(argc==2&&strcmp(argv[1],"--diagnose-container")==0) {
        NSError *error=nil;NSString *container=PFPosterBoardContainerWithError(&error);
        NSDictionary *result=container?@{@"success":@YES,@"container":container}:@{@"success":@NO,@"errorDetails":PFErrorDetails(error)};
        PFPrintJSON(result);return container?0:1;
    }
    if((argc==2||argc==3)&&strcmp(argv[1],"--diagnose-runtime")==0) {
        pid_t target=getpid();
        if(argc==3){char *end=NULL;long value=strtol(argv[2],&end,10);if(!end||*end||value<=1||value>INT_MAX)return 64;target=(pid_t)value;}
        PFMemoryStatus memory=PFReadProcessMemory(target);
        NSMutableDictionary *report=[PFMemoryReport(memory) mutableCopy];
        report[@"success"]=@(!memory.afterError);report[@"readOnly"]=@YES;
        report[@"targetIsDiagnosticProcess"]=@(target==getpid());
        report[@"expectedLaunchdService"]=@"system/com.posterforge.daemon";
        report[@"domainVerification"]=@"Correlate targetPID with launchctl print system/com.posterforge.daemon; this JSON does not infer a bootstrap domain from UID or foreground state.";
        PFPrintJSON(report);return memory.verified?0:1;
    }
    if(argc!=1){fprintf(stderr,"usage: posterforged [--diagnose-container | --diagnose-runtime [PID]]\n");return 64;}
    NSLog(@"PosterForge 0.1.2 daemon started pid=%d ppid=%d uid=%u euid=%u XPC_SERVICE_NAME=%s memory=%@",
          getpid(),getppid(),getuid(),geteuid(),getenv("XPC_SERVICE_NAME") ?: "(unset)",PFMemoryReport(startup));
    if(!startup.verified)NSLog(@"PosterForge memory SET/readback was not verified; heavy requests will remain queued");
    ProcessRequests();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),NULL,NotificationCallback,(__bridge CFStringRef)PFReloadNotification,NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
    NSTimer *timer=[NSTimer timerWithTimeInterval:3 repeats:YES block:^(NSTimer *t){ProcessRequests();}]; [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    }
    // Drain temporary objects on EVERY iteration instead of retaining the
    // startup autorelease pool for the daemon's entire lifetime.
    for(;;)@autoreleasepool {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:3]];
    }
}
