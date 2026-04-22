#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <StoreKit/StoreKit.h>
#import "AdBlockPanel.h"

/* ━━━━━━━━━━━━━━━━━━━━━━━━  偏好读取  ━━━━━━━━━━━━━━━━━━━━━━━━ */

#define ADBLOCK_SUITE    @"com.jijiang778.dsxnoads"
#define KEY_AD_BLOCK @"adBlockEnabled"
#define KEY_IAP      @"iapUnlockEnabled"

static BOOL prefBool(NSString *key, BOOL def) {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults]
                       persistentDomainForName:ADBLOCK_SUITE];
    id v = d[key];
    return v ? [v boolValue] : def;
}
static BOOL adBlockOn(void)   { return prefBool(KEY_AD_BLOCK, YES); }
static BOOL iapUnlockOn(void) { return prefBool(KEY_IAP,      NO);  }

/* ━━━━━━━━━━━━━━━━━━━━━━━━  广告域名表  ━━━━━━━━━━━━━━━━━━━━━━━ */

static NSSet<NSString *>   *gAdHosts;
static NSArray<NSString *> *gAdSuffixes;
static NSSet<NSString *>   *gAdSubdomains;   /* 广告子域名首标签 e.g. ad.xxx.com */
static NSArray<NSString *> *gAdDomainKws;    /* 域名内关键字 */
static NSArray<NSString *> *gAdPathKws;      /* URL 路径/参数关键字 */
/* 开屏/插屏广告 VC 类名关键字（含主流 SDK） */
static NSArray<NSString *> *gAdVCPatterns;

static BOOL isAdHost(NSString *host) {
    if (!host || host.length == 0) return NO;
    host = host.lowercaseString;
    /* 1. 精确主机名 */
    if ([gAdHosts containsObject:host]) return YES;
    /* 2. 域名后缀 */
    for (NSString *sfx in gAdSuffixes)
        if ([host hasSuffix:sfx]) return YES;
    /* 3. 广告子域名启发：ad.xxx.com / ads.xxx.com / adlog.xxx.com ... */
    NSArray *labels = [host componentsSeparatedByString:@"."];
    if (labels.count >= 3 && [gAdSubdomains containsObject:labels[0]]) return YES;
    /* 4. 域名内关键字启发 */
    for (NSString *kw in gAdDomainKws)
        if ([host containsString:kw]) return YES;
    return NO;
}
static BOOL isAdPath(NSString *path) {
    if (!path.length) return NO;
    NSString *lp = path.lowercaseString;
    for (NSString *kw in gAdPathKws)
        if ([lp containsString:kw]) return YES;
    return NO;
}

/* ━━━━━━━━━━━━━━━━━━━━━━━━  拦截协议  ━━━━━━━━━━━━━━━━━━━━━━━━ */

static NSString *const kMarker = @"AdBlockMarker";

@interface AdBlockProtocol : NSURLProtocol
@end

@implementation AdBlockProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)req {
    if (!adBlockOn()) return NO;
    if ([NSURLProtocol propertyForKey:kMarker inRequest:req]) return NO;
    NSString *urlStr = req.URL.absoluteString;
    return isAdHost(req.URL.host) || isAdPath(req.URL.path) || AdBlockIsCustomBlocked(urlStr);
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)req { return req; }
+ (BOOL)requestIsCacheEquivalent:(NSURLRequest *)a toRequest:(NSURLRequest *)b { return NO; }

- (void)startLoading {
    NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc]
        initWithURL:self.request.URL statusCode:200
        HTTPVersion:@"HTTP/1.1"
        headerFields:@{@"Content-Type": @"application/json; charset=utf-8",
                       @"Content-Length": @"2"}];
    [self.client URLProtocol:self didReceiveResponse:resp
          cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[@"{}" dataUsingEncoding:NSUTF8StringEncoding]];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}

@end

