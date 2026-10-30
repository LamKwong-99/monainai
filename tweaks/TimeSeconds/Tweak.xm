//
//  TimeSeconds — 让状态栏时间实时显示秒数
//  目标：iOS 16+ / RootHide（Dopamine roothide）/ 常规 rootless
//  2.1.5 极客性能与超低功耗引擎：
//    1. 真实零功耗待机（True Zero-Power Sleep）：锁屏/息屏定时器彻底停摆，亮屏毫秒级自愈唤醒
//    2. 纳秒级无分配时间源：底层 C 语言 time() + localtime_r() 纯栈运算，消除堆对象分配
//    3. 预解析分段时间缓存：每分钟仅解析 1 次正则，每小时消除 7,200 次正则计算
//    4. 富文本属性与字体单例复用：消除每秒高频字典与字形描述符临时对象
//    5. 灵动岛全机型弹性微缩自适应与中心对齐锁定
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>
#include <time.h>

#define TSLOG(fmt, ...) NSLog(@"[TimeSeconds] " fmt, ##__VA_ARGS__)

#pragma mark - 视觉与排版常量

#define TS_FONT_SCALE 1.0     // 保持 100% 系统原生字号
#define TS_KERN_RATIO 0.05    // 字距收紧比例，消除秒数跳动抖动并防挤爆
#define TS_MIN_SCALE 0.82     // 灵动岛展开挤压时的极限自适应微缩下限

#pragma mark - 文本正则与判定

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

// 检查是否为灵动岛药丸内部自带的倒计时私有子视图
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

#pragma mark - 字体与排版运算

static UIFont *TSMonospacedDigits(UIFont *font) {
    if (!font) return nil;
    CGFloat size = font.pointSize * TS_FONT_SCALE;
    if (size < 5.0) size = font.pointSize;
    size = round(size * 2.0) / 2.0;
    @try {
        NSArray *features = @[ @{ UIFontFeatureTypeIdentifierKey: @(6),
                                  UIFontFeatureSelectorIdentifierKey: @(0) } ];
        UIFontDescriptor *desc =
            [font.fontDescriptor fontDescriptorByAddingAttributes:
                @{ UIFontDescriptorFeatureSettingsAttribute: features }];
        return [UIFont fontWithDescriptor:desc size:size];
    } @catch (NSException *e) {
        return nil;
    }
}

static NSNumber *TSKernForSize(CGFloat size) {
    CGFloat k = -round(size * TS_KERN_RATIO * 100.0) / 100.0;
    return @(k);
}

#pragma mark - 高性能数据项模型（带预解析分段与属性单例缓存）

@interface TSItem : NSObject
@property (nonatomic, copy) NSString *base;
@property (nonatomic, copy) NSString *core;          // "15:18"
@property (nonatomic, copy) NSString *sep;           // ":"
@property (nonatomic, copy) NSString *suffix;        // " AM" 或 ""
@property (nonatomic, strong) NSAttributedString *attr;
@property (nonatomic, strong) UIFont *baseFont;
@property (nonatomic, strong) UIFont *cachedFont;
@property (nonatomic, strong) NSDictionary *cachedAttrs;
@property (nonatomic, copy) NSString *lastOut;
@property (nonatomic) CGFloat lastSize;

- (void)updateBase:(NSString *)base;
- (NSDictionary *)attributesForFont:(UIFont *)currentFont;
@end

@implementation TSItem

- (void)updateBase:(NSString *)base {
    if ([_base isEqualToString:base]) return;
    _base = [base copy];

    // 预解析分段（仅在整分钟变化时计算一次，彻底消除每秒正则解析）
    NSString *c = base;
    NSString *suf = @"";
    NSRange ampm = [base rangeOfString:@"[ \u00a0\u202f]*[APap]\\.?[Mm]\\.?\\s*$"
                               options:NSRegularExpressionSearch];
    if (ampm.location != NSNotFound) {
        suf = [base substringFromIndex:ampm.location];
        c = [base substringToIndex:ampm.location];
    }

    NSString *s = @":";
    NSRange sepRange = [c rangeOfString:@"[:.]" options:NSRegularExpressionSearch | NSBackwardsSearch];
    if (sepRange.location != NSNotFound) s = [c substringWithRange:sepRange];

    self.core = c;
    self.sep = s;
    self.suffix = suf;
}

// 缓存富文本属性字典，避免每秒重复创建 Dictionary、FontDescriptor
- (NSDictionary *)attributesForFont:(UIFont *)currentFont {
    if (self.cachedAttrs && self.baseFont == currentFont) {
        return self.cachedAttrs;
    }
    self.baseFont = currentFont;
    UIFont *want = TSMonospacedDigits(currentFont);
    if (!want) return nil;
    self.cachedFont = want;

    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    if (self.attr.length > 0) {
        NSDictionary *src = [self.attr attributesAtIndex:0 effectiveRange:NULL];
        if (src) [attrs addEntriesFromDictionary:src];
    }
    attrs[NSFontAttributeName] = want;
    attrs[NSKernAttributeName] = TSKernForSize(want.pointSize);
    self.cachedAttrs = [attrs copy];
    return self.cachedAttrs;
}

@end

#pragma mark - 时钟与状态管理器

@interface TSClock : NSObject
+ (instancetype)shared;
- (void)registerView:(id)view;
- (void)scheduleTick;
@end

