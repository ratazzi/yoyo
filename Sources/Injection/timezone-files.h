#pragma once
// Installs a read-only per-process view; never changes host files or symlinks.
int timezone_files_configure(const char *zone);
const char *timezone_files_path(void);
const char *timezone_files_replacement(int directory, const char *path);