/* ━━━━━━━━━━━━━━━━━━━━━━━━  Hook: NSURLSession 抓包  ━━━━━━━━━━━━ */

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)req {
    NSString *u = req.URL.absoluteString;
    BOOL ad = isAdHost(req.URL.host) || isAdPath(req.URL.path) || AdBlockIsCustomBlocked(u);
    [[AdBlockCaptureManager shared] addURLString:u method:req.HTTPMethod ?: @"GET" isAd:ad];
    return %orig;
}
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)req
                            completionHandler:(void(^)(NSData *, NSURLResponse *, NSError *))h {
    NSString *u = req.URL.absoluteString;
    BOOL ad = isAdHost(req.URL.host) || isAdPath(req.URL.path) || AdBlockIsCustomBlocked(u);
    [[AdBlockCaptureManager shared] addURLString:u method:req.HTTPMethod ?: @"GET" isAd:ad];
    return %orig;
}
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url {
    BOOL ad = isAdHost(url.host) || isAdPath(url.path) || AdBlockIsCustomBlocked(url.absoluteString);
    [[AdBlockCaptureManager shared] addURLString:url.absoluteString method:@"GET" isAd:ad];
    return %orig;
}
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url
                        completionHandler:(void(^)(NSData *, NSURLResponse *, NSError *))h {
    BOOL ad = isAdHost(url.host) || isAdPath(url.path) || AdBlockIsCustomBlocked(url.absoluteString);
    [[AdBlockCaptureManager shared] addURLString:url.absoluteString method:@"GET" isAd:ad];
    return %orig;
}
%end

%hook NSURLSessionConfiguration
- (NSArray *)protocolClasses {
    if (!adBlockOn()) return %orig;
    NSMutableArray *list = [NSMutableArray arrayWithObject:[AdBlockProtocol class]];
    NSArray *orig = %orig;
    if (orig) [list addObjectsFromArray:orig];
    return [list copy];
}
%end

/* ━━━━━━━━━━━━━━━━━━━━━━━━  Hook: 双指长按手势  ━━━━━━━━━━━━━━━━ */

%hook UIWindow
- (void)becomeKeyWindow {
    %orig;
    /* 跳过我们自己的悬浮窗 */
    if ([self isKindOfClass:[AdBlockOverlayWindow class]]) return;
    /* 每个 window 仅添加一次 */
    for (UIGestureRecognizer *g in self.gestureRecognizers) {
        if ([g isKindOfClass:[UILongPressGestureRecognizer class]] &&
            ((UILongPressGestureRecognizer *)g).numberOfTouchesRequired == 2) return;
    }
    UILongPressGestureRecognizer *gr =
        [[UILongPressGestureRecognizer alloc]
         initWithTarget:[AdBlockPanelManager shared]
                 action:@selector(showFromGesture:)];
    gr.minimumPressDuration    = 3.0;
    gr.numberOfTouchesRequired = 2;
    [self addGestureRecognizer:gr];
}
%end

/* ━━━━━━━━━━━━━━━━━━━━━━━━  Hook: 摇一摇广告拦截  ━━━━━━━━━━━━━━ */

%hook UIApplication
- (void)motionBegan:(UIEventSubtype)m withEvent:(UIEvent *)e {
    if (adBlockOn() && m == UIEventSubtypeMotionShake) return;
    %orig;
}
- (void)motionEnded:(UIEventSubtype)m withEvent:(UIEvent *)e {
    if (adBlockOn() && m == UIEventSubtypeMotionShake) return;
    %orig;
}
%end

%hook UIResponder
- (void)motionBegan:(UIEventSubtype)m withEvent:(UIEvent *)e {
    if (adBlockOn() && m == UIEventSubtypeMotionShake) return;
    %orig;
}
- (void)motionEnded:(UIEventSubtype)m withEvent:(UIEvent *)e {
    if (adBlockOn() && m == UIEventSubtypeMotionShake) return;
    %orig;
}
%end

/* ━━━━━━━━━━━━━━━━━━━━━━━━  Hook: 开屏/插屏广告 VC  ━━━━━━━━━━━━ */

%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!adBlockOn()) return;
    NSString *cls = NSStringFromClass(self.class);
    for (NSString *pat in gAdVCPatterns) {
        if ([cls containsString:pat]) {
            /* 有父控制器则 dismiss，否则尝试从导航栈弹出 */
            if (self.presentingViewController) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.presentingViewController
                     dismissViewControllerAnimated:NO completion:nil];
                });
            } else if (self.navigationController &&
                       self.navigationController.topViewController == self) {
                [self.navigationController popViewControllerAnimated:NO];
            }
            break;
        }
    }
}
%end

