#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <mach-o/dyld.h>
#include <notify.h>
#include "general.h"

@interface PRXTextView : UITextView
- (void)setTitleText:(id)titleView;
@end

@interface PRXCardContentView : UIView
@end

@interface PRXCardBackgroundView : UIView
@end

@interface PRXCardContainerView : UIView
@end

@interface PRXCardSlideUpPresentationController : UIPresentationController
@end

@interface PRXFlowConfiguration : NSObject
- (void)setSupportsDarkMode:(BOOL)arg1;
- (BOOL)supportsDarkMode;
@end

static struct podsgrant_settings *settings = NULL;
static int g_unlock_token = 0;

// 4 槽位多设备环形缓存（彻底解决 Apple Watch 与 AirPods 同时广播时的缓存抖动）
struct pgs_cache_slot {
	uint16_t orig;
	uint16_t target;
};
static struct pgs_cache_slot s_pid_cache[4] = {{0,0}, {0,0}, {0,0}, {0,0}};
static int s_cache_idx = 0;

static void reload_settings_if_needed(void) {
	if (settings) {
		PGS_freeSettings(settings);
		settings = NULL;
	}
	settings = PGS_readSettings(0);
	for (int i = 0; i < 4; i++) {
		s_pid_cache[i].orig = 0;
		s_pid_cache[i].target = 0;
	}
}

static inline uint16_t fast_patch_pid(uint16_t orig) {
	for (int i = 0; i < 4; i++) {
		if (s_pid_cache[i].orig == orig) {
			return s_pid_cache[i].target;
		}
	}
	uint16_t target = PGS_patchProductId(settings, orig);
	s_pid_cache[s_cache_idx].orig = orig;
	s_pid_cache[s_cache_idx].target = target;
	s_cache_idx = (s_cache_idx + 1) & 3;
	return target;
}

%group sharing_hook_grp

%hook SFBLEScanner

- (id)pairingParsePayload:(NSData *)payload identifier:(id)idf bleDevice:(id)bleDev peerInfo:(id)peerInfo {
	if (!payload || payload.length < 7) {
		return %orig;
	}

	const uint8_t *bytes = (const uint8_t *)payload.bytes;
	uint16_t orig_pid = *(const uint16_t *)(bytes + 5);
	uint16_t patched = fast_patch_pid(orig_pid);

	if (patched && patched != orig_pid) {
		NSMutableData *mutPayload = [payload mutableCopy];
		uint16_t *target_ptr = (uint16_t *)((uint8_t *)mutPayload.mutableBytes + 5);
		*target_ptr = patched;
		return %orig(mutPayload, idf, bleDev, peerInfo);
	}
	return %orig;
}

- (id)pairingParsePayload:(NSData *)payload identifier:(id)idf bleDevice:(id)bleDev {
	if (!payload || payload.length < 7) {
		return %orig;
	}

	const uint8_t *bytes = (const uint8_t *)payload.bytes;
	uint16_t orig_pid = *(const uint16_t *)(bytes + 5);
	uint16_t patched = fast_patch_pid(orig_pid);

	if (patched && patched != orig_pid) {
		NSMutableData *mutPayload = [payload mutableCopy];
		uint16_t *target_ptr = (uint16_t *)((uint8_t *)mutPayload.mutableBytes + 5);
		*target_ptr = patched;
		return %orig(mutPayload, idf, bleDev);
	}
	return %orig;
}

%end

%end

// ==========================================
// iOS 16 质感增强：自适应系统深浅色模式 + 彻底消灭冷启动白闪 + Taptic 触觉反馈
// ==========================================
%group darkpods_hook_grp

static NSTimeInterval s_last_haptic_time = 0;

static inline BOOL PGS_IsSystemDarkMode(void) {
	// 方式 1: 直接向 UIKitServices 查询全局深色模式模式值（冷启动 0 毫秒即生效）
	static Class s_styleModeCls = nil;
	static dispatch_once_t s_once;
	dispatch_once(&s_once, ^{
		s_styleModeCls = objc_getClass("UISUserInterfaceStyleMode");
	});
	if (s_styleModeCls) {
		id modeObj = [[s_styleModeCls alloc] init];
		if (modeObj) {
			long long mode = 0;
			@try {
				mode = ((long long (*)(id, SEL))objc_msgSend)(modeObj, sel_registerName("mode"));
			} @catch (id ex) {}
			if (mode == 2) return YES; // 2 = Dark Mode
			if (mode == 1) return NO;  // 1 = Light Mode
		}
	}
	// 方式 2: 屏幕/当前环境兜底
	if (@available(iOS 13.0, *)) {
		UIUserInterfaceStyle s = [UIScreen mainScreen].traitCollection.userInterfaceStyle;
		if (s == UIUserInterfaceStyleDark) return YES;
		if (s == UIUserInterfaceStyleLight) return NO;
	}
	return NO;
}

static inline UIUserInterfaceStyle PGS_CurrentSystemStyle(void) {
	return PGS_IsSystemDarkMode() ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
}

