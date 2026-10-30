//
//  TimeSeconds — 让状态栏时间实时显示秒数
//  目标：iOS 16+ / RootHide（Dopamine roothide）/ 常规 rootless
//  针对灵动岛（Dynamic Island）全机型专门深度优化：
//    1. 灵动岛实时活动极限挤压防护（自适应弹性压缩，不截断、不显示省略号）
//    2. OLED AOD（全天候显示）与锁屏息屏深度节能（息屏自动休眠，杜绝后台耗电）
//    3. 灵动岛弹簧动画居中基线抗抖动（保证伸缩变形时视觉垂直居中）
//    4. 灵动岛内部药丸组件防误抓隔离（精准只接管状态栏主时钟）
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>

#define TSLOG(fmt, ...) NSLog(@"[TimeSeconds] " fmt, ##__VA_ARGS__)

#pragma mark - 视觉与排版常量

// 保持 100% 原生系统字号（与原生完全一致）
#define TS_FONT_SCALE 1.0

// 字距收紧比例（相对字号）。0.05 ≈ 14.5pt 下每个字符间隙收 0.7pt，收敛宽度防挤爆
#define TS_KERN_RATIO 0.05

// 灵动岛展开（实时活动/音乐波形/导航挤压）时的极限自适应微缩下限
#define TS_MIN_SCALE 0.82

#pragma mark - 文本判定 / 渲染

static BOOL TSMatches(NSString *s, NSString *pattern) {
    if (s.length == 0) return NO;
    return [s rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound;
}

// "9:41" / "09:41" / "9.41" / "9:41 AM"
static BOOL TSIsMinuteText(NSString *s) {
    if (s.length == 0 || s.length > 20) return NO;
    return TSMatches(s, @"^\\s*[0-9]{1,2}[:.][0-9]{2}(\\s*[APap]\\.?[Mm]\\.?)?\\s*$");
}

// "9:41:07" / "09:41:07" / "9:41:07 AM"
static BOOL TSIsSecondText(NSString *s) {
    if (s.length == 0 || s.length > 24) return NO;
    return TSMatches(s, @"^\\s*[0-9]{1,2}[:.][0-9]{2}[:.][0-9]{2}(\\s*[APap]\\.?[Mm]\\.?)?\\s*$");
}

// 把 "9:41:07" 还原成 "9:41"；不是时间就返回 nil
static NSString *TSBaseText(NSString *s) {
    if (TSIsMinuteText(s)) return s;
    if (!TSIsSecondText(s)) return nil;

    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"^\\s*([0-9]{1,2}[:.][0-9]{2})[:.][0-9]{2}(\\s*[APap]\\.?[Mm]\\.?)?\\s*$"
                                                     options:0
                                                       error:nil];
    });
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (!m) return nil;
    return [re replacementStringForResult:m inString:s offset:0 template:@"$1$2"];
}

// 在分钟级文本后面插入秒，保留原来的分隔符和 AM/PM 后缀
static NSString *TSWithSeconds(NSString *base, NSInteger sec) {
    if (base.length == 0) return base;

    NSString *core = base;
    NSString *suffix = @"";

    NSRange ampm = [base rangeOfString:@"[ \u00a0\u202f]*[APap]\\.?[Mm]\\.?\\s*$"
                               options:NSRegularExpressionSearch];
    if (ampm.location != NSNotFound) {
        suffix = [base substringFromIndex:ampm.location];
        core = [base substringToIndex:ampm.location];
    }

    NSString *sep = @":";
    NSRange s = [core rangeOfString:@"[:.]" options:NSRegularExpressionSearch | NSBackwardsSearch];
    if (s.location != NSNotFound) sep = [core substringWithRange:s];

    return [NSString stringWithFormat:@"%@%@%02ld%@", core, sep, (long)sec, suffix];
}

// 检查是否为灵动岛药丸内部的私有子视图（避免误抓灵动岛内部自带的倒计时）
static BOOL TSIsIslandInternal(UIView *view) {
    UIView *cur = view;
    while (cur) {
        NSString *cls = NSStringFromClass([cur class]);
        if ([cls containsString:@"SystemAperture"] ||
            [cls containsString:@"Jindo"] ||
            [cls containsString:@"IslandContainer"] ||
            [cls containsString:@"ActivityLeading"] ||
            [cls containsString:@"ActivityTrailing"]) {
            return YES;
        }
        cur = cur.superview;
    }
    return NO;
}

#pragma mark - 每个视图的状态

