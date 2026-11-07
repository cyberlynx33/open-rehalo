// halo-display: the SmartHalo 2's display firmware (LED ring, OLED, front light, buzzer) on a
// computer, driven over stdin/stdout.
//
//   halo-display [--batch] [--from-boot]
//
// It says READY once the ring is booted and the app connected (about 11 s of firmware time, run at
// once), or, with --from-boot, at power-on with no app connected. Lines in:
//
//   C <hex>      a BLE command as the app sends it: [service, command, payload…]
//   K 0|1        the app disconnects / connects
//   T <code> <n> n taps on the ring; bit i of code = tap i was long
//   S 0|1        a swipe to the left / right
//   M 0|1        the bike stops / moves (the accelerometer)
//   W <ms>       --batch only: let that much time pass (otherwise time is the wall clock)
//   Q            quit
//
// Lines out, each with the firmware's tick (ms since boot):
//
//   L <t> <hex>  the 24 LEDs, 72 RGB bytes, as the animations hand them to the LED driver
//   O <t> <hex>  the display's memory, 1024 bytes: 8 pages of 128 columns, bit 0 at the top
//   P <t> <on> <contrast> <brightness>   the display turned on or off, its settings
//   F <t> <pct>  the front light
//   N <t> <hz> <volume> <on>             the buzzer
//   R <t> <hex>  a reply to a command; U <t> <hex>: an unsolicited notification
//   G <t> <text> the firmware's log
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <time.h>
#include <unistd.h>

#include "sim.h"

void init_GraphicsTask(void);
void init_SoundTask(void);
void init_PersonalityTask(void);
void init_NightLightTask(void);
void init_RideTask(void);
void init_AlarmTask(void);

#define BOOT_MS 7000      // the start-up screen
#define CONNECT_MS 6000   // the connected screen

void sim_out(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    putchar('\n');
}

void sim_out_hex(char kind, const uint8_t *bytes, uint32_t length) {
    printf("%c %u ", kind, sim_now());
    for (uint32_t i = 0; i < length; i++) printf("%02x", bytes[i]);
    putchar('\n');
}

static int hexValue(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static void advance(uint32_t ms) {
    for (uint32_t i = 0; i < ms; i++) {
        sim_tick();
        sim_devices_flush();
    }
    fflush(stdout);
}

// Returns false on Q.
static bool handleLine(char *line, bool batch) {
    size_t n = strlen(line);
    while (n && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = 0;
    if (!n) return true;
    switch (line[0]) {
    case 'C': {
        uint8_t bytes[256];
        uint16_t length = 0;
        for (char *p = line + 1; *p && length < sizeof bytes;) {
            if (*p == ' ' || *p == ',') { p++; continue; }
            int hi = hexValue(p[0]), lo = hexValue(p[1]);
            if (hi < 0 || lo < 0) break;
            bytes[length++] = (uint8_t)(hi << 4 | lo);
            p += 2;
        }
        sim_comm_receive(bytes, length);
        sim_run_ready();
        sim_devices_flush();
        break;
    }
    case 'K':
    case 'T':
    case 'S':
    case 'M': {
        char *rest;
        long a = strtol(line + 1, &rest, 0), b = strtol(rest, NULL, 0);
        if (line[0] == 'K') sim_comm_connection(a != 0);
        if (line[0] == 'T') sim_sensors_tap((uint8_t)a, (uint8_t)b);
        if (line[0] == 'S') sim_sensors_swipe(a != 0);
        if (line[0] == 'M') sim_sensors_motion(a != 0);
        sim_run_ready();
        sim_devices_flush();
        break;
    }
    case 'W':
        if (batch) advance((uint32_t)strtoul(line + 1, NULL, 10));
        break;
    case 'Q':
        return false;
    }
    fflush(stdout);
    return true;
}

static uint64_t monotonicMs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

int main(int argc, char **argv) {
    bool batch = false, fromBoot = false;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--batch")) batch = true;
        else if (!strcmp(argv[i], "--from-boot")) fromBoot = true;
    }
    setvbuf(stdout, NULL, _IOFBF, 1 << 16);

    sim_init();
    sim_comm_init();
    sim_sensors_init();
    sim_system_init();
    init_GraphicsTask();
    init_SoundTask();
    init_PersonalityTask();
    init_NightLightTask();
    init_RideTask();
    init_AlarmTask();
    sim_run_ready();
    sim_devices_flush();
    // As the app finds a ring: booted (the start-up screen holds the animations for about 6 s) and
    // then connected (the connected screen, about 5 s). --from-boot starts at power-on instead, with
    // no app connected.
    if (!fromBoot) {
        advance(BOOT_MS);
        sim_comm_connection(true);
        advance(CONNECT_MS);
    }
    printf("READY\n");
    fflush(stdout);

    static char line[4096];
    if (batch) {
        while (fgets(line, sizeof line, stdin)) {
            if (!handleLine(line, true)) break;
        }
        return 0;
    }

    // Real time: the tick follows the wall clock, and commands apply on the tick they arrive.
    uint64_t start = monotonicMs() - sim_now();
    size_t used = 0;
    for (;;) {
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(STDIN_FILENO, &fds);
        struct timeval tv = {0, 2000};
        if (select(STDIN_FILENO + 1, &fds, NULL, NULL, &tv) > 0) {
            ssize_t got = read(STDIN_FILENO, line + used, sizeof line - 1 - used);
            if (got == 0 || (got < 0 && errno != EINTR)) return 0;   // the parent is gone
            used += got > 0 ? (size_t)got : 0;
            line[used] = 0;
            char *end;
            while ((end = strchr(line, '\n'))) {
                *end = 0;
                if (!handleLine(line, false)) return 0;
                used -= (size_t)(end + 1 - line);
                memmove(line, end + 1, used + 1);
            }
            if (used == sizeof line - 1) used = 0;   // a line too long to be a command
        }
        uint64_t due = monotonicMs() - start;
        if (due > sim_now()) advance((uint32_t)(due - sim_now() > 1000 ? 1000 : due - sim_now()));
    }
}
