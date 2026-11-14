#import <Foundation/Foundation.h>
#import "../Shared/PFShared.h"
#import "../Daemon/PFTendiesArchive.h"
#import "../Daemon/PFMemory.h"
#import <stdio.h>
#import <string.h>
#import <errno.h>
#import <sys/resource.h>

static PFMemoryLimits fakeLimits;
static int fakeSets, fakeMode;
static int FakeMemoryControl(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t size) {
    if(pid!=321||flags||size!=sizeof(PFMemoryLimits)){errno=EINVAL;return -1;}
    if(command==8){*(PFMemoryLimits *)buffer=fakeLimits;return 0;}
    if(command==7){
        fakeSets++;
        if(fakeMode==1){errno=EPERM;return -1;}
        if(fakeMode!=2)fakeLimits=*(PFMemoryLimits *)buffer;
        return 0;
    }
    errno=EINVAL;return -1;
}

int main(int argc, char **argv) { @autoreleasepool {
    NSError *error = nil;
    id value = nil;
    if (argc == 3 && strcmp(argv[1], "scan") == 0) {
        value = PFFindPosterBoardContainer(@(argv[2]), &error);
    } else if (argc == 4 && strcmp(argv[1], "archive") == 0) {
        NSString *staging = @(argv[3]);
        if (PFExtractTendiesArchive(@(argv[2]), staging, &error)) value = PFTendiesDescriptorPaths(staging, &error);
    } else if (argc == 4 && strcmp(argv[1], "randomize") == 0) {
        if (PFRandomizeTendiesDescriptor(@(argv[2]), [@(argv[3]) integerValue], &error)) value = @YES;
    } else if (argc == 3 && strcmp(argv[1], "memory-mock") == 0) {
        fakeLimits=(PFMemoryLimits){6,1,6,1};fakeMode=0;fakeSets=0;
        NSString *mode=@(argv[2]);
        if([mode isEqual:@"denied"])fakeMode=1;
        if([mode isEqual:@"ignored"])fakeMode=2;
        if([mode isEqual:@"higher"])fakeLimits=(PFMemoryLimits){256,1,384,1};
        if([mode isEqual:@"mixed"])fakeLimits=(PFMemoryLimits){256,1,6,1};
        PFMemoryStatus status=PFMemoryConfigureUsing([mode isEqual:@"missing"]?NULL:FakeMemoryControl,321);
        value=@{@"verified":@(status.verified),@"activeMB":@(status.after.activeMB),@"inactiveMB":@(status.after.inactiveMB),
                @"setCalls":@(fakeSets),@"setErrno":@(status.setError),@"readbackErrno":@(status.afterError)};
    } else return 2;
    NSMutableDictionary *result = [@{@"success":@(value != nil)} mutableCopy];
    struct rusage usage={0};getrusage(RUSAGE_SELF,&usage);result[@"peakResidentBytes"]=@(usage.ru_maxrss);
    if (value) result[@"value"] = value;
    if (error) { result[@"error"] = error.localizedDescription; result[@"domain"] = error.domain; result[@"code"] = @(error.code); }
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout);
    return value ? 0 : 1;
} }
