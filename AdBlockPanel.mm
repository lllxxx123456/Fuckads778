#import "AdBlockPanel.h"
#import <QuartzCore/QuartzCore.h>

#define ADBLOCK_SUITE        @"com.jijiang778.dsxnoads"
#define KEY_AD_BLOCK     @"adBlockEnabled"
#define KEY_IAP          @"iapUnlockEnabled"
#define KEY_CUSTOM_PAT   @"customPatterns"
#define KEY_SESSIONS     @"captureSessions"
#define KEY_BATCH_BLOCKS @"batchBlocks"

/* ─────────── 偏好读写 ─────────── */
static NSDictionary *AdBlockPrefs(void) {
    return [[NSUserDefaults standardUserDefaults] persistentDomainForName:ADBLOCK_SUITE] ?: @{};
}
static void AdBlockWritePrefs(NSDictionary *d) {
    [[NSUserDefaults standardUserDefaults] setPersistentDomain:d forName:ADBLOCK_SUITE];
    [[NSUserDefaults standardUserDefaults] synchronize];
}
static void AdBlockSavePref(NSString *key, BOOL val) {
    NSMutableDictionary *d = [AdBlockPrefs() mutableCopy];
    d[key] = @(val);
    AdBlockWritePrefs(d);
}

/* ─────────── 自定义屏蔽规则（extern "C" 保证 C++ 编译单元输出 C 链接符号）─────────── */
#ifdef __cplusplus
extern "C" {
#endif

NSArray<NSString *> *AdBlockCustomPatterns(void) {
    return AdBlockPrefs()[KEY_CUSTOM_PAT] ?: @[];
}
BOOL AdBlockIsCustomBlocked(NSString *url) {
    if (!url.length) return NO;
    for (NSString *p in AdBlockCustomPatterns())
        if (p.length && [url containsString:p]) return YES;
    return NO;
}
void AdBlockAddCustomPattern(NSString *pattern) {
    if (!pattern.length) return;
    NSMutableDictionary *d = [AdBlockPrefs() mutableCopy];
    NSMutableArray *arr = [(d[KEY_CUSTOM_PAT] ?: @[]) mutableCopy];
    if (![arr containsObject:pattern]) [arr addObject:pattern];
    d[KEY_CUSTOM_PAT] = arr;
    AdBlockWritePrefs(d);
}
void AdBlockRemoveCustomPatternAtIndex(NSUInteger idx) {
    NSMutableDictionary *d = [AdBlockPrefs() mutableCopy];
    NSMutableArray *arr = [(d[KEY_CUSTOM_PAT] ?: @[]) mutableCopy];
    if (idx < arr.count) [arr removeObjectAtIndex:idx];
    d[KEY_CUSTOM_PAT] = arr;
    AdBlockWritePrefs(d);
}
NSArray<NSDictionary *> *AdBlockBatchBlocks(void) {
    return AdBlockPrefs()[KEY_BATCH_BLOCKS] ?: @[];
}
void AdBlockAddBatchBlock(NSArray<NSString *> *hosts) {
    if (!hosts.count) return;
    NSMutableDictionary *d = [AdBlockPrefs() mutableCopy];
    NSMutableArray *batches = [(d[KEY_BATCH_BLOCKS] ?: @[]) mutableCopy];
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    [batches insertObject:@{ @"ts": @([NSDate date].timeIntervalSince1970),
                             @"label": [df stringFromDate:[NSDate date]],
                             @"hosts": hosts } atIndex:0];
    d[KEY_BATCH_BLOCKS] = batches;
    NSMutableArray *customs = [(d[KEY_CUSTOM_PAT] ?: @[]) mutableCopy];
    for (NSString *h in hosts) if (![customs containsObject:h]) [customs addObject:h];
    d[KEY_CUSTOM_PAT] = customs;
    AdBlockWritePrefs(d);
}
void AdBlockRemoveBatchBlockAtIndex(NSUInteger idx) {
    NSMutableDictionary *d = [AdBlockPrefs() mutableCopy];
    NSMutableArray *batches = [(d[KEY_BATCH_BLOCKS] ?: @[]) mutableCopy];
    if (idx >= batches.count) return;
    NSArray *hosts = batches[idx][@"hosts"];
    [batches removeObjectAtIndex:idx];
    d[KEY_BATCH_BLOCKS] = batches;
    NSMutableArray *customs = [(d[KEY_CUSTOM_PAT] ?: @[]) mutableCopy];
    for (NSString *h in hosts) [customs removeObject:h];
    d[KEY_CUSTOM_PAT] = customs;
    AdBlockWritePrefs(d);
}

#ifdef __cplusplus
}
#endif

/* ─────────── 礼花片图片 ─────────── */
static UIImage *AdBlockPaperRect(UIColor *c) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(10, 6), NO, 0);
    [c setFill]; UIRectFill(CGRectMake(0,0,10,6));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

/* ━━━━━━━━━━━━━━━━  触摸穿透窗口（修复：也跳过 rootVC.view）  ━━━━━━━━━━━━━━━━ */

@implementation AdBlockOverlayWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *hit = [super hitTest:p withEvent:e];
    if (!hit || hit == self) return nil;
    if (self.rootViewController && hit == self.rootViewController.view) return nil;
    return hit;
}
@end

/* ━━━━━━━━━━━━━━━━  抓包条目  ━━━━━━━━━━━━━━━━ */

@implementation AdBlockCaptureEntry
@end

/* ━━━━━━━━━━━━━━━━  抓包会话  ━━━━━━━━━━━━━━━━ */

@implementation AdBlockCaptureSession
@end

/* ━━━━━━━━━━━━━━━━  抓包管理器  ━━━━━━━━━━━━━━━━ */

@implementation AdBlockCaptureManager {
    NSMutableArray<AdBlockCaptureEntry *>  *_current;
    NSMutableArray<AdBlockCaptureSession *> *_sessions;
    NSDate *_sessionStart;
}