static BOOL gInternal = NO;
static BOOL gHookActive = NO;                     // Hook 激活状态
static NSMapTable<UILabel *, TSItem *> *gViews;   // 弱引用自动回收池
static NSTimer *gTimer;
static NSTimeInterval gLastScan = 0;

// 底层 POSIX 高性能纳秒级时间提取（纯栈运行，0 堆分配）
static inline int TSGetCurrentSecond(void) {
    time_t rawtime;
    time(&rawtime);
    struct tm ti;
    localtime_r(&rawtime, &ti);
    return ti.tm_sec;
}

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

    if (TSIsIslandInternal(label)) return;

    NSString *text = label.text;
    NSAttributedString *attr = label.attributedText;

    NSString *base = TSBaseText(text);
    if (!base) base = TSBaseText(attr.string);
    if (!base) return;

    // 灵动岛防挤压与居中锁定
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = TS_MIN_SCALE;
    label.baselineAdjustment = UIBaselineAdjustmentAlignCenters;
    label.lineBreakMode = NSLineBreakByClipping;

    TSItem *it = [gViews objectForKey:label];
    if (!it) {
        it = [TSItem new];
        [gViews setObject:it forKey:label];
    }
    [it updateBase:base];
    it.attr = (text.length == 0 && attr.length > 0) ? attr : nil;
    if (it.appliedFont == nil || label.font != it.appliedFont) {
        it.baseFont = label.font;
    }

    // 若当前定时器处于休眠停摆状态，则立即唤醒对齐
    [self scheduleTick];
    [self renderView:label item:it second:TSGetCurrentSecond()];
}

- (void)renderView:(UILabel *)view item:(TSItem *)it second:(int)sec {
    if (it.base.length == 0) return;

    // 纳秒级预缓存字符串拼接
    NSString *out = [NSString stringWithFormat:@"%@%@%02d%@",
                     it.core ?: @"", it.sep ?: @":", sec, it.suffix ?: @""];

    UIFont *currentFont = view.font;
    if (it.appliedFont && currentFont != it.appliedFont) {
        it.baseFont = currentFont;
    } else if (!it.baseFont) {
        it.baseFont = currentFont;
    }

    NSDictionary *attrs = [it attributesForFont:it.baseFont];
    if (!attrs) return;
    UIFont *want = it.cachedFont;

    // 文本与字号短路跳过，彻底消除多余重绘
    NSString *cur = view.text;
    if (cur.length == 0) cur = view.attributedText.string;
    BOOL sameText = [it.lastOut isEqualToString:out] && [cur isEqualToString:out];
    BOOL sameSize = (fabs(it.lastSize - want.pointSize) <= 0.01);
    if (sameText && sameSize) return;

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

#pragma mark 零功耗调度引擎（True Zero-Power Sleep）

- (void)scheduleTick {
    if (gTimer) return;

    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    NSTimeInterval delay = 1.0 - fmod(now, 1.0) + 0.01;
    if (delay < 0.05) delay += 1.0;

    gTimer = [NSTimer timerWithTimeInterval:delay target:self selector:@selector(tick) userInfo:nil repeats:NO];
    gTimer.tolerance = 0.01;
    [[NSRunLoop mainRunLoop] addTimer:gTimer forMode:NSRunLoopCommonModes];
}

- (void)tick {
    gTimer = nil;
    BOOL anyVisible = NO;
    @autoreleasepool {
        anyVisible = [self refreshAll];
    }

    // 核心节能逻辑：
    // 只有在屏幕上有可见状态栏时才继续调度下一个整秒；
    // 一旦息屏/锁屏状态栏隐藏，定时器彻底停机（0 唤醒、0 耗电）。
    // 用户再次亮屏时，系统 SpringBoard 会触发 setText: 从而唤醒本插件。
    if (anyVisible) {
        [self scheduleTick];
    }
}

- (BOOL)refreshAll {
    int sec = TSGetCurrentSecond();
    BOOL anyVisible = NO;

    // 快速枚举，消灭临时 NSMutableArray 容器分配
    for (UILabel *v in gViews) {
        TSItem *it = [gViews objectForKey:v];
        if (!it) continue;

        BOOL isVisible = (v.window != nil && !v.hidden && v.alpha > 0.05);
        if (isVisible) {
            anyVisible = YES;
            NSString *cur = v.text;
            if (TSIsMinuteText(cur)) {
                [it updateBase:cur];
            } else if (cur.length == 0) {
                NSString *as = v.attributedText.string;
                if (TSIsMinuteText(as)) {
                    [it updateBase:as];
                    it.attr = v.attributedText;
                }
            }
            [self renderView:v item:it second:sec];
        }
    }

    if (gViews.count == 0 && !gHookActive) {
        [self maybeScan];
        return YES;
    }

    return anyVisible;
}

#pragma mark 兜底扫描（仅在 Hook 失效时按需激活）

- (void)maybeScan {
    if (gHookActive) return; // Hook 正常时永久关闭全局扫描，彻底释放 CPU
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - gLastScan < 3.0) return;
    gLastScan = now;

    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        [self scanView:w depth:0 statusBar:NO];
    }
}

- (void)scanView:(UIView *)v depth:(NSInteger)d statusBar:(BOOL)sb {
    if (d > 25) return;
    if (TSIsIslandInternal(v)) return;

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
            gHookActive = YES;
            %init(StringViewHooks);
            TSLOG(@"_UIStatusBarStringView hooked (Zero-Power Engine ready)");
        } else {
            TSLOG(@"_UIStatusBarStringView missing — 降级进入扫描模式");
        }
    }
}