static void PGS_TriggerHapticFeedback(void) {
	NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
	if (now - s_last_haptic_time < 2.0) {
		return; // 2秒防抖，避免重复触发
	}
	s_last_haptic_time = now;
	dispatch_async(dispatch_get_main_queue(), ^{
		UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
		[generator prepare];
		[generator impactOccurred];
	});
}

// 1. 根源防御：从顶级 UIWindow 创建瞬间锁定外观，所有子视图/毛玻璃从分配内存第一帧即为深色
%hook UIWindow

- (instancetype)initWithFrame:(CGRect)frame {
	self = %orig(frame);
	if (self) {
		self.overrideUserInterfaceStyle = PGS_CurrentSystemStyle();
	}
	return self;
}

- (instancetype)initWithWindowScene:(id)scene {
	self = %orig(scene);
	if (self) {
		self.overrideUserInterfaceStyle = PGS_CurrentSystemStyle();
	}
	return self;
}

- (void)makeKeyAndVisible {
	self.overrideUserInterfaceStyle = PGS_CurrentSystemStyle();
	%orig;
}

%end

// 2. 转场动画防御：滑入动画开始前，锁定被呈现控制器及外壳容器
%hook PRXCardSlideUpPresentationController

- (void)presentationTransitionWillBegin {
	UIUserInterfaceStyle targetStyle = PGS_CurrentSystemStyle();
	self.presentedViewController.overrideUserInterfaceStyle = targetStyle;
	self.containerView.overrideUserInterfaceStyle = targetStyle;
	%orig;
}

%end

// 3. 毛玻璃背景板防御：杜绝浅色毛玻璃被创建和绘制
%hook PRXCardBackgroundView

- (instancetype)initWithFrame:(CGRect)frame {
	self = %orig(frame);
	if (self) {
		self.overrideUserInterfaceStyle = PGS_CurrentSystemStyle();
	}
	return self;
}

- (void)didMoveToWindow {
	%orig;
	if (self.window) {
		self.overrideUserInterfaceStyle = PGS_CurrentSystemStyle();
	}
}

%end

// 4. 外层容器防御
%hook PRXCardContainerView

- (instancetype)initWithFrame:(CGRect)frame {
	self = %orig(frame);
	if (self) {
		self.overrideUserInterfaceStyle = PGS_CurrentSystemStyle();
	}
	return self;
}

- (void)didMoveToWindow {
	%orig;
	if (self.window) {
		self.overrideUserInterfaceStyle = PGS_CurrentSystemStyle();
	}
}

%end

// 5. 内容层与触觉反馈
%hook PRXCardContentView

- (instancetype)initWithFrame:(CGRect)frame {
	self = %orig(frame);
	if (self) {
		self.overrideUserInterfaceStyle = PGS_CurrentSystemStyle();
	}
	return self;
}

- (void)didMoveToWindow {
	%orig;
	if (self.window) {
		self.overrideUserInterfaceStyle = PGS_CurrentSystemStyle();
		// 弹窗登场瞬间伴随轻微清脆的 Taptic Engine 线性马达震动
		PGS_TriggerHapticFeedback();
	}
}

- (void)setTitleView:(PRXTextView *)titleView {
	%orig;
	if (titleView && [titleView respondsToSelector:@selector(setTitleText:)]) {
		// iOS 17 风格加粗标题
		[titleView setTitleText:titleView.text];
	}
}

%end

// 6. 配置层从实例化 init 开始预置支持深色模式
%hook PRXFlowConfiguration

- (instancetype)init {
	self = %orig;
	if (self) {
		[self setSupportsDarkMode:YES];
	}
	return self;
}

- (void)setSupportsDarkMode:(BOOL)arg1 {
	%orig(YES);
}

- (BOOL)supportsDarkMode {
	return YES;
}

%end

%end

%dtor {
	if (g_unlock_token != 0) {
		notify_cancel(g_unlock_token);
		g_unlock_token = 0;
	}
	if (settings) {
		PGS_freeSettings(settings);
		settings = NULL;
	}
}

%ctor {
	char exec_path[512] = {0};
	uint32_t len = sizeof(exec_path);
	_NSGetExecutablePath(exec_path, &len);

	// 1. 若注入目标为弹窗渲染服务 (SharingViewService)，激活完全消除白闪的深色模式与触觉反馈
	if (strstr(exec_path, "SharingViewService") != NULL) {
		%init(darkpods_hook_grp);
		return; // 立即返回！绝不在弹窗进程中进行多余的文件读写或通知监听，释放 100% 主线程算力
	}

	// 2. 仅对非 bluetoothd 进程（如 sharingd, SpringBoard）初始化
	if (memcmp(exec_path, "/usr/sbin/bluetoothd", 21) != 0) {
		PGS_initOSVersion();
		reload_settings_if_needed();

		notify_register_dispatch("com.apple.mobile.keybagd.first_unlock", &g_unlock_token, dispatch_get_main_queue(), ^(int token) {
			reload_settings_if_needed();
		});

		%init(sharing_hook_grp);
	}
}
