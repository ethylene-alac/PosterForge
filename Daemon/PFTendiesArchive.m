#import "PFTendiesArchive.h"
#import <sys/stat.h>
#import <zlib.h>
#import <string.h>
#import <errno.h>

static BOOL PFFail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"com.posterforge.tendies" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static uint16_t U16(const uint8_t *p) { return p[0] | ((uint16_t)p[1] << 8); }
static uint32_t U32(const uint8_t *p) { return U16(p) | ((uint32_t)U16(p + 2) << 16); }

BOOL PFExtractTendiesArchive(NSString *path, NSString *staging, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *attributes = [fm attributesOfItemAtPath:path error:error];
    if (!attributes) return NO;
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular] || [attributes[NSFileSize] unsignedLongLongValue] > 256ULL * 1024 * 1024)
        return PFFail(error, @"Tendies archive must be a regular ZIP file no larger than 256 MiB");
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!data) return NO;
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length, end = NSNotFound;
    if (length < 22) return PFFail(error, @"Truncated Tendies ZIP");
    NSUInteger minimum = length > 65557 ? length - 65557 : 0;
    for (NSUInteger i = length - 22;; i--) {
        if (U32(bytes + i) == 0x06054b50 && i + 22 + U16(bytes + i + 20) == length) { end = i; break; }
        if (i == minimum) break;
    }
    if (end == NSNotFound) return PFFail(error, @"Missing ZIP central directory");
    const uint8_t *eocd = bytes + end;
    NSUInteger count = U16(eocd + 10), size = U32(eocd + 12), offset = U32(eocd + 16);
    if (U16(eocd + 4) || U16(eocd + 6) || U16(eocd + 8) != count || count == 65535 ||
        !count || count > 20000 || offset > end || size != end - offset)
        return PFFail(error, @"Unsupported multi-disk/ZIP64 ZIP or invalid directory bounds");
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *paths = [NSMutableDictionary dictionary];
    uint64_t total = 0;
    for (NSUInteger index = 0; index < count; index++) {
        if (offset > end || end - offset < 46 || U32(bytes + offset) != 0x02014b50)
            return PFFail(error, @"Invalid ZIP directory entry");
        const uint8_t *h = bytes + offset;
        NSUInteger nameLength = U16(h + 28), extraLength = U16(h + 30), commentLength = U16(h + 32);
        NSUInteger next = offset + 46 + nameLength + extraLength + commentLength;
        if (!nameLength || next > end) return PFFail(error, @"Invalid ZIP filename bounds");
        NSString *name = [[NSString alloc] initWithBytes:h + 46 length:nameLength encoding:NSUTF8StringEncoding];
        if (!name || [name hasPrefix:@"/"] || [name containsString:@"\\"] || [name containsString:@":"] ||
            [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
            return PFFail(error, @"Unsafe or non-UTF8 path in Tendies archive");
        BOOL directory = [name hasSuffix:@"/"];
        NSString *clean = directory ? [name substringToIndex:name.length - 1] : name;
        NSArray *components = [clean componentsSeparatedByString:@"/"];
        for (NSString *component in components) {
            if (!component.length || [component isEqual:@"."] || [component isEqual:@".."])
                return PFFail(error, @"Unsafe path in Tendies archive");
            if ([component.lowercaseString isEqual:@"container"])
                return PFFail(error, @"Container-format Tendies archives are not supported (including mixed Container/Descriptor archives)");
        }
        NSString *key = clean.precomposedStringWithCanonicalMapping.lowercaseString;
        if (paths[key]) return PFFail(error, @"Duplicate or case-colliding ZIP paths");
        paths[key] = @(directory);
        unsigned mode = U32(h + 38) >> 16, type = mode & S_IFMT;
        if (type && type != (directory ? S_IFDIR : S_IFREG))
            return PFFail(error, @"Links and special files are not allowed in Tendies archives");
        unsigned flags = U16(h + 8), method = U16(h + 10);
        NSUInteger compressed = U32(h + 20), uncompressed = U32(h + 24), local = U32(h + 42);
        total += uncompressed;
        if ((flags & ~0x080E) || (method != 0 && method != 8) || U16(h + 34) ||
            uncompressed > 256ULL * 1024 * 1024 || total > 1024ULL * 1024 * 1024 ||
            local > U32(eocd + 16) || U32(eocd + 16) - local < 30 || U32(bytes + local) != 0x04034b50)
            return PFFail(error, @"Unsupported ZIP encryption/compression, excessive size, or invalid local header");
        const uint8_t *lh = bytes + local;
        NSUInteger payload = local + 30 + U16(lh + 26) + U16(lh + 28);
        if (U16(lh + 6) != flags || U16(lh + 8) != method || U16(lh + 26) != nameLength ||
            payload > U32(eocd + 16) || compressed > U32(eocd + 16) - payload ||
            memcmp(lh + 30, h + 46, nameLength) != 0 || (directory && uncompressed))
            return PFFail(error, @"ZIP local and central headers disagree");
        [entries addObject:@{@"name":clean, @"directory":@(directory), @"method":@(method), @"payload":@(payload),
                             @"compressed":@(compressed), @"size":@(uncompressed), @"crc":@(U32(h + 16))}];
        offset = next;
    }
    if (offset != end) return PFFail(error, @"Unexpected data in ZIP directory");
    // Check implicit parents too, before creating any files.
    for (NSString *key in paths) {
        NSString *parent = key.stringByDeletingLastPathComponent;
        while (parent.length) {
            if (paths[parent] && !paths[parent].boolValue) return PFFail(error, @"ZIP file/directory path collision");
            parent = parent.stringByDeletingLastPathComponent;
        }
    }
    if (mkdir(staging.fileSystemRepresentation, 0755) != 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{NSFilePathErrorKey:staging}];
        return NO;
    }
    for (NSDictionary *entry in entries) @autoreleasepool {
        NSString *destination = [staging stringByAppendingPathComponent:entry[@"name"]];
        if (![fm createDirectoryAtPath:destination.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:error]) return NO;
        NSUInteger uncompressed = [entry[@"size"] unsignedIntegerValue], compressed = [entry[@"compressed"] unsignedIntegerValue];
        const uint8_t *payload = bytes + [entry[@"payload"] unsignedIntegerValue];
        NSMutableData *output = [NSMutableData dataWithLength:MAX((NSUInteger)1, uncompressed)];
        if ([entry[@"method"] intValue] == 0) {
            if (uncompressed != compressed) return PFFail(error, @"Invalid stored ZIP size");
            memcpy(output.mutableBytes, payload, uncompressed);
        } else {
            z_stream stream = {0};
            stream.next_in = (Bytef *)payload; stream.avail_in = (uInt)compressed;
            stream.next_out = output.mutableBytes; stream.avail_out = (uInt)output.length;
            if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return PFFail(error, @"Cannot initialize ZIP decompressor");
            int rc = inflate(&stream, Z_FINISH);
            BOOL valid = rc == Z_STREAM_END && stream.total_out == uncompressed && stream.total_in == compressed;
            inflateEnd(&stream);
            if (!valid) return PFFail(error, @"Invalid deflated ZIP data");
        }
        output.length = uncompressed;
        if ((uint32_t)crc32(0L, output.bytes, (uInt)uncompressed) != [entry[@"crc"] unsignedIntValue])
            return PFFail(error, @"ZIP checksum mismatch");
        if ([entry[@"directory"] boolValue]) {
            if (![fm createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:error]) return NO;
            continue;
        }
        if (![output writeToFile:destination options:NSDataWritingWithoutOverwriting error:error]) return NO;
    }
    return YES;
}

