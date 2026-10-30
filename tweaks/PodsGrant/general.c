#include "general.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

unsigned char PGS_global_os_ver = 0;

void PGS_initOSVersion(void) {
	if (PGS_global_os_ver != 0) return;
	char os_ver_buf[32] = {0};
	size_t os_ver_len = sizeof(os_ver_buf) - 1;
	if (sysctlbyname("kern.osproductversion", os_ver_buf, &os_ver_len, NULL, 0) == 0) {
		for (char *ptr = os_ver_buf; *ptr != 0; ptr++) {
			if (*ptr == '.') {
				*ptr = 0;
				break;
			}
		}
		PGS_global_os_ver = (unsigned char)atoi(os_ver_buf);
	}
	if (PGS_global_os_ver == 0) {
		PGS_global_os_ver = 15; // 默认回退值
	}
}

int PGS_saveSettings(struct podsgrant_settings *configuration) {
	FILE *config_file = fopen(PGS_SETTINGS_FILE, "wb");
	if (!config_file) return -1;
	fputc(configuration->is_tweak_enabled, config_file);
	fputc(configuration->product_id_mapping_cnt, config_file);
	if (configuration->product_id_mapping_cnt && configuration->product_id_mapping) {
		fwrite(configuration->product_id_mapping, sizeof(struct product_id_map_entry_custom), configuration->product_id_mapping_cnt, config_file);
	}
	fputc(configuration->address_mapping_cnt, config_file);
	if (configuration->address_mapping_cnt && configuration->address_mapping) {
		fwrite(configuration->address_mapping, sizeof(struct address_map_entry), configuration->address_mapping_cnt, config_file);
	}
	if (ferror(config_file) != 0) {
		fclose(config_file);
		remove(PGS_SETTINGS_FILE);
		return -3;
	}
	fclose(config_file);
	return 0;
}

struct podsgrant_settings *PGS_readSettings_to(struct podsgrant_settings *configuration, int read_full_anyway) {
	PGS_initOSVersion();
	configuration->is_managed_structure = 0;
	configuration->product_id_mapping_cnt = 0;
	configuration->address_mapping_cnt = 0;
	configuration->product_id_mapping = NULL;
	configuration->address_mapping = NULL;

	FILE *config_file = fopen(PGS_SETTINGS_FILE, "rb");
	if (!config_file) {
		// 未解锁或尚未创建配置时，默认开启插件并启用内置预设
		configuration->is_tweak_enabled = 1;
		return configuration;
	}

	int enabled = fgetc(config_file);
	if (enabled == EOF) {
		fclose(config_file);
		configuration->is_tweak_enabled = 1;
		return configuration;
	}
	configuration->is_tweak_enabled = (uint8_t)enabled;

	if (!configuration->is_tweak_enabled && !read_full_anyway) {
		fclose(config_file);
		return configuration;
	}

	int product_id_mapping_entries = fgetc(config_file);
	if (product_id_mapping_entries != EOF && product_id_mapping_entries > 0) {
		configuration->product_id_mapping_cnt = (uint8_t)product_id_mapping_entries;
		configuration->product_id_mapping = malloc(product_id_mapping_entries * sizeof(struct product_id_map_entry_custom));
		if (configuration->product_id_mapping) {
			size_t read_bytes = fread(configuration->product_id_mapping, sizeof(struct product_id_map_entry_custom), product_id_mapping_entries, config_file);
			if (read_bytes != (size_t)product_id_mapping_entries) {
				free(configuration->product_id_mapping);
				configuration->product_id_mapping = NULL;
				configuration->product_id_mapping_cnt = 0;
			}
		}
	}

	int addr_mapping_entries = fgetc(config_file);
	if (addr_mapping_entries != EOF && addr_mapping_entries > 0) {
		configuration->address_mapping_cnt = (uint8_t)addr_mapping_entries;
		configuration->address_mapping = malloc(addr_mapping_entries * sizeof(struct address_map_entry));
		if (configuration->address_mapping) {
			size_t read_bytes = fread(configuration->address_mapping, sizeof(struct address_map_entry), addr_mapping_entries, config_file);
			if (read_bytes != (size_t)addr_mapping_entries) {
				free(configuration->address_mapping);
				configuration->address_mapping = NULL;
				configuration->address_mapping_cnt = 0;
			}
		}
	}

	fclose(config_file);
	return configuration;
}

struct podsgrant_settings *PGS_readSettings(int read_full_anyway) {
	struct podsgrant_settings *configuration = malloc(sizeof(struct podsgrant_settings));
	if (!configuration) return NULL;
	configuration->is_managed_structure = 1;
	return PGS_readSettings_to(configuration, read_full_anyway);
}

void PGS_freeSettings(struct podsgrant_settings *conf) {
	if (!conf) return;
	if (conf->product_id_mapping) {
		free(conf->product_id_mapping);
		conf->product_id_mapping = NULL;
	}
	if (conf->address_mapping) {
		free(conf->address_mapping);
		conf->address_mapping = NULL;
	}
	if (conf->is_managed_structure) {
		free(conf);
	}
}