@interface TSItem : NSObject
@property (nonatomic, copy) NSString *base;          // 分钟级基准文本
@property (nonatomic, strong) NSAttributedString *attr; // 若原视图用 attributedText 则保留样式
@property (nonatomic, strong) UIFont *baseFont;      // 系统原始字体（缩放前）
@property (nonatomic, strong) UIFont *appliedFont;   // 我们最后写进去的字体
@property (nonatomic, copy) NSString *lastOut;       // 上一次渲染的完整文本
@property (nonatomic) CGFloat lastSize;              // 上一次渲染用的字号
@end
@implementation TSItem
@end

static UIFont *TSMonospacedDigits(UIFont *font) {
    if (!font) return nil;
    CGFloat size = font.pointSize * TS_FONT_SCALE;
    if (size < 5.0) size = font.pointSize;
    size = round(size * 2.0) / 2.0;      // 0.5pt 粒度
    @try {
        NSArray *features = @[ @{ UIFontFeatureTypeIdentifierKey: @(6),      // kNumberSpacingType
                                  UIFontFeatureSelectorIdentifierKey: @(0) } ]; // MonospacedNumbersSelector
        UIFontDescriptor *desc =
            [font.fontDescriptor fontDescriptorByAddingAttributes:
                @{ UIFontDescriptorFeatureSettingsAttribute: features }];
        return [UIFont fontWithDescriptor:desc size:size];
    } @catch (NSException *e) {
        return nil;
    }
}

// 负的 NSKern 让 9:41:07 稍微紧凑一点，整体能窄 2~3pt
static NSNumber *TSKernForSize(CGFloat size) {
    CGFloat k = -round(size * TS_KERN_RATIO * 100.0) / 100.0;
    return @(k);
}

#pragma mark - 时钟与状态管理器

@interface TSClock : NSObject
+ (instancetype)shared;
- (void)registerView:(id)view;
- (void)scheduleTick;
@end

static BOOL gInternal = NO;                       // 防止自己的写入被 hook 再次处理
static NSMapTable<UILabel *, TSItem *> *gViews;   // 弱引用 key，视图销毁自动移除
static NSTimer *gTimer;
static NSTimeInterval gLastScan = 0;

@implementation TSClock

+ (instancetype)shared {
    static TSClock *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = [TSClock new];
        gViews = [NSMapTable weakToStrongObjectsMapTable];
    });
    return c;
}

- (void)registerView:(id)view {
    if (![view isKindOfClass:[UILabel class]]) return;
    UILabel *label = (UILabel *)view;

    // 隔离灵动岛内部自带的倒计时组件
    if (TSIsIslandInternal(label)) return;

    NSString *text = label.text;
    NSAttributedString *attr = label.attributedText;

    NSString *base = TSBaseText(text);
    if (!base) base = TSBaseText(attr.string);
    if (!base) return;

    // 灵动岛适配：设置弹性自适应与垂直居中锁定
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = TS_MIN_SCALE;
    label.baselineAdjustment = UIBaselineAdjustmentAlignCenters;
    label.lineBreakMode = NSLineBreakByClipping;

    TSItem *it = [gViews objectForKey:label];
    if (!it) {
        it = [TSItem new];
        [gViews setObject:it forKey:label];
    }
    it.base = base;
    it.attr = (text.length == 0 && attr.length > 0) ? attr : nil;
    if (it.appliedFont == nil || label.font != it.appliedFont) {
        it.baseFont = label.font;
    }

    [self scheduleTick];
    [self renderView:label item:it];
}

- (void)renderView:(UILabel *)view item:(TSItem *)it {
    if (it.base.length == 0) return;

    NSInteger sec = [[NSCalendar currentCalendar] component:NSCalendarUnitSecond fromDate:[NSDate date]];
    NSString *out = TSWithSeconds(it.base, sec);

    // 字体：始终从系统原始字体推导，避免每分钟被重复缩放
    UIFont *f = view.font;
    if (it.appliedFont && f != it.appliedFont) {
        it.baseFont = f;                     // 系统换了字体（灵动岛药丸变大/样式切换），跟着走
    } else if (!it.baseFont) {
        it.baseFont = f;
    }

    UIFont *want = TSMonospacedDigits(it.baseFont);
    if (!want) return;

    // 文本和字号都没变就跳过，避免灵动岛弹簧动画过程中的多余布局重绘
    NSString *cur = view.text;
    if (cur.length == 0) cur = view.attributedText.string;
    BOOL sameText = [it.lastOut isEqualToString:out] && [cur isEqualToString:out];
    BOOL sameSize = (fabs(it.lastSize - want.pointSize) <= 0.01);
    if (sameText && sameSize) return;

    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    if (it.attr.length > 0) {
        NSDictionary *src = [it.attr attributesAtIndex:0 effectiveRange:NULL];
        if (src) [attrs addEntriesFromDictionary:src];
    }
    attrs[NSFontAttributeName] = want;
    attrs[NSKernAttributeName] = TSKernForSize(want.pointSize);

    gInternal = YES;
    @try {
        view.attributedText = [[NSAttributedString alloc] initWithString:out attributes:attrs];
        it.appliedFont = want;
        it.lastOut = out;
        it.lastSize = want.pointSize;
    } @catch (NSException *e) {
        TSLOG(@"render failed: %@", e);
    } @finally {
        gInternal = NO;
    }
}