NSArray<NSString *> *PFTendiesDescriptorPaths(NSString *staging, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    __block NSError *enumerationError = nil;
    NSDirectoryEnumerator *en = [fm enumeratorAtURL:[NSURL fileURLWithPath:staging] includingPropertiesForKeys:nil
        options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^BOOL(NSURL *url, NSError *e) { enumerationError = e; return NO; }];
    for (NSURL *url in en) {
        if ([url.lastPathComponent isEqual:@"__MACOSX"]) { [en skipDescendants]; continue; }
        NSString *name = url.lastPathComponent.lowercaseString;
        if (![name isEqual:@"descriptor"] && ![name isEqual:@"descriptors"]) continue;
        NSArray *children = [fm contentsOfDirectoryAtPath:url.path error:&enumerationError];
        if (!children) break;
        for (NSString *child in children) {
            if ([child hasPrefix:@"."] || [child isEqual:@"__MACOSX"]) continue;
            NSString *candidate = [url.path stringByAppendingPathComponent:child];
            BOOL directory = NO;
            if (![fm fileExistsAtPath:candidate isDirectory:&directory] || !directory) continue;
            NSString *identifier = [candidate stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"];
            NSString *role = [candidate stringByAppendingPathComponent:@"com.apple.posterkit.role.identifier"];
            NSString *versions = [candidate stringByAppendingPathComponent:@"versions"];
            BOOL versionsDirectory = NO;
            if (![fm isReadableFileAtPath:identifier] || ![fm isReadableFileAtPath:role] ||
                ![fm fileExistsAtPath:versions isDirectory:&versionsDirectory] || !versionsDirectory) {
                PFFail(error, [NSString stringWithFormat:@"Invalid descriptor layout: %@", child]); return nil;
            }
            [result addObject:candidate];
        }
        [en skipDescendants];
    }
    if (enumerationError) { if (error) *error = enumerationError; return nil; }
    if (!result.count) { PFFail(error, @"No supported descriptor/descriptors folder found in Tendies archive"); return nil; }
    return [result sortedArrayUsingSelector:@selector(compare:)];
}

BOOL PFRandomizeTendiesDescriptor(NSString *path, NSInteger newID, NSError **error) {
    if (![[NSString stringWithFormat:@"%ld", (long)newID] writeToFile:[path stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"]
        atomically:YES encoding:NSUTF8StringEncoding error:error]) return NO;
    __block NSError *enumerationError = nil;
    NSDirectoryEnumerator *en = [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:path] includingPropertiesForKeys:nil options:0
        errorHandler:^BOOL(NSURL *url, NSError *e) { enumerationError = e; return NO; }];
    for (NSURL *url in en) {
        NSString *name = url.lastPathComponent;
        if (![name isEqual:@"Wallpaper.plist"] && ![name isEqual:@"com.apple.posterkit.provider.contents.userInfo"]) continue;
        NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error]; if (!data) return NO;
        id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:NULL error:error];
        if (![plist isKindOfClass:NSMutableDictionary.class]) return PFFail(error, @"Descriptor metadata must be a dictionary plist");
        if ([name isEqual:@"Wallpaper.plist"]) {
            plist[@"identifier"] = @(newID);
            // Keep nested asset IDs intact: packages may refer to those IDs.
        } else plist[@"wallpaperRepresentingIdentifier"] = [NSString stringWithFormat:@"%ld", (long)newID];
        NSData *updated = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
        if (!updated || ![updated writeToURL:url options:NSDataWritingAtomic error:error]) return NO;
    }
    if (enumerationError) { if (error) *error = enumerationError; return NO; }
    return YES;
}
