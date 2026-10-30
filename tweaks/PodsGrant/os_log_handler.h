#pragma once
#include <stdio.h>
#include <stdint.h>

void format_os_log(FILE *log_file, void *log_ent, const char *format, uint8_t *buf, uint32_t size, int is_string_only);
