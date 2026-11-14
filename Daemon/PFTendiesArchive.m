#import "PFTendiesArchive.h"
#import <sys/stat.h>
#import <zlib.h>
#import <string.h>
#import <errno.h>
#import <fcntl.h>
#import <unistd.h>

static BOOL PFFail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"com.posterforge.tendies" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static uint16_t U16(const uint8_t *p) { return p[0] | ((uint16_t)p[1] << 8); }
static uint32_t U32(const uint8_t *p) { return U16(p) | ((uint32_t)U16(p + 2) << 16); }

static BOOL PFPOSIXError(NSError **error, NSString *path) {
    int code=errno ?: EIO;
    if(error)*error=[NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:@{NSFilePathErrorKey:path}];
    return NO;
}

static BOOL PFReadAt(int fd, void *buffer, size_t length, off_t offset, NSError **error) {
    uint8_t *cursor=buffer;
    while(length) {
        ssize_t count=pread(fd,cursor,length,offset);
        if(count<0&&errno==EINTR)continue;
        if(count<0)return PFPOSIXError(error,@"Tendies ZIP read");
        if(!count)return PFFail(error,@"Truncated Tendies ZIP payload");
        cursor+=count;offset+=count;length-=(size_t)count;
    }
    return YES;
}

static BOOL PFWriteAll(int fd, const uint8_t *buffer, size_t length, NSError **error) {
    while(length) {
        ssize_t count=write(fd,buffer,length);
        if(count<0&&errno==EINTR)continue;
        if(count<=0)return PFPOSIXError(error,@"Tendies staged file write");
        buffer+=count;length-=(size_t)count;
    }
    return YES;
}

static BOOL PFExtractEntry(NSDictionary *entry, int archive, NSString *staging, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *destination = [staging stringByAppendingPathComponent:entry[@"name"]];
    if (![fm createDirectoryAtPath:destination.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:error]) return NO;
    NSUInteger uncompressed = [entry[@"size"] unsignedIntegerValue], compressed = [entry[@"compressed"] unsignedIntegerValue];
    off_t position=[entry[@"payload"] longLongValue];
    BOOL directory=[entry[@"directory"] boolValue], deflated=[entry[@"method"] intValue]==8;
    if(!deflated&&uncompressed!=compressed)return PFFail(error,@"Invalid stored ZIP size");
    int output=directory?-1:open(destination.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0644);
    if(!directory&&output<0)return PFPOSIXError(error,destination);
    uint8_t inputBuffer[65536], outputBuffer[65536];
    z_stream stream={0};
    BOOL initialized=NO, ok=YES, ended=NO;
    uint64_t producedTotal=0;
    uLong checksum=crc32(0L,Z_NULL,0);
    if(deflated) {
        initialized=inflateInit2(&stream,-MAX_WBITS)==Z_OK;
        if(!initialized)ok=PFFail(error,@"Cannot initialize ZIP decompressor");
    }
    NSUInteger remaining=compressed;
    while(ok&&(!ended)&&(remaining||stream.avail_in||deflated)) {
        if(!stream.avail_in&&remaining) {
            size_t count=MIN(sizeof(inputBuffer),remaining);
            if(!PFReadAt(archive,inputBuffer,count,position,error)){ok=NO;break;}
            position+=(off_t)count;remaining-=count;
            stream.next_in=inputBuffer;stream.avail_in=(uInt)count;
        }
        const uint8_t *chunk=inputBuffer;
        size_t count=stream.avail_in;
        if(deflated) {
            stream.next_out=outputBuffer;stream.avail_out=sizeof(outputBuffer);
            uInt previousInput=stream.avail_in;
            int rc=inflate(&stream,Z_NO_FLUSH);
            count=sizeof(outputBuffer)-stream.avail_out;chunk=outputBuffer;
            ended=rc==Z_STREAM_END;
            if((rc!=Z_OK&&!ended)||(!ended&&!count&&previousInput==stream.avail_in)) {
                ok=PFFail(error,@"Invalid or truncated deflated ZIP data");break;
            }
            if(ended&&(remaining||stream.avail_in)){ok=PFFail(error,@"Unexpected trailing deflated ZIP data");break;}
        } else stream.avail_in=0;
        if(producedTotal+count>uncompressed){ok=PFFail(error,@"ZIP output exceeds declared size");break;}
        producedTotal+=count;checksum=crc32(checksum,chunk,(uInt)count);
        if(!directory&&count&&!PFWriteAll(output,chunk,count,error)){ok=NO;break;}
        if(!deflated&&!remaining)ended=YES;
    }
    if(initialized)inflateEnd(&stream);
    if(ok&&(producedTotal!=uncompressed||(deflated&&!ended)))ok=PFFail(error,@"Invalid ZIP expanded size");
    if(ok&&(uint32_t)checksum!=[entry[@"crc"] unsignedIntValue])ok=PFFail(error,@"ZIP checksum mismatch");
    if(output>=0&&close(output)!=0&&ok)ok=PFPOSIXError(error,destination);
    if(!ok){if(output>=0)unlink(destination.fileSystemRepresentation);return NO;}
    return !directory||[fm createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:error];
}

