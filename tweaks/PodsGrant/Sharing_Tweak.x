#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <mach-o/dyld.h>
#include <notify.h>
#include "general.h"

@interface PRXTextView : UITextView
- (void)setTitleText:(id)titleView;
@end

@interface PRXCardContentView : UIView
@end

@interface PRXFlowConfiguration : NSObject
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
// iOS 16 专属质感：全天候纯黑卡片 + Taptic Engine 开盖轻触反馈
// ==========================================
%group darkpods_hook_grp

static NSTimeInterval s_last_haptic_time = 0;

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

%hook PRXCardContentView

- (void)didMoveToWindow {
	%orig;
	if (self.window) {
		// 1. 强制全天候深色卡片：无论系统处于白天浅色还是夜间深色，弹窗均保持高级黑
		self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
		// 2. 弹窗登场瞬间伴随轻微清脆的 Taptic Engine 线性马达震动
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

%hook PRXFlowConfiguration

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

	// 1. 若注入目标为弹窗渲染服务 (SharingViewService)，激活极简深色模式与 Taptic 触觉反馈
	if (strstr(exec_path, "SharingViewService") != NULL) {
		%init(darkpods_hook_grp);
	}

	// 2. 仅对非 bluetoothd 进程（如 sharingd, SharingViewService, SpringBoard）初始化
	if (memcmp(exec_path, "/usr/sbin/bluetoothd", 21) != 0) {
		PGS_initOSVersion();
		reload_settings_if_needed();

		notify_register_dispatch("com.apple.mobile.keybagd.first_unlock", &g_unlock_token, dispatch_get_main_queue(), ^(int token) {
			reload_settings_if_needed();
		});

		%init(sharing_hook_grp);
	}
}
