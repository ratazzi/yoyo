#pragma once
void timezone_trace_configure(void);
// 1 means acknowledged; 0 means unconfirmed, not an injection failure.
int timezone_trace_startup(const char *zone);
void timezone_trace_call(const char *operation, const char *zone);