+ (instancetype)shared {
    static AdBlockCaptureManager *s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [AdBlockCaptureManager new]; });
    return s;
}
- (instancetype)init {
    self = [super init];
    _current  = [NSMutableArray array];
    _sessions = [NSMutableArray array];
    [self _loadSessions];
    return self;
}
- (NSArray<AdBlockCaptureEntry *> *)currentEntries  { return [_current  copy]; }
- (NSArray<AdBlockCaptureSession *> *)sessions       { return [_sessions copy]; }

- (void)startCapturing {
    [_current removeAllObjects];
    _sessionStart = [NSDate date];
    self.capturing = YES;
}
- (void)addURLString:(NSString *)url method:(NSString *)method isAd:(BOOL)ad {
    if (!self.capturing || !url.length) return;
    NSString *host = [NSURL URLWithString:url].host.lowercaseString;
    if (!host.length || [host isEqualToString:@"localhost"] || [host hasPrefix:@"127."]) return;
    AdBlockCaptureEntry *e = [AdBlockCaptureEntry new];
    e.urlString = url; e.method = method ?: @"GET";
    e.date = [NSDate date]; e.isAd = ad;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_current insertObject:e atIndex:0];
        if (self->_current.count > 500) [self->_current removeLastObject];
    });
}
- (void)stopAndSaveSession {
    self.capturing = NO;
    if (_current.count == 0) return;
    AdBlockCaptureSession *s = [AdBlockCaptureSession new];
    s.startDate = _sessionStart ?: [NSDate date];
    s.entries   = [_current copy];
    [_sessions insertObject:s atIndex:0];
    if (_sessions.count > 50) [_sessions removeLastObject];
    [_current removeAllObjects];
    [self _saveSessions];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"AdBlockSessionsUpdated" object:nil];
}
- (void)removeSessionAtIndex:(NSUInteger)idx {
    if (idx >= _sessions.count) return;
    [_sessions removeObjectAtIndex:idx];
    [self _saveSessions];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"AdBlockSessionsUpdated" object:nil];
}
- (void)clearAllSessions {
    [_sessions removeAllObjects];
    [_current  removeAllObjects];
    [self _saveSessions];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"AdBlockSessionsUpdated" object:nil];
}

/* ── 持久化 ── */
- (NSDictionary *)_entryDict:(AdBlockCaptureEntry *)e {
    return @{ @"u": e.urlString ?: @"",
              @"m": e.method    ?: @"GET",
              @"t": @(e.date.timeIntervalSince1970),
              @"a": @(e.isAd) };
}
- (AdBlockCaptureEntry *)_entryFromDict:(NSDictionary *)d {
    AdBlockCaptureEntry *e = [AdBlockCaptureEntry new];
    e.urlString = d[@"u"]; e.method = d[@"m"];
    e.date = [NSDate dateWithTimeIntervalSince1970:[d[@"t"] doubleValue]];
    e.isAd = [d[@"a"] boolValue];
    return e;
}
- (void)_saveSessions {
    NSMutableArray *arr = [NSMutableArray array];
    for (AdBlockCaptureSession *s in _sessions) {
        NSMutableArray *entries = [NSMutableArray array];
        for (AdBlockCaptureEntry *e in s.entries) [entries addObject:[self _entryDict:e]];
        [arr addObject:@{ @"start": @(s.startDate.timeIntervalSince1970), @"entries": entries }];
    }
    NSMutableDictionary *prefs = [AdBlockPrefs() mutableCopy];
    prefs[KEY_SESSIONS] = arr;
    AdBlockWritePrefs(prefs);
}
- (void)_loadSessions {
    NSArray *arr = AdBlockPrefs()[KEY_SESSIONS];
    if (!arr) return;
    for (NSDictionary *sd in arr) {
        AdBlockCaptureSession *s = [AdBlockCaptureSession new];
        s.startDate = [NSDate dateWithTimeIntervalSince1970:[sd[@"start"] doubleValue]];
        NSMutableArray *entries = [NSMutableArray array];
        for (NSDictionary *ed in sd[@"entries"]) [entries addObject:[self _entryFromDict:ed]];
        s.entries = entries;
        [_sessions addObject:s];
    }
}
@end

/* ━━━━━━━━━━━━━━━━  抓包会话列表 VC  ━━━━━━━━━━━━━━━━ */

@interface AdBlockCaptureSessionVC : UITableViewController
- (instancetype)initWithSession:(AdBlockCaptureSession *)session;
@end

@interface AdBlockCaptureVC : UITableViewController
@end

@implementation AdBlockCaptureVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"抓包历史";
    self.tableView.backgroundColor = [UIColor colorWithRed:0.05f green:0.07f blue:0.11f alpha:1];
    self.tableView.separatorStyle  = UITableViewCellSeparatorStyleNone;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"sess"];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"清空全部"
            style:UIBarButtonItemStylePlain target:self action:@selector(_clearAll)];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_reload)
                                                 name:@"AdBlockSessionsUpdated" object:nil];
    [self _reload];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)_reload  { [self.tableView reloadData]; }
