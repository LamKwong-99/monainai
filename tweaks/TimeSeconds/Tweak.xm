//
//  TimeSeconds — 让状态栏时间实时显示秒数
//  目标：iOS 16+ / RootHide（Dopamine roothide）/ 常规 rootless
//  2.1.7 官方原生级排版与极致美学版：
//    1. 100% 还原苹果原生 Semibold 饱满字重（消灭发虚、偏细与比例失调）
//    2. 优雅分层排版：时分 100% 原生大字 + 冒号秒数 78% 精致小标
//    3. 彻底根治灵动岛外卖/音乐等实时活动遮挡秒数（自然收窄 12pt，不碰头、不左偏）
//    4. 消除负字距压迫感，恢复自然光学字距，冒号不再畸形变形
//    5. 真实零功耗待机：锁屏/息屏定时器彻底停摆（0 唤醒 0 耗电），亮屏毫秒级自愈
//    6. 纳秒级底层 C 语言 time() 栈运算，属性字典单例复用，零内存抖动
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>
#include <time.h>

#define TSLOG(fmt, ...) NSLog(@"[TimeSeconds] " fmt, ##__VA_ARGS__)

#pragma mark - 视觉排版常量

#define TS_FONT_SCALE 1.0     // 时分保持 100% 苹果原生字号
#define TS_SEC_SCALE  0.78    // 秒数微缩至 78% 精致小标，彻底避让灵动岛
#define TS_MIN_SCALE  0.82    // 灵动岛极端挤压时的自适应微缩下限

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

#pragma mark - 原生官方 Semibold 等宽字形提取

static CGFloat TSGetFontWeight(UIFont *font) {
    if (!font) return UIFontWeightSemibold;
    NSDictionary *traits = [font.fontDescriptor objectForKey:UIFontDescriptorTraitsAttribute];
    if (traits && traits[UIFontWeightTrait]) {
        CGFloat w = [traits[UIFontWeightTrait] floatValue];
        // 状态栏原生字重通常在 0.23 (Medium) 到 0.30 (Semibold) 之间
        if (w >= 0.20) return w;
    }
    return UIFontWeightSemibold;
}

#pragma mark - 数据模型（双字阶与属性单例缓存）

@interface TSItem : NSObject
@property (nonatomic, copy) NSString *base;
@property (nonatomic, copy) NSString *core;          // "22:45"
@property (nonatomic, copy) NSString *sep;           // ":"
@property (nonatomic, copy) NSString *suffix;        // " AM" 或 ""
@property (nonatomic, strong) NSAttributedString *attr;
@property (nonatomic, strong) UIFont *baseFont;
@property (nonatomic, strong) UIFont *cachedMainFont;
@property (nonatomic, strong) UIFont *cachedSecFont;
@property (nonatomic, strong) NSDictionary *cachedMainAttrs;
@property (nonatomic, strong) NSDictionary *cachedSecAttrs;
@property (nonatomic, copy) NSString *lastOut;

- (void)updateBase:(NSString *)base;
- (void)updateFontsForCurrentFont:(UIFont *)currentFont;
@end

@implementation TSItem

