#pragma once
#include <stdint.h>
#include <stdio.h>

struct address_map_entry {
	unsigned char version_major;
	unsigned char version_minor;
	unsigned char version_patch;
	unsigned int product_id_offset;
	uint64_t first_hook_addr;
	uint64_t ability_func_addr;
	uint64_t support_remote_volume_change_addr;
	uint64_t recv_logging_handler_addr;
};

struct product_id_map_entry_custom {
	uint16_t original;
	uint16_t target;
};

struct product_id_map_entry {
	uint16_t original;
	uint16_t target;
	uint8_t  minimum_ios;
	uint8_t  maximum_ios;
	// [minimum_ios, maximum_ios] 闭区间
};

// 预设产品映射表
static const struct product_id_map_entry product_id_map_preset[] = {
	{8212, 8206, 0, 15},   // AirPods Pro 2 Lightning -> AirPods Pro (iOS <= 15)
	{8217, 8207, 0, 255},  // Beats Fit Pro -> AirPods 2
	{8219, 8206, 0, 15},   // AirPods 4 -> AirPods Pro (iOS <= 15)
	{8228, 8206, 0, 15},   // AirPods Pro 2 USB-C -> AirPods Pro (iOS <= 15)
	{8231, 8206, 0, 15},   // AirPods Pro 3 / Max Refreshed -> AirPods Pro (iOS <= 15)
	{8232, 8206, 0, 15},   // AirPods Pro 3 / ANC -> AirPods Pro (iOS <= 15)
	{8228, 8212, 16, 255}, // AirPods Pro 2 USB-C -> AirPods Pro 2 Lightning (iOS >= 16)
	{8219, 8212, 16, 255}, // AirPods 4 -> AirPods Pro 2 Lightning (iOS >= 16)
	{8231, 8212, 16, 255}, // AirPods Pro 3 -> AirPods Pro 2 Lightning (iOS >= 16)
	{8232, 8212, 16, 255}, // AirPods Pro 3 -> AirPods Pro 2 Lightning (iOS >= 16)
	{8221, 8203, 0, 16},   // Beats Studio Buds Plus -> Powerbeats Pro
	{8211, 8207, 0, 255},  // AirPods 3 -> AirPods 2
	{8214, 8209, 0, 255},  // Beats Studio Buds -> Beats Solo Pro
	{0, 0, 0, 0}
};

struct podsgrant_settings {
	uint8_t is_tweak_enabled;
	uint8_t is_managed_structure;
	struct product_id_map_entry_custom *product_id_mapping;
	struct address_map_entry *address_mapping;
	uint8_t product_id_mapping_cnt;
	uint8_t address_mapping_cnt;
};

#define NSSTR(a) @a
#define PGS_SETTINGS_FILE "/var/mobile/Library/Preferences/com.lns.pogr.bin"

extern unsigned char PGS_global_os_ver;

// 初始化系统版本号（保证各进程均能获取真实系统版本）
void PGS_initOSVersion(void);

// 查询并替换产品 PID
uint16_t PGS_patchProductId(struct podsgrant_settings *conf, uint16_t original);

// 配置存储与管理
int PGS_saveSettings(struct podsgrant_settings *configuration);
struct podsgrant_settings *PGS_readSettings_to(struct podsgrant_settings *configuration, int read_full_anyway);
struct podsgrant_settings *PGS_readSettings(int read_full_anyway);
void PGS_freeSettings(struct podsgrant_settings *conf);

// 动态汇编指令掩码地址解算
int PGS_findAddresses(uint64_t *addresses, uint32_t *pid_offset);