- (void)_clearAll {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"清空全部历史"
        message:@"此操作不可撤销" preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(id _) {
        [[AdBlockCaptureManager shared] clearAllSessions];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)sec {
    return (NSInteger)[AdBlockCaptureManager shared].sessions.count;
}
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip { return 70; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"sess" forIndexPath:ip];
    cell.backgroundColor = UIColor.clearColor;
    cell.selectionStyle  = UITableViewCellSelectionStyleNone;
    for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];

    AdBlockCaptureSession *sess = [AdBlockCaptureManager shared].sessions[ip.row];
    CGFloat W = tv.bounds.size.width;
    const CGFloat pad = 10;

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(pad, 5, W - pad * 2, 60)];
    card.backgroundColor = [UIColor colorWithRed:0.11f green:0.14f blue:0.19f alpha:1];
    card.layer.cornerRadius = 10;
    card.clipsToBounds = YES;
    [cell.contentView addSubview:card];

    NSUInteger adCnt = [[sess.entries filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"isAd == YES"]] count];
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 4, 60)];
    bar.backgroundColor = adCnt > 0
        ? [UIColor colorWithRed:0.95f green:0.25f blue:0.25f alpha:1]
        : [UIColor colorWithRed:0.25f green:0.6f blue:1.0f alpha:1];
    [card addSubview:bar];

    static NSDateFormatter *df;
    if (!df) { df = [NSDateFormatter new]; df.dateFormat = @"yyyy-MM-dd HH:mm:ss"; }
    UILabel *dateL = [UILabel new];
    dateL.frame = CGRectMake(14, 10, W - pad * 2 - 36, 22);
    dateL.text = [df stringFromDate:sess.startDate];
    dateL.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    dateL.textColor = UIColor.whiteColor;
    [card addSubview:dateL];

    UILabel *cntL = [UILabel new];
    cntL.frame = CGRectMake(14, 34, W - pad * 2 - 36, 16);
    cntL.text = [NSString stringWithFormat:@"共 %lu 条  |  广告 %lu 条",
                 (unsigned long)sess.entries.count, (unsigned long)adCnt];
    cntL.font = [UIFont systemFontOfSize:11];
    cntL.textColor = [UIColor colorWithWhite:0.5f alpha:1];
    [card addSubview:cntL];

    UILabel *chev = [UILabel new];
    chev.frame = CGRectMake(W - pad * 2 - 22, 20, 16, 20);
    chev.text = @">";
    chev.font = [UIFont systemFontOfSize:18 weight:UIFontWeightLight];
    chev.textColor = [UIColor colorWithWhite:0.35f alpha:1];
    [card addSubview:chev];

    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    AdBlockCaptureSession *sess = [AdBlockCaptureManager shared].sessions[ip.row];
    AdBlockCaptureSessionVC *vc = [[AdBlockCaptureSessionVC alloc] initWithSession:sess];
    [self.navigationController pushViewController:vc animated:YES];
}
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)es
forRowAtIndexPath:(NSIndexPath *)ip {
    if (es == UITableViewCellEditingStyleDelete)
        [[AdBlockCaptureManager shared] removeSessionAtIndex:(NSUInteger)ip.row];
}
- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)sec {
    if ([AdBlockCaptureManager shared].sessions.count > 0) return nil;
    UIView *fv = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tv.bounds.size.width, 120)];
    fv.backgroundColor = UIColor.clearColor;
    UILabel *lbl = [UILabel new];
    lbl.frame = CGRectMake(0, 24, tv.bounds.size.width, 72);
    lbl.text = @"暂无抓包历史\n开启网络抓包开关后操作 App\n关闭开关后自动保存此次记录";
    lbl.font = [UIFont systemFontOfSize:13];
    lbl.textColor = [UIColor colorWithWhite:0.35f alpha:1];
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.numberOfLines = 3;
    [fv addSubview:lbl];
    return fv;
}
- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)sec {
    return [AdBlockCaptureManager shared].sessions.count == 0 ? 120 : 0;
}
@end

/* ━━━━━━━━━━━━━━━━  抓包会话详情 VC  ━━━━━━━━━━━━━━━━ */

@implementation AdBlockCaptureSessionVC {
    AdBlockCaptureSession          *_session;
    NSArray<AdBlockCaptureEntry *> *_data;
    UISegmentedControl         *_seg;
}

