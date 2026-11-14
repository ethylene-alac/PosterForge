#import <Foundation/Foundation.h>

// Extracts only a bounded, unencrypted ZIP of ordinary files/directories into
// a new staging directory. No archive-supplied permissions or links are applied.
BOOL PFExtractTendiesArchive(NSString *path, NSString *staging, NSError **error);
NSArray<NSString *> *PFTendiesDescriptorPaths(NSString *staging, NSError **error);
BOOL PFRandomizeTendiesDescriptor(NSString *path, NSInteger newID, NSError **error);
