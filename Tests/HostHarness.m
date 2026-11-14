#import <Foundation/Foundation.h>
#import "../Shared/PFShared.h"
#import "../Daemon/PFTendiesArchive.h"
#import <stdio.h>
#import <string.h>

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
    } else return 2;
    NSMutableDictionary *result = [@{@"success":@(value != nil)} mutableCopy];
    if (value) result[@"value"] = value;
    if (error) { result[@"error"] = error.localizedDescription; result[@"domain"] = error.domain; result[@"code"] = @(error.code); }
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout);
    return value ? 0 : 1;
} }