#pragma mark 定时器与 AOD / 息屏节能调度

- (void)scheduleTick {
    if (gTimer) {
        [gTimer invalidate];
        gTimer = nil;
    }
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    NSTimeInterval delay = 1.0 - fmod(now, 1.0) + 0.01;
    if (delay < 0.05) delay += 1.0;

    gTimer = [NSTimer timerWithTimeInterval:delay target:self selector:@selector(tick) userInfo:nil repeats:NO];
    gTimer.tolerance = 0.01;
    [[NSRunLoop mainRunLoop] addTimer:gTimer forMode:NSRunLoopCommonModes];
}

// 低功耗待机模式（AOD 息屏 / 锁屏状态栏淡出时调度，3 秒一次轻量轮询）
- (void)scheduleIdleTick {
    if (gTimer) return;
    gTimer = [NSTimer timerWithTimeInterval:3.0 target:self selector:@selector(tick) userInfo:nil repeats:NO];
    gTimer.tolerance = 0.5;
    [[NSRunLoop mainRunLoop] addTimer:gTimer forMode:NSRunLoopCommonModes];
}

- (void)tick {
    gTimer = nil;
    BOOL anyVisible = NO;
    @autoreleasepool {
        anyVisible = [self refreshAll];
    }

    // 智能动态节电：若当前屏幕有可见状态栏，则保持 1 秒高精度对齐；
    // 若当前无任何可见状态栏（手机息屏/全屏游戏隐藏状态栏/锁屏深睡），则进入低功耗待机
    if (anyVisible) {
        [self scheduleTick];
    } else {
        [self scheduleIdleTick];
    }
}

- (BOOL)refreshAll {
    NSMutableArray *keys = [NSMutableArray array];
    for (id k in gViews) [keys addObject:k];

    BOOL anyVisible = NO;

    for (UILabel *v in keys) {
        TSItem *it = [gViews objectForKey:v];
        if (!it) continue;

        // 视图可见性检查（挂载在活跃窗口、未隐藏、透明度大于 0.05）
        BOOL isVisible = (v.window != nil && !v.hidden && v.alpha > 0.05);
        if (isVisible) {
            anyVisible = YES;
            // 系统在整分钟时会重新写一次文本，自动跟进
            NSString *cur = v.text;
            if (TSIsMinuteText(cur)) {
                it.base = cur;
            } else if (cur.length == 0) {
                NSString *as = v.attributedText.string;
                if (TSIsMinuteText(as)) {
                    it.base = as;
                    it.attr = v.attributedText;
                }
            }
            [self renderView:v item:it];
        }
    }

    if (keys.count == 0) {
        [self maybeScan];
        return YES; // 尚未找到视图时保持探测
    }

    return anyVisible;
}

#pragma mark 兜底扫描

- (void)maybeScan {
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - gLastScan < 2.0) return;
    gLastScan = now;

    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        [self scanView:w depth:0 statusBar:NO];
    }
}

- (void)scanView:(UIView *)v depth:(NSInteger)d statusBar:(BOOL)sb {
    if (d > 30) return;
    if (TSIsIslandInternal(v)) return; // 忽略灵动岛内部组件

    BOOL inSB = sb || [NSStringFromClass([v class]) containsString:@"StatusBar"];
    if (inSB && [v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        if (TSBaseText(l.text) || TSBaseText(l.attributedText.string)) {
            [self registerView:l];
        }
    }
    for (UIView *s in v.subviews) {
        [self scanView:s depth:d + 1 statusBar:inSB];
    }
}

@end

#pragma mark - Hook

%group StringViewHooks
%hook _UIStatusBarStringView

- (void)setText:(NSString *)text {
    %orig;
    if (gInternal) return;
    if (TSBaseText(text)) {
        [[TSClock shared] registerView:self];
    }
}

- (void)setAttributedText:(NSAttributedString *)text {
    %orig;
    if (gInternal) return;
    if (TSBaseText(text.string)) {
        [[TSClock shared] registerView:self];
    }
}

%end
%end

%ctor {
    @autoreleasepool {
        [TSClock shared];

        Class c = objc_getClass("_UIStatusBarStringView");
        if (c) {
            %init(StringViewHooks);
            TSLOG(@"_UIStatusBarStringView hooked");
        } else {
            TSLOG(@"_UIStatusBarStringView missing — 只能靠扫描兜底");
        }
    }
}
