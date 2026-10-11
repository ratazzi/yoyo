#pragma once
#include <stddef.h>
// Canonicalize a display name through the system ICU database without changing TZ.
int timezone_display_canonicalize(const char *identifier, char *result, size_t capacity);
