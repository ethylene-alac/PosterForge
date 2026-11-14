#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
extern NSString * const PFRootDirectory;
extern NSString * const PFLibraryDirectory;
extern NSString * const PFRequestsDirectory;
extern NSString * const PFCompletedDirectory;
extern NSString * const PFReloadNotification;

FOUNDATION_EXPORT BOOL PFEnsureDirectories(NSError **error);
FOUNDATION_EXPORT NSString *PFNewIdentifier(void);
FOUNDATION_EXPORT NSArray<NSDictionary *> *PFLoadItems(void);
FOUNDATION_EXPORT BOOL PFSaveItem(NSDictionary *item, NSError **error);
FOUNDATION_EXPORT BOOL PFDeleteItem(NSString *identifier, NSError **error);
FOUNDATION_EXPORT BOOL PFQueueRequest(NSDictionary *request, NSError **error);
FOUNDATION_EXPORT NSString * _Nullable PFPosterBoardContainer(void);
FOUNDATION_EXPORT NSString * _Nullable PFPosterBoardContainerWithError(NSError **error);
// The base-path variant is also used by host tests with disposable containers.
FOUNDATION_EXPORT NSString * _Nullable PFFindPosterBoardContainer(NSString *base, NSError **error);
NS_ASSUME_NONNULL_END