uint16_t PGS_patchProductId(struct podsgrant_settings *conf, uint16_t original) {
	if (conf && conf->product_id_mapping && conf->product_id_mapping_cnt > 0) {
		for (struct product_id_map_entry_custom *entry = conf->product_id_mapping;
		     entry < conf->product_id_mapping + conf->product_id_mapping_cnt;
		     entry++) {
			if (entry->original == original) {
				return entry->target;
			}
		}
	}
	// 查询预设表
	PGS_initOSVersion();
	for (const struct product_id_map_entry *entry = product_id_map_preset; entry->original != 0; entry++) {
		if (PGS_global_os_ver > entry->maximum_ios || PGS_global_os_ver < entry->minimum_ios) {
			continue;
		}
		if (entry->original == original) {
			return entry->target;
		}
	}
	return 0;
}

static uint32_t match_arr_1[] = {
	0xffc003e0, 0x39400000,
	0xff000000, 0x34000000,
	0xffc003e0, 0xb9400000,
	0xffc003e0, 0xb9000020,
	0xffc003e0, 0xb9400000,
	0xffc003e0, 0xb9000040,
	0xffc003e0, 0xb9400000,
	0xffc003e0, 0xb9000060,
	0xffc003e0, 0xb9400000,
	0xffc003e0, 0xb9000080
};

static uint32_t match_arr_2[] = {
	0xffc003e0, 0xb9400000,
	0xfffffc1f, 0x7101301f,
	0xff00001f, 0x54000001,
	0xffc00000, 0xb9400000,
	0xffffffe0, 0x12840020,
	0xff000000, 0x0b000000,
	0xfffffc1f, 0x7100441f
};

static uint32_t match_arr_3[] = {
	0x9f000000, 0x90000000,
	0xffc00000, 0xf9400000,
	0x9f000000, 0x90000000,
	0xffc00000, 0xf9400000,
	0xffffffff, 0x7100003f,
	0xffe0fc00, 0x9a801000,
	0xfffffc1f, 0xf9400002,
	0x9f00001f, 0x90000001,
	0xff8003ff, 0x91000021,
	0xfc000000, 0x14000000
};

static int match_instructions(uint32_t *out, size_t osz, uint32_t *target, size_t tsz, FILE *bin) {
	fseek(bin, 0, SEEK_SET);
	int total_cnt = 0;
	size_t match_cnt = 0;
	unsigned int val;
	while (fread(&val, 1, 4, bin) == 4) {
		if ((target[match_cnt * 2] & val) == target[match_cnt * 2 + 1]) {
			match_cnt++;
			if (match_cnt == tsz / 8) {
				out[total_cnt] = (uint32_t)(ftell(bin) - (long)(tsz / 2));
				total_cnt++;
				if (total_cnt == (int)osz) break;
				match_cnt = 0;
			}
		} else {
			match_cnt = 0;
		}
	}
	return total_cnt;
}

int PGS_findAddresses(uint64_t *addresses, uint32_t *product_id_offset) {
	FILE *bin = fopen("/usr/sbin/bluetoothd", "rb");
	if (!bin) return 0;

	uint32_t results[16];
	int first_match_cnt = match_instructions(results, 16, match_arr_1, sizeof(match_arr_1), bin);
	if (first_match_cnt != 1) {
		fclose(bin);
		return 0;
	}
	addresses[0] = (uint64_t)results[0] + 0x100000000ULL;
	if (product_id_offset) {
		uint32_t product_id_ldr = 0;
		fseek(bin, results[0] + 6 * 4, SEEK_SET);
		fread(&product_id_ldr, 1, 4, bin);
		*product_id_offset = ((product_id_ldr >> 10) & ((1 << 12) - 1)) << 2;
	}

	int second_match_cnt = match_instructions(results, 16, match_arr_2, sizeof(match_arr_2), bin);
	if (second_match_cnt != 1) {
		fclose(bin);
		return 0;
	}
	fseek(bin, results[0] - 4, SEEK_SET);
	uint32_t pre_ldr_inst2 = 0;
	fread(&pre_ldr_inst2, 1, 4, bin);
	if ((pre_ldr_inst2 & 0xffe0ffe0) == 0xaa0003e0) {
		results[0] -= 4;
	}
	addresses[1] = (uint64_t)results[0] + 0x100000000ULL;
	addresses[2] = 0;

	int third_match_cnt = match_instructions(results, 16, match_arr_3, sizeof(match_arr_3), bin);
	for (int i = 0; i < third_match_cnt; i++) {
		fseek(bin, results[i] + 7 * 4, SEEK_SET);
		unsigned int adrp_and_add[2] = {0};
		fread(adrp_and_add, 1, 8, bin);
		uint64_t adrp = adrp_and_add[0];
		uint64_t addr = (((adrp >> 5) & ((1 << 19) - 1)) << 14) | (((adrp >> 29) & 3) << 12);
		addr += (results[i] >> 12) << 12;
		addr += (adrp_and_add[1] >> 10) & 0xfff;
		fseek(bin, addr, SEEK_SET);
		char buf[45] = {0};
		fread(buf, 1, 44, bin);
		if (strcmp(buf, "kBTAudioMsgPropertySupportRemoteVolumeChange") == 0) {
			addresses[2] = (uint64_t)results[i] + 0x100000000ULL;
			break;
		}
	}

	fclose(bin);
	return 1;
}