static BOOL PFExtractZIP(int archive, NSUInteger length, NSString *staging, NSError **error) {
    if (length < 22) return PFFail(error, @"Truncated Tendies ZIP");
    NSUInteger tailLength=MIN(length,(NSUInteger)65557), end=NSNotFound;
    NSMutableData *tail=[NSMutableData dataWithLength:tailLength];
    if(!PFReadAt(archive,tail.mutableBytes,tailLength,(off_t)(length-tailLength),error))return NO;
    const uint8_t *bytes=tail.bytes;
    for (NSUInteger i = tailLength - 22;; i--) {
        if (U32(bytes + i) == 0x06054b50 && i + 22 + U16(bytes + i + 20) == tailLength) { end = length-tailLength+i; break; }
        if (i == 0) break;
    }
    if (end == NSNotFound) return PFFail(error, @"Missing ZIP central directory");
    const uint8_t *eocd = bytes + end-(length-tailLength);
    NSUInteger count = U16(eocd + 10), size = U32(eocd + 12), offset = U32(eocd + 16);
    if (U16(eocd + 4) || U16(eocd + 6) || U16(eocd + 8) != count || count == 65535 ||
        !count || count > 20000 || size>8*1024*1024 || offset > end || size != end - offset)
        return PFFail(error, @"Unsupported multi-disk/ZIP64 ZIP or invalid directory bounds");
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *paths = [NSMutableDictionary dictionary];
    uint64_t total = 0, pathBytes=0;
    for (NSUInteger index = 0; index < count; index++) {
        uint8_t header[46];
        if (offset > end || end - offset < 46 || !PFReadAt(archive,header,sizeof(header),offset,error))
            return PFFail(error, @"Invalid ZIP directory entry");
        const uint8_t *h = header;
        if(U32(h)!=0x02014b50)return PFFail(error,@"Invalid ZIP directory entry signature");
        NSUInteger nameLength = U16(h + 28), extraLength = U16(h + 30), commentLength = U16(h + 32);
        NSUInteger next = offset + 46 + nameLength + extraLength + commentLength;
        pathBytes+=nameLength;
        if (!nameLength || nameLength>1024 || pathBytes>4*1024*1024 || next > end) return PFFail(error, @"Invalid or excessive ZIP filename bounds");
        NSMutableData *nameBytes=[NSMutableData dataWithLength:nameLength];
        if(!PFReadAt(archive,nameBytes.mutableBytes,nameLength,offset+46,error))return NO;
        NSString *name = [[NSString alloc] initWithData:nameBytes encoding:NSUTF8StringEncoding];
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
            local > U32(eocd + 16) || U32(eocd + 16) - local < 30)
            return PFFail(error, @"Unsupported ZIP encryption/compression, excessive size, or invalid local header");
        uint8_t localHeader[30];
        if(!PFReadAt(archive,localHeader,sizeof(localHeader),local,error))return NO;
        const uint8_t *lh = localHeader;
        NSUInteger payload = local + 30 + U16(lh + 26) + U16(lh + 28);
        if (U32(lh)!=0x04034b50 || U16(lh + 6) != flags || U16(lh + 8) != method || U16(lh + 26) != nameLength ||
            payload > U32(eocd + 16) || compressed > U32(eocd + 16) - payload ||
            (directory && uncompressed))
            return PFFail(error, @"ZIP local and central headers disagree");
        NSMutableData *localName=[NSMutableData dataWithLength:nameLength];
        if(!PFReadAt(archive,localName.mutableBytes,nameLength,local+30,error))return NO;
        if(![localName isEqualToData:nameBytes])return PFFail(error,@"ZIP local and central headers disagree");
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
    for (NSDictionary *entry in entries) {
        // Retain errors before draining the entry's pool. An autoreleasing
        // out-parameter pointing into that pool would dangle on CRC/write failure.
        NSError *entryError = nil;
        BOOL extracted = NO;
        @autoreleasepool { extracted = PFExtractEntry(entry, archive, staging, &entryError); }
        if (!extracted) {
            if (error) *error = entryError;
            return NO;
        }
    }
    return YES;
}