/* ━━━━━━━━━━━━━━━━━━━━━━━━  Hook: 广告 View 隐藏  ━━━━━━━━━━━━━━ */

%hook UIView
- (void)didMoveToWindow {
    %orig;
    if (!adBlockOn() || !self.window) return;
    NSString *cls = NSStringFromClass(self.class);
    if (cls.length < 6) return;
    /* 快速跳过系统类（绝大多数都以 UI/NS/CA/_/ 开头） */
    unichar c0 = [cls characterAtIndex:0];
    unichar c1 = [cls characterAtIndex:1];
    if ((c0=='U'&&c1=='I') || (c0=='N'&&c1=='S') ||
        (c0=='C'&&c1=='A') || c0=='_') return;
    /* 针对广告 SDK View 类名关键字直接隐藏 */
    if ([cls containsString:@"SplashAd"]        ||
        [cls containsString:@"PauseAd"]         ||
        [cls containsString:@"FullScreenAd"]    ||
        [cls containsString:@"InterstitialAd"]  ||
        [cls containsString:@"GDTNativeAd"]     ||
        [cls containsString:@"SMAdBanner"]      ||
        [cls containsString:@"BUNativeAd"]      ||
        [cls containsString:@"OpenAdView"]      ||
        [cls containsString:@"AdOverlayView"]   ||
        [cls containsString:@"MBSplash"]        ||
        [cls containsString:@"ATAdView"]) {
        self.hidden = YES;
    }
}
%end

/* ━━━━━━━━━━━━━━━━━━━━━━━━  Hook: IAP 内购解锁  ━━━━━━━━━━━━━━━━ */

%hook SKPaymentQueue
+ (BOOL)canMakePayments { return iapUnlockOn() ? YES : %orig; }
%end

%hook SKPaymentTransaction
- (SKPaymentTransactionState)transactionState {
    if (!iapUnlockOn()) return %orig;
    SKPaymentTransactionState s = %orig;
    if (s == SKPaymentTransactionStateFailed ||
        s == SKPaymentTransactionStatePurchasing)
        return SKPaymentTransactionStatePurchased;
    return s;
}
- (NSDate *)transactionDate {
    return (iapUnlockOn() && !%orig) ? [NSDate date] : %orig;
}
- (NSString *)transactionIdentifier {
    return (iapUnlockOn() && !%orig) ? [NSUUID UUID].UUIDString : %orig;
}
%end

%hook SKReceiptRefreshRequest
- (void)start {
    if (iapUnlockOn()) {
        if ([self.delegate respondsToSelector:@selector(requestDidFinish:)])
            [self.delegate requestDidFinish:self];
        return;
    }
    %orig;
}
%end

/* ━━━━━━━━━━━━━━━━━━━━━━━━  构造函数  ━━━━━━━━━━━━━━━━━━━━━━━━━ */