- (instancetype)initWithSession:(AdBlockCaptureSession *)session {
    self = [super initWithStyle:UITableViewStylePlain];
    _session = session;
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    static NSDateFormatter *dft;
    if (!dft) { dft = [NSDateFormatter new]; dft.dateFormat = @"MM-dd HH:mm:ss"; }
    self.title = [dft stringFromDate:_session.startDate];
    self.tableView.backgroundColor = [UIColor colorWithRed:0.05f green:0.07f blue:0.11f alpha:1];
    self.tableView.separatorStyle  = UITableViewCellSeparatorStyleNone;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"cap"];

    _seg = [[UISegmentedControl alloc] initWithItems:@[@"全部请求", @"仅广告"]];
    _seg.selectedSegmentIndex = 0;
    _seg.apportionsSegmentWidthsByContent = NO;
    if (@available(iOS 13.0, *)) {
        _seg.selectedSegmentTintColor = [UIColor colorWithRed:0.25f green:0.55f blue:1.0f alpha:1];
        [_seg setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor}
                            forState:UIControlStateSelected];
        [_seg setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.65f alpha:1]}
                            forState:UIControlStateNormal];
    }
    [_seg addTarget:self action:@selector(_reload) forControlEvents:UIControlEventValueChanged];
    UIView *hv = [[UIView alloc] initWithFrame:CGRectMake(0, 0, UIScreen.mainScreen.bounds.size.width, 58)];
    hv.backgroundColor = UIColor.clearColor;
    _seg.frame = CGRectMake(16, 12, hv.frame.size.width - 32, 34);
    _seg.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [hv addSubview:_seg];
    self.tableView.tableHeaderView = hv;

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"屏蔽广告"
            style:UIBarButtonItemStylePlain target:self action:@selector(_blockAllAds)];

    [self _reload];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *hv = self.tableView.tableHeaderView;
    if (!hv) return;
    CGFloat tw = self.tableView.bounds.size.width;
    if (ABS(hv.frame.size.width - tw) > 0.5f) {
        CGRect f = hv.frame; f.size.width = tw;
        hv.frame = f;
        self.tableView.tableHeaderView = hv;
    }
}
- (void)_reload {
    _data = (_seg.selectedSegmentIndex == 1)
        ? [_session.entries filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"isAd == YES"]]
        : _session.entries;
    [self.tableView reloadData];
}
- (void)_blockAllAds {
    NSArray *adE = [_session.entries filteredArrayUsingPredicate:
                    [NSPredicate predicateWithFormat:@"isAd == YES"]];
    if (adE.count == 0) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"无广告请求"
            message:@"本次会话未发现广告请求" preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil]; return;
    }
    NSMutableOrderedSet *hostSet = [NSMutableOrderedSet orderedSet];
    for (AdBlockCaptureEntry *e in adE) {
        NSString *h = [NSURL URLWithString:e.urlString].host.lowercaseString;
        if (h.length) [hostSet addObject:h];
    }
    NSArray *hosts = hostSet.array;
    NSString *preview = hosts.count <= 6
        ? [hosts componentsJoinedByString:@"\n"]
        : [[hosts subarrayWithRange:NSMakeRange(0,6)] componentsJoinedByString:@"\n"];
    if (hosts.count > 6) preview = [preview stringByAppendingFormat:@"\n...等 %lu 个域名", (unsigned long)hosts.count];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"屏蔽所有广告域名"
        message:[NSString stringWithFormat:@"将屏蔽 %lu 个域名：\n\n%@\n\n可在「自定义屏蔽规则」中统一释放。",
                 (unsigned long)hosts.count, preview]
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"确认屏蔽" style:UIAlertActionStyleDestructive handler:^(id _) {
        AdBlockAddBatchBlock(hosts);
        UIAlertController *ok = [UIAlertController alertControllerWithTitle:@"已屏蔽"
            message:[NSString stringWithFormat:@"%lu 个域名已批量添加到屏蔽规则", (unsigned long)hosts.count]
            preferredStyle:UIAlertControllerStyleAlert];
        [ok addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ok animated:YES completion:nil];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)sec {
    return (NSInteger)_data.count;
}
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip { return 74; }
- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)sec {
    UIView *hv = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tv.bounds.size.width, 32)];
    hv.backgroundColor = UIColor.clearColor;
    UILabel *lbl = [UILabel new];
    lbl.frame = CGRectMake(16, 6, 300, 20);
    lbl.text = [NSString stringWithFormat:@"共 %lu 条记录", (unsigned long)_data.count];
    lbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    lbl.textColor = [UIColor colorWithWhite:0.45f alpha:1];
    [hv addSubview:lbl];
    return hv;
}
- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)sec { return 32; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"cap" forIndexPath:ip];
    cell.backgroundColor = UIColor.clearColor;
    cell.selectionStyle  = UITableViewCellSelectionStyleNone;
    for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];

    AdBlockCaptureEntry *e = _data[ip.row];
    CGFloat W = tv.bounds.size.width;
    const CGFloat pad = 10;

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(pad, 4, W - pad * 2, 66)];
    card.backgroundColor = [UIColor colorWithRed:0.11f green:0.14f blue:0.19f alpha:1];
    card.layer.cornerRadius = 10; card.clipsToBounds = YES;
    [cell.contentView addSubview:card];

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 4, 66)];
    bar.backgroundColor = e.isAd
        ? [UIColor colorWithRed:0.95f green:0.25f blue:0.25f alpha:1]
        : [UIColor colorWithRed:0.25f green:0.6f blue:1.0f alpha:1];
    [card addSubview:bar];

    UILabel *meth = [UILabel new];
    meth.frame = CGRectMake(14, 12, 44, 18);
    meth.text = e.method; meth.font = [UIFont boldSystemFontOfSize:9];
    meth.textColor = UIColor.whiteColor;
    meth.backgroundColor = e.isAd
        ? [UIColor colorWithRed:0.85f green:0.15f blue:0.15f alpha:0.9f]
        : [UIColor colorWithRed:0.2f green:0.5f blue:1.0f alpha:0.9f];
    meth.layer.cornerRadius = 4; meth.clipsToBounds = YES;
    meth.textAlignment = NSTextAlignmentCenter;
    [card addSubview:meth];

    CGFloat urlRight = 14;
    if (e.isAd) {
        UILabel *badge = [UILabel new];
        badge.frame = CGRectMake(W - pad * 2 - 44, 12, 40, 18);
        badge.text = @"广告"; badge.font = [UIFont boldSystemFontOfSize:10];
        badge.textColor = UIColor.whiteColor;
        badge.backgroundColor = [UIColor colorWithRed:0.9f green:0.2f blue:0.2f alpha:1];
        badge.layer.cornerRadius = 5; badge.clipsToBounds = YES;
        badge.textAlignment = NSTextAlignmentCenter;
        [card addSubview:badge]; urlRight = 50;
    }

    UILabel *urlL = [UILabel new];
    urlL.frame = CGRectMake(64, 10, W - pad * 2 - 64 - urlRight, 20);
    urlL.text = e.urlString;
    urlL.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    urlL.textColor = UIColor.whiteColor;
    urlL.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [card addSubview:urlL];

    static NSDateFormatter *df;
    if (!df) { df = [NSDateFormatter new]; df.dateFormat = @"HH:mm:ss"; }
    UILabel *dateL = [UILabel new];
    dateL.frame = CGRectMake(14, 36, 68, 16);
    dateL.text = [df stringFromDate:e.date];
    dateL.font = [UIFont systemFontOfSize:10];
    dateL.textColor = [UIColor colorWithWhite:0.45f alpha:1];
    [card addSubview:dateL];

    UILabel *hostL = [UILabel new];
    hostL.frame = CGRectMake(86, 36, W - pad * 2 - 86 - 14, 16);
    hostL.text = [NSURL URLWithString:e.urlString].host ?: @"";
    hostL.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    hostL.textColor = [UIColor colorWithRed:0.4f green:0.75f blue:1.0f alpha:0.85f];
    [card addSubview:hostL];

    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.row >= (NSInteger)_data.count) return;
    AdBlockCaptureEntry *e = _data[ip.row];
    NSString *host = [NSURL URLWithString:e.urlString].host ?: e.urlString;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"操作"
        message:e.urlString preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"屏蔽此域名" style:UIAlertActionStyleDestructive handler:^(id _) {
        AdBlockAddCustomPattern(host);
        UIAlertController *ok = [UIAlertController alertControllerWithTitle:@"已添加"
            message:[NSString stringWithFormat:@"已屏蔽：%@", host]
            preferredStyle:UIAlertControllerStyleAlert];
        [ok addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ok animated:YES completion:nil];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"复制 URL" style:UIAlertActionStyleDefault handler:^(id _) {
        [UIPasteboard generalPasteboard].string = e.urlString;
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}
@end

/* ━━━━━━━━━━━━━━━━  自定义屏蔽规则全屏 VC  ━━━━━━━━━━━━━━━━ */

@interface AdBlockCustomRulesVC : UITableViewController
@end

@implementation AdBlockCustomRulesVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"自定义屏蔽规则";
    self.tableView.backgroundColor = [UIColor colorWithRed:0.05f green:0.07f blue:0.11f alpha:1];
    self.tableView.separatorStyle  = UITableViewCellSeparatorStyleNone;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"rule"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"batch"];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self action:@selector(_addRule)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭"
            style:UIBarButtonItemStylePlain target:self action:@selector(_close)];
}
- (void)_close { [[AdBlockPanelManager shared] closeModalWindow]; }
- (void)_addRule {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"添加屏蔽规则"
        message:@"输入域名或 URL 关键字，匹配后将被拦截" preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"例：ad.example.com 或 /api/ad/";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(id _) {
        NSString *txt = [ac.textFields.firstObject.text stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (txt.length) { AdBlockAddCustomPattern(txt); [self.tableView reloadData]; }
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}
- (void)_releaseBatchAtIndex:(NSUInteger)idx {
    NSDictionary *batch = AdBlockBatchBlocks()[idx];
    NSArray *hosts = batch[@"hosts"];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"释放此批次屏蔽"
        message:[NSString stringWithFormat:@"将从屏蔽规则中移除 %lu 个域名:\n%@",
                 (unsigned long)hosts.count,
                 hosts.count <= 5
                     ? [hosts componentsJoinedByString:@"\n"]
                     : [[hosts subarrayWithRange:NSMakeRange(0,5)] componentsJoinedByString:@"\n"]]
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"释放" style:UIAlertActionStyleDestructive handler:^(id _) {
        AdBlockRemoveBatchBlockAtIndex(idx);
        [self.tableView reloadData];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

/* ─── 表格 ─── */
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? (NSInteger)AdBlockBatchBlocks().count : (NSInteger)AdBlockCustomPatterns().count;
}
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == 0 ? 68 : 60;
}
- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    UIView *hv = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tv.bounds.size.width, 36)];
    hv.backgroundColor = UIColor.clearColor;
    UILabel *lbl = [UILabel new];
    lbl.frame = CGRectMake(16, 8, tv.bounds.size.width - 32, 20);
    lbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    lbl.textColor = [UIColor colorWithWhite:0.5f alpha:1];
    lbl.text = s == 0
        ? @"[B]  批量屏蔽规则（左滑可整批释放）"
        : @"[R]  单条屏蔽规则（左滑删除）";
    [hv addSubview:lbl];
    return hv;
}
- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    if (s == 0 && AdBlockBatchBlocks().count == 0) return 0;
    if (s == 1 && AdBlockCustomPatterns().count == 0 && AdBlockBatchBlocks().count == 0) return 0;
    return 36;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    CGFloat W = tv.bounds.size.width;
    const CGFloat pad = 10;
    if (ip.section == 0) {
        /* 批量屏蔽行 */
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"batch" forIndexPath:ip];
        cell.backgroundColor = UIColor.clearColor;
        cell.selectionStyle  = UITableViewCellSelectionStyleNone;
        for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];
        NSDictionary *batch = AdBlockBatchBlocks()[ip.row];
        NSArray *hosts = batch[@"hosts"];
        NSString *label = batch[@"label"] ?: @"批量屏蔽";
        UIView *card = [[UIView alloc] initWithFrame:CGRectMake(pad, 4, W - pad * 2, 60)];
        card.backgroundColor = [UIColor colorWithRed:0.13f green:0.10f blue:0.18f alpha:1];
        card.layer.cornerRadius = 10; card.clipsToBounds = YES;
        [cell.contentView addSubview:card];
        UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 4, 60)];
        bar.backgroundColor = [UIColor colorWithRed:0.8f green:0.3f blue:0.9f alpha:1];
        [card addSubview:bar];
        UILabel *titleL = [UILabel new];
        titleL.frame = CGRectMake(14, 8, W - pad * 2 - 28, 20);
        titleL.text = [NSString stringWithFormat:@"批次：%@", label];
        titleL.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        titleL.textColor = [UIColor colorWithWhite:0.9f alpha:1];
        [card addSubview:titleL];
        UILabel *hostsL = [UILabel new];
        hostsL.frame = CGRectMake(14, 30, W - pad * 2 - 28, 20);
        hostsL.text = [NSString stringWithFormat:@"共 %lu 个域名：%@",
                       (unsigned long)hosts.count, [hosts componentsJoinedByString:@"  "]];
        hostsL.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
        hostsL.textColor = [UIColor colorWithWhite:0.55f alpha:1];
        hostsL.lineBreakMode = NSLineBreakByTruncatingTail;
        [card addSubview:hostsL];
        return cell;
    }
    /* 单条规则行 */
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"rule" forIndexPath:ip];
    cell.backgroundColor = UIColor.clearColor;
    cell.selectionStyle  = UITableViewCellSelectionStyleNone;
    for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];
    NSString *pattern = AdBlockCustomPatterns()[ip.row];
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(pad, 5, W - pad * 2, 50)];
    card.backgroundColor = [UIColor colorWithRed:0.11f green:0.14f blue:0.19f alpha:1];
    card.layer.cornerRadius = 10; card.clipsToBounds = YES;
    [cell.contentView addSubview:card];
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 4, 50)];
    bar.backgroundColor = [UIColor colorWithRed:0.95f green:0.3f blue:0.2f alpha:1];
    [card addSubview:bar];
    UILabel *iconL = [UILabel new];
    iconL.frame = CGRectMake(14, 13, 20, 24);
    iconL.text = @"X"; iconL.font = [UIFont boldSystemFontOfSize:13];
    iconL.textColor = [UIColor colorWithRed:0.95f green:0.3f blue:0.2f alpha:1];
    [card addSubview:iconL];
    UILabel *lbl = [UILabel new];
    lbl.frame = CGRectMake(40, 15, W - pad * 2 - 50, 20);
    lbl.text = pattern;
    lbl.font = [UIFont fontWithName:@"Menlo" size:13] ?: [UIFont systemFontOfSize:13];
    lbl.textColor = UIColor.whiteColor;
    lbl.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [card addSubview:lbl];
    return cell;
}
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)es
forRowAtIndexPath:(NSIndexPath *)ip {
    if (es != UITableViewCellEditingStyleDelete) return;
    if (ip.section == 0) {
        [self _releaseBatchAtIndex:(NSUInteger)ip.row];
    } else {
        AdBlockRemoveCustomPatternAtIndex((NSUInteger)ip.row);
        [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationFade];
    }
}
- (NSString *)tableView:(UITableView *)tv titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == 0 ? @"释放" : @"删除";
}
- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    if (s == 0) return nil;
    if (AdBlockCustomPatterns().count > 0 || AdBlockBatchBlocks().count > 0) return nil;
    UIView *fv = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tv.bounds.size.width, 100)];
    fv.backgroundColor = UIColor.clearColor;
    UILabel *lbl = [UILabel new];
    lbl.frame = CGRectMake(0, 24, tv.bounds.size.width, 52);
    lbl.text = @"暂无屏蔽规则\n点击右上角 + 添加域名或 URL 关键字";
    lbl.font = [UIFont systemFontOfSize:13];
    lbl.textColor = [UIColor colorWithWhite:0.35f alpha:1];
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.numberOfLines = 2;
    [fv addSubview:lbl];
    return fv;
}
- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s {
    if (s == 0) return 0;
    return (AdBlockCustomPatterns().count == 0 && AdBlockBatchBlocks().count == 0) ? 100 : 0;
}
@end

