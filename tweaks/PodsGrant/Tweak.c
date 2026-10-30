#include <stdio.h>
#include <string.h>
#include <substrate.h>
#include <mach-o/dyld.h>
#include <sys/sysctl.h>
#include "os_log_handler.h"
#include "general.h"

static unsigned int product_id_offset;
static struct podsgrant_settings *settings = NULL;

unsigned int (*orig_1002E1F9C)(void *a1, void *a2, void *a3, void *a4, void *a5);
unsigned int my_1002E1F9C(void *a1, void *a2, void *a3, void *a4, void *a5) {
	if (a1 && product_id_offset) {
		uint32_t current_id = *(uint32_t *)((uint8_t *)a1 + product_id_offset);
		uint16_t patched = PGS_patchProductId(settings, (uint16_t)current_id);
		if (patched) {
			*(uint32_t *)((uint8_t *)a1 + product_id_offset) = (uint32_t)patched;
		}
	}
	return orig_1002E1F9C(a1, a2, a3, a4, a5);
}

unsigned int (*abilityFuncOrig)(void *, unsigned int abilityID);
unsigned int abilityFunc(void *a1, unsigned int abilityID) {
	if (a1 && product_id_offset) {
		uint32_t current_id = *(uint32_t *)((uint8_t *)a1 + product_id_offset);
		uint16_t patched = PGS_patchProductId(settings, (uint16_t)current_id);
		if (patched) {
			*(uint32_t *)((uint8_t *)a1 + product_id_offset) = (uint32_t)patched;
		}
		if (*(uint32_t *)((uint8_t *)a1 + product_id_offset) == 0x200E) { // 8206 (AirPods Pro)
			if (abilityID == 12 || abilityID == 26) {
				return 1;
			}
		}
	}
	return abilityFuncOrig(a1, abilityID);
}

void *(*supportRemoteVolumeChangeOriginal)(void*, int);
void *supportRemoteVolumeChange(void *a1, int support) {
	// 强制上报支持远程音量手势控制 (耳机柄滑动调节音量)
	return supportRemoteVolumeChangeOriginal(a1, 1);
}

__attribute__((destructor))
static void __podsgrant_main_teardown(void) {
	if (settings) {
		PGS_freeSettings(settings);
		settings = NULL;
	}
}

__attribute__((constructor))
static void __podsgrant_main_construct(void) {
	char exec_path[512] = {0};
	uint32_t len = sizeof(exec_path);
	_NSGetExecutablePath(exec_path, &len);
	if (memcmp(exec_path, "/usr/sbin/bluetoothd", 21) != 0) {
		return;
	}

	PGS_initOSVersion();
	settings = PGS_readSettings(0);

	uint64_t all_addr[3] = {0};
	int found = PGS_findAddresses(all_addr, &product_id_offset);
	if (!found) return;

	uint64_t bin_vmaddr_slide = 0;
#ifndef IS_ROOTLESS
	bin_vmaddr_slide = _dyld_get_image_vmaddr_slide(0);
#else
	int image_count = _dyld_image_count();
	for (int i = 0; i < image_count; i++) {
		const char *img_name = _dyld_get_image_name(i);
		if (img_name && memcmp(img_name, "/usr/sbin/bluetoothd", 20) == 0) {
			bin_vmaddr_slide = _dyld_get_image_vmaddr_slide(i);
			break;
		}
	}
#endif

	if (all_addr[0]) {
		MSHookFunction((void *)(bin_vmaddr_slide + all_addr[0]), (void *)&my_1002E1F9C, (void **)&orig_1002E1F9C);
	}
	if (all_addr[1]) {
		MSHookFunction((void *)(bin_vmaddr_slide + all_addr[1]), (void *)&abilityFunc, (void **)&abilityFuncOrig);
	}
	if (all_addr[2]) {
		MSHookFunction((void *)(bin_vmaddr_slide + all_addr[2]), (void *)&supportRemoteVolumeChange, (void **)&supportRemoteVolumeChangeOriginal);
	}
}