%ctor {
    @autoreleasepool {

        /* ── 精确主机名 ── */
        gAdHosts = [NSSet setWithArray:@[
            /* Sigmob */
            @"tm.sigmob.cn", @"dc.sigmob.cn",
            @"adservice.sigmob.cn", @"rtbcallback.sigmob.cn",

            /* 腾讯广点通 GDT */
            @"win.gdt.qq.com", @"v3.gdt.qq.com",
            @"v2mi.gdt.qq.com", @"mi.gdt.qq.com",
            @"sdk.e.qq.com", @"sdkquic.e.qq.com",
            @"pgdt.ugdtimg.com",

            /* 快手联盟 */
            @"open.e.kuaishou.com",
            @"p1-lm.adukwai.com", @"p2-lm.adukwai.com",

            /* 1RTB */
            @"sdk.1rtb.net", @"ssp.1rtb.com",

            /* 贝字 */
            @"api-htp.beizi.biz", @"sdk.beizi.biz",

            /* Medproad */
            @"tr.medproad.com",

            /* Hubcloud 广告端 */
            @"v.adx.hubcloud.com.cn",
            @"api.htp.hubcloud.com.cn",
            @"res1.hubcloud.com.cn",

            /* 黄河 DSP */
            @"api.yellow-river.cn",

            /* ADN Plus */
            @"dsp-tracer.adn-plus.com.cn",

            /* 美团 DSP */
            @"impdsp.meituan.com", @"s3plus.meituan.net",

            /* 掌阅移动 */
            @"sdk.zhangyuyidong.cn", @"sdklog.zhangyuyidong.cn",

            /* AppAd */
            @"res.appad.top",

            /* Ad-Scope */
            @"resource.ad-scope.com.cn",

            /* 广告配置 CDN */
            @"log-alibaba-taobao-douyin.cdn.bcebos.com",

            /* Pangle / 穿山甲 (字节跳动) */
            @"pangolin.snssdk.com", @"ad.oceanengine.com",
            @"mlog.snssdk.com",     @"e.csjplatform.com",
            @"pangle.io",           @"ad.pangle.io",

            /* TopOn / AnyThink */
            @"sdk.anythinktech.com", @"api.anythink.cn",
            @"distributor.anythinktech.com",

            /* Mintegral / Mobvista */
            @"sdk.mobvista.com",  @"sdk.mintegral.com",
            @"cdn-adn.rayjump.com",

            /* Vungle */
            @"ads.vungle.com", @"api.vungle.com",

            /* 百度广告 */
            @"ad.api.mw.baidu.com",

            /* 优量汇（腾讯广告联盟）- 补充 */
            @"adq.qq.com", @"imgcache.qq.com",

            /* Umeng 统计/广告 */
            @"alog.umeng.com", @"ulogs.umeng.com",
            @"utoken.umeng.com", @"oslogs.umeng.com",

            /* 当贝 */
            @"e.dangbei.com",

            /* 游米广告 */
            @"api.yumi-ad.com",

            /* 快游 */
            @"sdk-ad.kuaiyou.net",

            /* 拼多多 DSP */
            @"ad.pinduoduo.com",

            /* 京东广告 */
            @"ad.jd.com",

            /* 爱奇艺广告 */
            @"sdk.iqiyi.com", @"afp.iqiyi.com",

            /* 优酷广告 */
            @"log.mmstat.com", @"ad.youku.com",

            /* 腾讯视频 DSP */
            @"adservice.google.com",

            /* 火眼/Flink 广告 */
            @"sdk.flinkads.com",

            /* 穿山甲补充子域 */
            @"sf3-ttcdn-tos.pstatp.com",
            @"ad-log.snssdk.com",

            /* 有米广告 */
            @"api.youmi.net", @"mtk.youmi.net",

            /* 微博广告 */
            @"mapi.weibo.com",

            /* 小米广告 */
            @"global.adtrack.mi.com",
            @"api.ad.xiaomi.com",

            /* OPPO 广告 */
            @"iad.heytapmobi.com",
            @"sdk.ad.heytapmobi.com",

            /* vivo 广告 */
            @"api.ad.vivo.com.cn",

            /* 华为广告 */
            @"adrequestserver.hicloud.com",
            @"adserver.cloud.huawei.com",

            /* 汇量/Mintegral 补充 */
            @"adnet.mintegral.com",
            @"ad.mintegral.com",

            /* 热云 Reyun */
            @"track.reyun.com",

            /* 数数科技 ThinkingData */
            @"sdkgw.huihuo.com",

            /* TilingSales 瓜子影视广告域名 */
            @"api.ainitpz.com",
            @"api.4hnovel.com",
            @"api.1000gxf.com",

            /* MoPub */
            @"ads.mopub.com", @"api.mopub.com",

            /* Chartboost */
            @"live.chartboost.com",

            /* AdColony */
            @"adc3-launch.adcolony.com",
            @"wd.adcolony.com",

            /* Taboola / Outbrain */
            @"trc.taboola.com", @"cdn.taboola.com",
            @"widgets.outbrain.com", @"odb.outbrain.com",

            /* Unity Ads */
            @"auction.unityads.unity3d.com",
            @"config.unityads.unity3d.com",

            /* AppLovin */
            @"a.applovin.com", @"d.applovin.com",
            @"rt.applovin.com", @"ms.applovin.com",

            /* InMobi */
            @"api.w.inmobi.com", @"sdkm.w.inmobi.com",

            /* IronSource */
            @"outcome-ssp.supersonicads.com",
            @"init.supersonicads.com",

            /* Smaato */
            @"soma.smaato.com",
        ]];

        /* ── 域名后缀匹配（覆盖子域名）── */
        gAdSuffixes = @[
            @".adukwai.com",
            @".gdt.qq.com",
            @".e.qq.com",
            @".sigmob.cn",
            @".1rtb.net",
            @".1rtb.com",
            @".beizi.biz",
            @".medproad.com",
            @".adn-plus.com.cn",
            @".zhangyuyidong.cn",
            @".ad-scope.com.cn",
            @".snssdk.com",
            @".csjplatform.com",
            @".anythinktech.com",
            @".mintegral.com",
            @".mobvista.com",
            @".rayjump.com",
            @".vungle.com",
            @".pangle.io",
            @".yumi-ad.com",
            @".applovin.com",
            @".inmobi.com",
            @".ironsource.com",
            @".fyber.com",
            @".liftoff.io",
            @".tanx.com",
            @".adnxs.com",
            @".criteo.com",
            @".pubmatic.com",
            @".unity3d.com",
            @".hubcloud.com.cn",
            @".flinkads.com",
            @".taboola.com",
            @".outbrain.com",
            @".mopub.com",
            @".chartboost.com",
            @".tapjoyads.com",
            @".startapp.com",
            @".leadbolt.com",
            @".digitalturbine.com",
            @".smaato.com",
            @".adcolony.com",
            @".youmi.net",
        ];

        /* ── 广告子域名首标签（ad.xxx.com 类型）── */
        gAdSubdomains = [NSSet setWithArray:@[
            @"ad",  @"ads",  @"adv",  @"adx",   @"adn",
            @"adlog", @"adtrack", @"adserver", @"adsdk",
            @"adapi", @"adshow", @"adservice", @"adreport",
            @"ad-log", @"ad-sdk", @"ad-track",
        ]];

        /* ── 域名内关键字（非首标签也能命中）── */
        gAdDomainKws = @[
            @"adservice", @"adserver",  @"adtrack",
            @"adnetwork", @"adplatform", @"adsystem",
            @".adx.",     @".dsp.",     @".ssp.",    @".rtb.",
            @"admob",
        ];

        /* ── URL 路径/参数关键字 ── */
        gAdPathKws = @[
            @"/adservice", @"/adrequest", @"/adtrack",
            @"/adsdk",     @"/adshow",    @"/adlog",
            @"/ad/load",   @"/ad/show",   @"/ad/request",  @"/ad/click",
            @"/ads/load",  @"/ads/show",  @"/ads/request",
            @"/splash_ad", @"/openscreen", @"/interstitialad",
            @"adtype=",    @"ad_type=",    @"adunit=",  @"ad_unit=",
            /* TilingSales 瓜子影视类通用规则 */
            @"/app/ad/",
            @"/indexlist/homefloatad",
            @"/resource/commentad/",
            @"/indexplay/vodadvertisement",
            /* 通用影视 App 广告路径 */
            @"/adinfo",    @"/adconfig",   @"/adpolicy",
            @"/getad",     @"/getads",     @"/adapi/",
            @"/ad_imp",    @"/adpv",       @"/adclick",
            @"/splashinfo", @"/bannerinfo", @"/floatad",
            @"/prerollad", @"/midrollad",  @"/postrollad",
            @"/rewardad",  @"/reward_ad",
        ];

        /* ── 开屏/插屏广告 VC 类名关键字 ── */
        gAdVCPatterns = @[
            /* 通用关键字 */
            @"SplashAd",    @"AdSplash",   @"LaunchAd",
            @"OpenAd",      @"StartAd",    @"FullScreenAd",
            @"InterstitialAd",
            /* Sigmob */
            @"SMSplashAd",  @"SMInterstitialAd",
            /* 腾讯 GDT */
            @"GDTSplashAd", @"GDTInterstitialAd",
            /* 快手 */
            @"KSAdSplash",  @"KSSplash",
            /* 字节/穿山甲 */
            @"BUSplashAd",  @"BUInterstitialAd", @"BUFullscreenVideoAd",
            /* Pangle */
            @"PAGSplash",   @"PAGInterstitial",
            /* 百度 */
            @"BdSplashAd",
            /* TopOn */
            @"ATSplashAd",  @"ATInterstitialAd",
            /* Mintegral */
            @"MBSplashAd",  @"MBInterstitialAd",
        ];

        [NSURLProtocol registerClass:[AdBlockProtocol class]];
    }
}