/* ━━━━━━━━━━━━━━━━  面板管理器  ━━━━━━━━━━━━━━━━ */

@implementation AdBlockPanelManager {
    AdBlockOverlayWindow   *_win;
    UIVisualEffectView *_card;
    UIWindow           *_modalWin;
    UIWindow           *_captureIndicatorWin;
}

+ (instancetype)shared {
    static AdBlockPanelManager *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [AdBlockPanelManager new]; });
    return s;
}

- (void)showFromGesture:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (_win) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [self _buildPanel]; });
}

- (void)dismiss {
    [UIView animateWithDuration:0.22 animations:^{
        self->_card.alpha = 0;
        self->_card.transform = CGAffineTransformMakeScale(0.82, 0.82);
    } completion:^(BOOL _) {
        self->_win.hidden = YES;
        self->_win = nil; self->_card = nil;
    }];
}

/* 全屏 VC 弹出（使用独立 UIWindow，完全遮盖底层 App） */
- (void)openFullScreenVC:(UIViewController *)vc title:(NSString *)title {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.barStyle  = UIBarStyleBlack;
    nav.navigationBar.tintColor = [UIColor colorWithRed:0.3f green:0.7f blue:1.0f alpha:1];
    nav.navigationBar.titleTextAttributes = @{NSForegroundColorAttributeName: UIColor.whiteColor};
    nav.navigationBar.barTintColor = [UIColor colorWithWhite:0.1f alpha:1];

    /* 在 vc 上注入"关闭"按钮（如果 vc 没有自己设置的话） */
    if (!vc.navigationItem.leftBarButtonItem) {
        vc.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"关闭"
                style:UIBarButtonItemStylePlain target:self action:@selector(closeModalWindow)];
    }

    _modalWin = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    _modalWin.windowLevel     = UIWindowLevelAlert + 400;
    _modalWin.rootViewController = nav;
    _modalWin.hidden          = NO;
    _modalWin.backgroundColor = UIColor.blackColor;
}

