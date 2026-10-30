//
//  TimeSeconds — 让状态栏时间实时显示秒数
//  目标：iOS 16+ / RootHide（Dopamine roothide）/ 常规 rootless
//  2.2.0 灵动岛智能避让纯净版（方案 2 终极落地）：
//    1. 还原 100% 满血原生大字号、原生 Semibold 饱满粗细、原生对称居中位置（彻底去除左移与字距压缩）
//    2. 所有数字时分秒完全等大（彻底去除大小字分层）
//    3. 灵动岛智能感知避让：
//       - 平时（无外卖/打车/音乐等活动）：显示 100% 满血原生秒数大字 "22:45:14"
//       - 当灵动岛展开实时活动占用左耳空间时：智能优雅降级为原生时分 "22:45"，彻底杜绝遮挡
//       - 实时活动收起或送达后：毫秒级自动恢复全尺寸秒数显示
//    4. 真实零功耗待机：锁屏息屏定时器彻底停摆（0 唤醒 0 耗电），亮屏毫秒级自愈
//    5. 底层 C 语言 time() 栈运算，属性字典单例复用，零内存抖动
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>
#include <time.h>

#define TSLOG(fmt, ...) NSLog(@"[TimeSeconds] " fmt, ##__VA_ARGS__)

#pragma mark - 满血原生排版常量

// 100% 满血苹果系统原生大字号（绝不微缩，还原官方尺寸）
#define TS_FONT_SCALE 1.0

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

#pragma mark - 灵动岛实时活动展开状态智能探测

static BOOL TSIsApertureExpanded(void) {
    @try {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            NSString *wCls = NSStringFromClass([w class]);
            if (![wCls containsString:@"Aperture"]) continue;

            UIViewController *rvc = w.rootViewController;
            if (rvc) {
                // 方式 1：检查实时活动 elements 集合（外卖/音乐/打车激活时 count > 0）
                if ([rvc respondsToSelector:@selector(activeElements)]) {
                    NSArray *elems = [(id)rvc activeElements];
                    if (elems && [elems count] > 0) return YES;
                }

                // 方式 2：检查灵动岛药丸容器视图宽度（正常黑药丸宽约 126pt，有实时活动展开时宽 > 155pt）
                UIView *rv = rvc.view;
                if (rv) {
                    for (UIView *sub in rv.subviews) {
                        CGRect b = sub.bounds;
                        if (b.size.width > 155.0 && b.size.width < 390.0 && b.size.height > 25.0) {
                            return YES;
                        }
                    }
                }
            }
        }
    } @catch (NSException *e) {}
    return NO;
}

#pragma mark - 原生官方 Semibold 饱满字形提取

static CGFloat TSGetFontWeight(UIFont *font) {
    if (!font) return UIFontWeightSemibold;
    NSDictionary *traits = [font.fontDescriptor objectForKey:UIFontDescriptorTraitsAttribute];
    if (traits && traits[UIFontWeightTrait]) {
        CGFloat w = [traits[UIFontWeightTrait] floatValue];
        if (w >= 0.20) return w;
    }
    return UIFontWeightSemibold;
}

#pragma mark - 数据模型（满血原生字重与防污染缓存）

@interface TSItem : NSObject
@property (nonatomic, copy) NSString *base;
@property (nonatomic, copy) NSString *core;          // "22:45"
@property (nonatomic, copy) NSString *sep;           // ":"
@property (nonatomic, copy) NSString *suffix;        // " AM" 或 ""
@property (nonatomic, strong) NSAttributedString *attr;
@property (nonatomic, strong) UIFont *baseFont;
@property (nonatomic, strong) UIFont *cachedFont;
@property (nonatomic, strong) NSDictionary *cachedAttrs;
@property (nonatomic, copy) NSString *lastOut;

- (void)updateBase:(NSString *)base;
- (void)setSystemFont:(UIFont *)font;
- (NSDictionary *)getAttributes;
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

- (void)setSystemFont:(UIFont *)font {
    if (!font) return;
    if (self.cachedFont && [font isEqual:self.cachedFont]) {
        return;
    }
    CGFloat baseSize = font.pointSize;
    if (baseSize < 12.0) baseSize = 15.0; // 锁死正常 15pt 大字底线

    self.baseFont = font;
    CGFloat weight = TSGetFontWeight(font);

    // 100% 满血原生大字号，Semibold 饱满粗体
    CGFloat finalSize = round(baseSize * TS_FONT_SCALE * 2.0) / 2.0;
    self.cachedFont = [UIFont monospacedDigitSystemFontOfSize:finalSize weight:weight];

    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    if (self.attr.length > 0) {
        NSDictionary *src = [self.attr attributesAtIndex:0 effectiveRange:NULL];
        if (src) [attrs addEntriesFromDictionary:src];
    }
    attrs[NSFontAttributeName] = self.cachedFont;
    // 零负字距，冒号与数字 100% 自然舒展
    attrs[NSKernAttributeName] = @(0.0);
    self.cachedAttrs = [attrs copy];
}

- (NSDictionary *)getAttributes {
    if (!self.cachedAttrs) {
        [self setSystemFont:self.baseFont ?: [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold]];
    }
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

    // 彻底恢复原生位置（零位移，零压缩，关闭 UIKit 自动缩容）
    label.transform = CGAffineTransformIdentity;
    label.adjustsFontSizeToFitWidth = NO;
    label.lineBreakMode = NSLineBreakByClipping;

    TSItem *it = [gViews objectForKey:label];
    if (!it) {
        it = [TSItem new];
        [gViews setObject:it forKey:label];
    }
    [it updateBase:base];
    it.attr = (text.length == 0 && attr.length > 0) ? attr : nil;
    [it setSystemFont:label.font];

    [self scheduleTick];
    [self renderView:label item:it second:TSGetCurrentSecond()];
}

- (void)renderView:(UILabel *)view item:(TSItem *)it second:(int)sec {
    if (it.base.length == 0) return;

    // 锁死原生居中位置
    if (!CGAffineTransformIsIdentity(view.transform)) {
        view.transform = CGAffineTransformIdentity;
    }
    if (view.adjustsFontSizeToFitWidth) {
        view.adjustsFontSizeToFitWidth = NO;
    }

    if (view.font && it.cachedFont && ![view.font isEqual:it.cachedFont] && view.font.pointSize >= 12.0) {
        [it setSystemFont:view.font];
    }

    NSDictionary *attrs = [it getAttributes];
    if (!attrs) return;

    // 方案 2 核心机制：灵动岛智能避让
    // 当外卖/打车/音乐等实时活动展开导致左侧空间被极限挤占时，智能显示原生时分 base；
    // 其余平时正常状态下，显示 100% 满血原生大字秒数！
    BOOL isApertureBusy = TSIsApertureExpanded();
    NSString *fullOut = isApertureBusy ? (it.base ?: @"") :
                        [NSString stringWithFormat:@"%@%@%02d%@",
                         it.core ?: @"", it.sep ?: @":", sec, it.suffix ?: @""];

    // 短路跳过无谓重绘
    NSString *cur = view.text;
    if (cur.length == 0) cur = view.attributedText.string;
    if ([it.lastOut isEqualToString:fullOut] && [cur isEqualToString:fullOut]) {
        return;
    }

    NSAttributedString *as = [[NSAttributedString alloc] initWithString:fullOut attributes:attrs];

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
            TSLOG(@"_UIStatusBarStringView hooked (Scheme 2 Pure Native & Dynamic Island Smart Avoidance ready)");
        } else {
            TSLOG(@"_UIStatusBarStringView missing — 降级进入扫描模式");
        }
    }
}