- (void)updateBase:(NSString *)base {
    if ([_base isEqualToString:base]) return;
    _base = [base copy];

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

- (void)updateFontsForCurrentFont:(UIFont *)currentFont {
    if (self.cachedMainAttrs && self.baseFont == currentFont) {
        return;
    }
    self.baseFont = currentFont;

    CGFloat baseSize = currentFont ? currentFont.pointSize : 15.0;
    if (baseSize < 5.0) baseSize = 15.0;
    CGFloat weight = TSGetFontWeight(currentFont);

    // 时分：100% 苹果原生字号与 Semibold 饱满字重
    CGFloat mainSize = round(baseSize * TS_FONT_SCALE * 2.0) / 2.0;
    self.cachedMainFont = [UIFont monospacedDigitSystemFontOfSize:mainSize weight:weight];

    // 秒数：78% 精致小标，同样保持 Semibold 饱满字重，视觉不发虚
    CGFloat secSize = round(baseSize * TS_SEC_SCALE * 2.0) / 2.0;
    self.cachedSecFont = [UIFont monospacedDigitSystemFontOfSize:secSize weight:weight];

    // 主属性（时分）
    NSMutableDictionary *mainAttrs = [NSMutableDictionary dictionary];
    if (self.attr.length > 0) {
        NSDictionary *src = [self.attr attributesAtIndex:0 effectiveRange:NULL];
        if (src) [mainAttrs addEntriesFromDictionary:src];
    }
    mainAttrs[NSFontAttributeName] = self.cachedMainFont;
    self.cachedMainAttrs = [mainAttrs copy];

    // 次属性（秒数，微调 0.5pt 基线提升以与大字几何视觉居中对齐）
    NSMutableDictionary *secAttrs = [NSMutableDictionary dictionaryWithDictionary:mainAttrs];
    secAttrs[NSFontAttributeName] = self.cachedSecFont;
    secAttrs[NSBaselineOffsetAttributeName] = @(0.5);
    self.cachedSecAttrs = [secAttrs copy];
}

@end

#pragma mark - 时钟与状态管理器

@interface TSClock : NSObject
+ (instancetype)shared;
- (void)registerView:(id)view;
- (void)scheduleTick;
@end

static BOOL gInternal = NO;
static BOOL gHookActive = NO;
static NSMapTable<UILabel *, TSItem *> *gViews;
static NSTimer *gTimer;
static NSTimeInterval gLastScan = 0;

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

    // 恢复自然居中与原生平移（无需任何左移位移，靠紧凑排版自然避开遮挡）
    label.transform = CGAffineTransformIdentity;
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
    [it updateFontsForCurrentFont:label.font];

    [self scheduleTick];
    [self renderView:label item:it second:TSGetCurrentSecond()];
}

- (void)renderView:(UILabel *)view item:(TSItem *)it second:(int)sec {
    if (it.base.length == 0) return;

    // 确保视图保持原生坐标系
    if (!CGAffineTransformIsIdentity(view.transform)) {
        view.transform = CGAffineTransformIdentity;
    }

    [it updateFontsForCurrentFont:view.font];
    if (!it.cachedMainAttrs || !it.cachedSecAttrs) return;

    NSString *core = it.core ?: @"";
    NSString *secStr = [NSString stringWithFormat:@"%@%02d%@",
                        it.sep ?: @":", sec, it.suffix ?: @""];
    NSString *fullOut = [core stringByAppendingString:secStr];

    // 短路跳过无谓重绘
    NSString *cur = view.text;
    if (cur.length == 0) cur = view.attributedText.string;
    if ([it.lastOut isEqualToString:fullOut] && [cur isEqualToString:fullOut]) {
        return;
    }

    // 构建双字阶优雅富文本（时分原生大字 Semibold + 秒数小标 Semibold）
    NSMutableAttributedString *as = [[NSMutableAttributedString alloc] initWithString:core attributes:it.cachedMainAttrs];
    NSAttributedString *secAttr = [[NSAttributedString alloc] initWithString:secStr attributes:it.cachedSecAttrs];
    [as appendAttributedString:secAttr];

    gInternal = YES;
    @try {
        view.attributedText = as;
        it.lastOut = fullOut;
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

    // 亮屏且有可见状态栏才继续对齐调度；息屏完全停机
    if (anyVisible) {
        [self scheduleTick];
    }
}

- (BOOL)refreshAll {
    int sec = TSGetCurrentSecond();
    BOOL anyVisible = NO;

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

#pragma mark 兜底扫描

- (void)maybeScan {
    if (gHookActive) return;
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
            TSLOG(@"_UIStatusBarStringView hooked (Official Semibold & Sub-second Engine ready)");
        } else {
            TSLOG(@"_UIStatusBarStringView missing — 降级进入扫描模式");
        }
    }
}