/* ── 构建面板 ── */
- (void)_buildPanel {
    CGRect sc  = UIScreen.mainScreen.bounds;
    const CGFloat W  = MIN(sc.size.width - 48.0f, 320.0f);
    const CGFloat H  = 490.0f;
    const CGFloat CX = (sc.size.width  - W) / 2.0f;
    const CGFloat CY = (sc.size.height - H) / 2.0f;

    _win = [[AdBlockOverlayWindow alloc] initWithFrame:sc];
    _win.windowLevel = UIWindowLevelAlert + 200;
    _win.backgroundColor = UIColor.clearColor;
    _win.rootViewController = [UIViewController new];
    _win.hidden = NO;

    UIBlurEffect *fx = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    _card = [[UIVisualEffectView alloc] initWithEffect:fx];
    _card.frame = CGRectMake(CX, CY, W, H);
    _card.layer.cornerRadius = 22;
    _card.clipsToBounds = YES;
    _card.alpha = 0;
    _card.transform = CGAffineTransformMakeScale(0.72f, 0.72f);
    [_win addSubview:_card];

    UIView *cv = _card.contentView;

    /* ── 礼花筒 ── */
    [self _fireConfetti:cv W:W H:H];

    /* ── 关闭按钮（圆形带X，大红色）── */
    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake(W - 46, 8, 36, 36);
    close.backgroundColor = [UIColor colorWithRed:0.85f green:0.12f blue:0.12f alpha:1.0f];
    close.layer.cornerRadius = 18;
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    [close addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [cv addSubview:close];

    /* ── 标题 ── */
    UILabel *ttl = [UILabel new];
    ttl.frame = CGRectMake(16, 14, W - 32, 34);
    ttl.text = @"恭喜你找到了彩蛋！";
    ttl.textColor = UIColor.whiteColor;
    ttl.font = [UIFont boldSystemFontOfSize:19];
    ttl.textAlignment = NSTextAlignmentCenter;
    [cv addSubview:ttl];

    UILabel *sub = [UILabel new];
    sub.frame = CGRectMake(16, 50, W - 32, 18);
    sub.text  = @"🛡️  基本拥有去广告能力的插件 · by JiJiang778";
    sub.textColor = [UIColor colorWithWhite:0.52f alpha:1];
    sub.font  = [UIFont systemFontOfSize:11];
    sub.textAlignment = NSTextAlignmentCenter;
    [cv addSubview:sub];

    [self _sep:cv y:74 W:W];

    /* ── 读取偏好 ── */
    NSDictionary *p = AdBlockPrefs();
    id adVal = p[KEY_AD_BLOCK], iapVal = p[KEY_IAP];
    BOOL adOn  = adVal  ? [adVal  boolValue] : YES;
    BOOL iapOn = iapVal ? [iapVal boolValue] : NO;

    /* ── Toggle 行 ── */
    [self _row:cv y:82 W:W title:@"拦截广告请求" detail:@"屏蔽广告 SDK，实时生效"
           key:KEY_AD_BLOCK on:adOn restart:NO];
    [self _sep:cv y:162 W:W];
    [self _row:cv y:170 W:W title:@"内购免费解锁" detail:@"模拟 StoreKit 购买成功（重启生效）"
           key:KEY_IAP on:iapOn restart:YES];
    [self _sep:cv y:250 W:W];

    /* ── Toggle 行：网络抓包 ── */
    [self _captureRow:cv y:258 W:W];
    [self _sep:cv y:338 W:W];

    /* ── 导航行：抓包历史 ── */
    [self _navRow:cv y:346 W:W icon:@"📋" title:@"抓包历史"
           detail:@"查看已捕获请求，一键屏蔽/导出" action:@selector(_openCaptureHistory)];
    [self _sep:cv y:400 W:W];

    /* ── 导航行：自定义屏蔽 ── */
    [self _navRow:cv y:408 W:W icon:@"⛔" title:@"自定义屏蔽规则"
           detail:@"手动添加域名/URL 关键字" action:@selector(_openCustomRules)];
    [self _sep:cv y:462 W:W];

    /* ── 版本 ── */
    UILabel *ver = [UILabel new];
    ver.frame = CGRectMake(0, 470, W, 22);
    ver.text  = @"v1.0.1  ·  尝试通杀所有影视 App的插件";
    ver.textColor = [UIColor colorWithRed:0.65f green:0.18f blue:0.18f alpha:1];
    ver.font  = [UIFont systemFontOfSize:11];
    ver.textAlignment = NSTextAlignmentCenter;
    [cv addSubview:ver];

    /* ── 弹出动画 ── */
    [UIView animateWithDuration:0.40 delay:0
         usingSpringWithDamping:0.65f initialSpringVelocity:0.4f
                        options:0 animations:^{
        self->_card.alpha = 1;
        self->_card.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)_openCaptureHistory {
    [self openFullScreenVC:[AdBlockCaptureVC new] title:@"抓包历史"];
}
- (void)_openCustomRules {
    [self openFullScreenVC:[AdBlockCustomRulesVC new] title:@"自定义屏蔽规则"];
}

/* ━━━━━━━━━  礼花筒发射  ━━━━━━━━━ */
- (void)_fireConfetti:(UIView *)parent W:(CGFloat)W H:(CGFloat)H {
    CAEmitterLayer *emit = [CAEmitterLayer layer];
    emit.frame = CGRectMake(0, 0, W, H);
    emit.emitterPosition = CGPointMake(W / 2.0f, H * 0.72f);
    emit.emitterShape    = kCAEmitterLayerPoint;
    emit.emitterSize     = CGSizeMake(2, 2);

    NSArray<UIColor *> *cols = @[
        UIColor.systemRedColor, UIColor.systemBlueColor,
        UIColor.systemGreenColor, UIColor.systemYellowColor,
        UIColor.systemPinkColor, UIColor.systemOrangeColor,
        UIColor.cyanColor, UIColor.systemPurpleColor,
    ];
    NSMutableArray *cells = [NSMutableArray array];
    for (UIColor *c in cols) {
        CAEmitterCell *cell = [CAEmitterCell new];
        cell.birthRate = 6; cell.lifetime = 2.2f;
        cell.velocity = 320; cell.velocityRange = 120;
        cell.emissionLongitude = -(CGFloat)M_PI_2;
        cell.emissionRange     = (CGFloat)(M_PI / 1.8);
        cell.spin = 5; cell.spinRange = 8;
        cell.scale = 0.9f; cell.scaleRange = 0.5f;
        cell.yAcceleration = 550; cell.xAcceleration = 15;
        cell.contents = (id)AdBlockPaperRect(c).CGImage;
        [cells addObject:cell];
    }
    emit.emitterCells = cells;
    [parent.layer insertSublayer:emit atIndex:0];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ emit.birthRate = 0; });
}

/* ━━━━━━━━━  辅助：分割线  ━━━━━━━━━ */
- (void)_sep:(UIView *)parent y:(CGFloat)y W:(CGFloat)W {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(16, y, W - 32, 0.5f)];
    v.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12f];
    [parent addSubview:v];
}

