// Included before every file: the simulator builds the firmware for a computer.
#ifndef SIM_PRELUDE_H
#define SIM_PRELUDE_H

// AnimationsLibrary.c writes each LED through a bounds-checked statement expression that only GCC
// accepts as an lvalue; with this it writes the array directly, which is the same for valid indices.
#define WWDG_FOUND 1

#include <stddef.h>

// newlib's itoa and strlcpy, which the firmware uses (src/stubs.c). strlcpy goes by another name, as
// macOS's libc has its own (a macro under _FORTIFY_SOURCE) and glibc's only from 2.38.
char *itoa(int value, char *str, int base);
size_t sim_strlcpy(char *dst, const char *src, size_t size);
#define strlcpy sim_strlcpy

#endif