BOOL PFExtractTendiesArchive(NSString *path, NSString *staging, NSError **error) {
    int archive=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    if(archive<0)return PFPOSIXError(error,path);
    BOOL ok=NO;
    @try {
        struct stat attributes;
        if(fstat(archive,&attributes)!=0)return PFPOSIXError(error,path);
        if(!S_ISREG(attributes.st_mode)||attributes.st_size<0||attributes.st_size>256LL*1024*1024)
            return PFFail(error,@"Tendies archive must be a regular ZIP file no larger than 256 MiB");
        ok=PFExtractZIP(archive,(NSUInteger)attributes.st_size,staging,error);
    } @finally { close(archive); }
    return ok;
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

static BOOL PFUpdateDescriptorPlist(NSURL *url, NSInteger newID, NSError **error) {
        NSString *name = url.lastPathComponent;
        if (![name isEqual:@"Wallpaper.plist"] && ![name isEqual:@"com.apple.posterkit.provider.contents.userInfo"]) return YES;
        NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:error];
        if(!attributes)return NO;
        if([attributes[NSFileSize] unsignedLongLongValue]>1024*1024)return PFFail(error,@"Descriptor metadata plist exceeds 1 MiB");
        NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error]; if (!data) return NO;
        id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:NULL error:error];
        if (![plist isKindOfClass:NSMutableDictionary.class]) return PFFail(error, @"Descriptor metadata must be a dictionary plist");
        if ([name isEqual:@"Wallpaper.plist"]) {
            plist[@"identifier"] = @(newID);
            // Keep nested asset IDs intact: packages may refer to those IDs.
        } else plist[@"wallpaperRepresentingIdentifier"] = [NSString stringWithFormat:@"%ld", (long)newID];
        NSData *updated = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
        if (!updated || ![updated writeToURL:url options:NSDataWritingAtomic error:error]) return NO;
    return YES;
}

BOOL PFRandomizeTendiesDescriptor(NSString *path, NSInteger newID, NSError **error) {
    if (![[NSString stringWithFormat:@"%ld", (long)newID] writeToFile:[path stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"]
        atomically:YES encoding:NSUTF8StringEncoding error:error]) return NO;
    __block NSError *enumerationError = nil;
    NSDirectoryEnumerator *en = [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:path] includingPropertiesForKeys:nil options:0
        errorHandler:^BOOL(NSURL *url, NSError *e) { enumerationError = e; return NO; }];
    for (NSURL *url in en) {
        NSError *entryError=nil;BOOL ok=NO;
        @autoreleasepool { ok=PFUpdateDescriptorPlist(url,newID,&entryError); }
        if(!ok){if(error)*error=entryError;return NO;}
    }
    if (enumerationError) { if (error) *error = enumerationError; return NO; }
    return YES;
}