/* ━━━━━━━━━  辅助：导航行（图标 + 标题 + 描述 + 箭头）  ━━━━━━━━━ */
- (void)_navRow:(UIView *)parent y:(CGFloat)y W:(CGFloat)W
           icon:(NSString *)icon title:(NSString *)title
         detail:(NSString *)detail action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(0, y, W, 54);
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [parent addSubview:btn];

    UILabel *iconL = [UILabel new];
    iconL.frame = CGRectMake(16, 15, 26, 26);
    iconL.text = icon; iconL.font = [UIFont systemFontOfSize:20];
    iconL.userInteractionEnabled = NO;
    [btn addSubview:iconL];

    UILabel *tl = [UILabel new];
    tl.frame = CGRectMake(50, 10, W - 78, 20);
    tl.text = title;
    tl.textColor = UIColor.whiteColor;
    tl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    tl.userInteractionEnabled = NO;
    [btn addSubview:tl];

    UILabel *dl = [UILabel new];
    dl.frame = CGRectMake(50, 30, W - 78, 14);
    dl.text = detail;
    dl.textColor = [UIColor colorWithWhite:0.52f alpha:1];
    dl.font = [UIFont systemFontOfSize:11];
    dl.userInteractionEnabled = NO;
    [btn addSubview:dl];

    UILabel *chev = [UILabel new];
    chev.frame = CGRectMake(W - 22, 18, 14, 18);
    chev.text = @"›";
    chev.textColor = [UIColor colorWithWhite:0.45f alpha:1];
    chev.font = [UIFont systemFontOfSize:20 weight:UIFontWeightLight];
    chev.userInteractionEnabled = NO;
    [btn addSubview:chev];
}

/* 公开的关闭模态窗口方法 */
- (void)closeModalWindow {
    [UIView animateWithDuration:0.22 animations:^{ self->_modalWin.alpha = 0; }
                     completion:^(BOOL _) { self->_modalWin.hidden = YES; self->_modalWin = nil; }];
}

