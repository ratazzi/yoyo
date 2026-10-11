#include "timezone-display.h"
#include <stdint.h>
#include <string.h>

// macOS exports ICU through libicucore without shipping its public C headers.
extern int32_t ucal_getCanonicalTimeZoneID(const uint16_t *, int32_t, uint16_t *, int32_t, int8_t *, int32_t *);

int timezone_display_canonicalize(const char *identifier, char *result, size_t capacity) {
    uint16_t input[256], output[256];
    size_t length = strlen(identifier);
    if (!length || length >= 256 || !capacity) return 0;
    for (size_t i = 0; i < length; i++) {
        if ((unsigned char)identifier[i] > 127) return 0;
        input[i] = (uint16_t)(unsigned char)identifier[i];
    }
    int32_t error = 0; int8_t system = 0;
    int32_t count = ucal_getCanonicalTimeZoneID(input, (int32_t)length, output, 256, &system, &error);
    if (error > 0 || !system || count <= 0 || count >= 256 || (size_t)count >= capacity) return 0;
    for (int32_t i = 0; i < count; i++) {
        if (output[i] > 127) return 0;
        result[i] = (char)output[i];
    }
    result[count] = 0;
    return 1;
}
