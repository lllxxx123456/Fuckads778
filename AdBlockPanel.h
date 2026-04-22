#import <UIKit/UIKit.h>

/* 触摸穿透窗口（面板专用） */
@interface AdBlockOverlayWindow : UIWindow
@end

/* 面板主控制器 */
@interface AdBlockPanelManager : NSObject
+ (instancetype)shared;
- (void)showFromGesture:(UILongPressGestureRecognizer *)gesture;
- (void)dismiss;
- (void)openFullScreenVC:(UIViewController *)vc title:(NSString *)title;
- (void)closeModalWindow;
@end

/* 抓包条目 */
@interface AdBlockCaptureEntry : NSObject
@property (nonatomic, copy)   NSString *urlString;
@property (nonatomic, copy)   NSString *method;
@property (nonatomic, strong) NSDate   *date;
@property (nonatomic)         BOOL      isAd;
@end

/* 抓包会话（开→关 = 一个会话）*/
@interface AdBlockCaptureSession : NSObject
@property (nonatomic, strong) NSDate                       *startDate;
@property (nonatomic, copy)   NSArray<AdBlockCaptureEntry *>   *entries;
@end

/* 抓包管理器 */
@interface AdBlockCaptureManager : NSObject
+ (instancetype)shared;
@property (nonatomic) BOOL capturing;
@property (nonatomic, readonly) NSArray<AdBlockCaptureEntry *>  *currentEntries;
@property (nonatomic, readonly) NSArray<AdBlockCaptureSession *> *sessions;
- (void)addURLString:(NSString *)url method:(NSString *)method isAd:(BOOL)ad;
- (void)startCapturing;
- (void)stopAndSaveSession;
- (void)removeSessionAtIndex:(NSUInteger)idx;
- (void)clearAllSessions;
@end

/* 规则工具 */
#ifdef __cplusplus
extern "C" {
#endif
NSArray<NSString *>             *AdBlockCustomPatterns(void);
BOOL                             AdBlockIsCustomBlocked(NSString *urlString);
void                             AdBlockAddCustomPattern(NSString *pattern);
void                             AdBlockRemoveCustomPatternAtIndex(NSUInteger idx);
NSArray<NSDictionary *>         *AdBlockBatchBlocks(void);
void                             AdBlockAddBatchBlock(NSArray<NSString *> *hosts);
void                             AdBlockRemoveBatchBlockAtIndex(NSUInteger idx);
#ifdef __cplusplus
}
#endif