/* ━━━━━━━━━  辅助：功能行（标题 + 描述 + 开关）  ━━━━━━━━━ */
- (void)_row:(UIView *)parent y:(CGFloat)y W:(CGFloat)W
       title:(NSString *)title detail:(NSString *)detail
         key:(NSString *)key on:(BOOL)on restart:(BOOL)restart {

    UILabel *tl = [UILabel new];
    tl.frame = CGRectMake(18, y + 8, W - 104, 22);
    tl.text = title;
    tl.textColor = UIColor.whiteColor;
    tl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [parent addSubview:tl];

    UILabel *dl = [UILabel new];
    dl.frame = CGRectMake(18, y + 32, W - 104, 16);
    dl.text = detail;
    dl.textColor = [UIColor colorWithWhite:0.52f alpha:1];
    dl.font = [UIFont systemFontOfSize:11];
    [parent addSubview:dl];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.frame = CGRectMake(W - 76, y + 18, 51, 31);
    sw.on = on;
    /* 借用 accessibilityLabel/Hint 携带元数据 */
    sw.accessibilityLabel = key;
    sw.accessibilityHint  = restart ? @"1" : @"0";
    [sw addTarget:self action:@selector(_onToggle:) forControlEvents:UIControlEventValueChanged];
    [parent addSubview:sw];
}

/* ━━━━━━━━━  开关切换回调  ━━━━━━━━━ */
- (void)_onToggle:(UISwitch *)sw {
    if (sw.tag == 99) {
        if (sw.isOn) {
            [[AdBlockCaptureManager shared] startCapturing];
            [self _showCaptureIndicator];
            [self _toast:@"📡 抓包已开启，点击顶部红色按钮可停止"];
        } else {
            [[AdBlockCaptureManager shared] stopAndSaveSession];
            [self _hideCaptureIndicator];
            [self _toast:@"📁 抓包已停止并保存，进入「抓包历史」查看"];
        }
        return;
    }
    AdBlockSavePref(sw.accessibilityLabel, sw.isOn);
    BOOL needRestart = [sw.accessibilityHint isEqualToString:@"1"];
    NSString *msg;
    if (needRestart) {
        msg = sw.isOn ? @"✅ 已开启，重启 App 后生效" : @"❌ 已关闭，重启 App 后生效";
    } else {
        msg = sw.isOn ? @"✅ 已开启，立即生效，无需重启" : @"❌ 已关闭，立即生效，无需重启";
    }
    [self _toast:msg];
}

/* ━━━━━━━━━  抓包 Toggle 行  ━━━━━━━━━ */
- (void)_captureRow:(UIView *)parent y:(CGFloat)y W:(CGFloat)W {
    UILabel *tl = [UILabel new];
    tl.frame = CGRectMake(18, y + 8, W - 104, 22);
    tl.text = @"网络抓包";
    tl.textColor = UIColor.whiteColor;
    tl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [parent addSubview:tl];

    UILabel *dl = [UILabel new];
    dl.frame = CGRectMake(18, y + 32, W - 104, 16);
    dl.text = @"开启后实时记录请求，关闭后进入历史查看";
    dl.textColor = [UIColor colorWithWhite:0.52f alpha:1];
    dl.font = [UIFont systemFontOfSize:11];
    [parent addSubview:dl];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.frame = CGRectMake(W - 76, y + 18, 51, 31);
    sw.on = [AdBlockCaptureManager shared].capturing;
    sw.tag = 99;
    [sw addTarget:self action:@selector(_onToggle:) forControlEvents:UIControlEventValueChanged];
    [parent addSubview:sw];
}

/* ━━━━━━━━━  抓包悬浮指示器  ━━━━━━━━━ */
- (void)_showCaptureIndicator {
    if (_captureIndicatorWin) return;
    CGRect sc = UIScreen.mainScreen.bounds;
    _captureIndicatorWin = [[AdBlockOverlayWindow alloc] initWithFrame:sc];
    _captureIndicatorWin.windowLevel = UIWindowLevelAlert + 600;
    _captureIndicatorWin.backgroundColor = UIColor.clearColor;
    _captureIndicatorWin.rootViewController = [UIViewController new];
    _captureIndicatorWin.hidden = NO;

    const CGFloat bw = 190, bh = 34;
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake((sc.size.width - bw) / 2.0f, 54, bw, bh);
    btn.backgroundColor = [UIColor colorWithRed:0.85f green:0.08f blue:0.08f alpha:0.93f];
    btn.layer.cornerRadius = bh / 2.0f;
    btn.clipsToBounds = YES;
    [btn setTitle:@"🔴 抓包中 · 点击停止" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [btn addTarget:self action:@selector(_stopCaptureFromIndicator)
          forControlEvents:UIControlEventTouchUpInside];
    [_captureIndicatorWin.rootViewController.view addSubview:btn];
}
- (void)_hideCaptureIndicator {
    _captureIndicatorWin.hidden = YES;
    _captureIndicatorWin = nil;
}
- (void)_stopCaptureFromIndicator {
    [[AdBlockCaptureManager shared] stopAndSaveSession];
    [self _hideCaptureIndicator];
}

/* ━━━━━━━━━  Toast 提示  ━━━━━━━━━ */
- (void)_toast:(NSString *)msg {
    if (!_card) return;
    UIView *cv = _card.contentView;
    CGFloat W  = _card.bounds.size.width;
    CGFloat H  = _card.bounds.size.height;

    UILabel *t = [UILabel new];
    t.text = msg;
    t.textColor = UIColor.whiteColor;
    t.backgroundColor = [UIColor colorWithRed:0.08f green:0.08f blue:0.12f alpha:0.94f];
    t.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    t.textAlignment = NSTextAlignmentCenter;
    t.layer.cornerRadius = 15;
    t.clipsToBounds = YES;
    [t sizeToFit];
    CGFloat tw = t.frame.size.width + 34, th = 32;
    t.frame = CGRectMake((W - tw) / 2.0f, H - th - 10, tw, th);
    t.alpha = 0;
    [cv addSubview:t];

    [UIView animateWithDuration:0.18 animations:^{ t.alpha = 1; } completion:^(BOOL _) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.18 animations:^{ t.alpha = 0; }
                             completion:^(BOOL __) { [t removeFromSuperview]; }];
        });
    }];
}

@end
