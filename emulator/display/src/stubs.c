// The rest of the firmware the display code calls into, reduced to a ring on a desk: awake, paired,
// not charging, at a fixed battery level. (Touch and motion are in sensors.c.)
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "main.h"
#include "sim.h"

char *itoa(int value, char *str, int base) {
    char tmp[34];
    unsigned int v = value < 0 && base == 10 ? (unsigned int)-value : (unsigned int)value;
    int i = 0;
    do {
        int d = v % base;
        tmp[i++] = (char)(d < 10 ? '0' + d : 'a' + d - 10);
        v /= base;
    } while (v);
    int j = 0;
    if (value < 0 && base == 10) str[j++] = '-';
    while (i) str[j++] = tmp[--i];
    str[j] = 0;
    return str;
}

size_t sim_strlcpy(char *dst, const char *src, size_t size) {
    size_t n = strlen(src);
    if (size) {
        size_t c = n < size - 1 ? n : size - 1;
        memcpy(dst, src, c);
        dst[c] = 0;
    }
    return n;
}

int log_Shell(const char *format, ...) {
    char text[512];
    va_list ap;
    va_start(ap, format);
    vsnprintf(text, sizeof text, format, ap);
    va_end(ap);
    for (char *p = text; *p; p++) if (*p == '\n' || *p == '\r') *p = ' ';
    sim_out("G %u %s", sim_now(), text);
    return 0;
}

void soft_crash(uint32_t arg) {
    sim_out("G %u soft crash 0x%08x", sim_now(), arg);
}

void Error_Handler(void) {}
void HAL_Delay(uint32_t ms) { vTaskDelay(ms); }

// ---- SystemUtilitiesTask ---------------------------------------------------------------------

#include "AnimationsLibrary.h"
#include "GraphicsTask.h"
#include "SystemUtilitiesTask.h"
#include "WatchdogTask.h"
#include "CommunicationTask.h"
#include "BootLoaderImport.h"
#include "reboot.h"

const char pairedFile[] = "PairedState";

static uint8_t stateOfCharge = 80;

// The LED half of the original: the ring shows the charge. (The original also draws a battery on the
// display, from SystemUtilitiesTask.c's own image, which the simulator doesn't build.)
void displayStateOfCharge_SystemUtilities(bool showIdle) {
    struct StateOfChargeAnimationData data = {.stateOfCharge = stateOfCharge, .charging = false, .showIdle = showIdle};
    startAnimation_GraphicsTask(HaloAnimation_display_stateOfCharge, (uint8_t *)&data);
}

uint8_t getStateOfCharge_SystemUtilities(void) { return stateOfCharge; }
EResetType_t getResetType_SystemUtilities(void) { return eResetType_Normal; }
eRebootReason_t getRebootReason_SystemUtilities(void) { return eRebootNormal; }
bool getIsChargingAnimationAllowed_SystemUtilities(void) { return false; }
bool getIsPlugged_SystemUtilities(void) { return false; }
bool getIsPaired_SystemUtilities(void) { return true; }
bool isTestMode_SystemUtilities(void) { return false; }
bool waitForFS_SystemUtilities(const char *filename) { return true; }
// Millivolts (PersonalityTask draws nothing under 3300).
float getRawBatteryVoltage_SystemUtilities(void) { return 3900.0f; }

// The display's language, which the app sets with the date ({4,6}).
static Localization_E locale = english;
Localization_E getLocale_SystemUtilities(void) { return locale; }
void setLocale_SystemUtilities(Localization_E newLocale) { locale = newLocale; }

// {4,6}, as SystemUtilitiesTask answers it: an 8-byte time, then optionally a 2-letter language. The
// simulator keeps no calendar (the app sends the clock it shows), only the language.
static void setDate(uint16_t length, uint8_t *payload) {
    if (length != 8 && length != 10) {
        genericResponse_CommunicationTask(eCOM_RETURN_STATUS_FAIL);
        return;
    }
    if (length == 10) {
        const char *l = (const char *)&payload[8];
        locale = !strncmp(l, "fr", 2) ? french : !strncmp(l, "es", 2) ? spanish : !strncmp(l, "de", 2) ? german : english;
    }
    genericResponse_CommunicationTask(eCOM_RETURN_STATUS_OK);
}

void sim_system_init(void) { assignFunction_CommunicationTask(COM_DEVICE, DEVICE_SETDATE, setDate); }
void setLightSetting_SystemUtilities(bool isReady) {}
void setLightState_SystemUtilities(bool isShowing) {}

// The flash file system, in memory: settings survive until the simulator quits.
#define MAX_FILES 32
static struct { char name[32]; uint8_t data[256]; size_t length; } files[MAX_FILES];
static int fileCount;

bool readFile_SystemUtilities(const char *fileName, void *buf, size_t length) {
    for (int i = 0; i < fileCount; i++) {
        if (strcmp(files[i].name, fileName)) continue;
        if (files[i].length < length) return false;
        memcpy(buf, files[i].data, length);
        return true;
    }
    return false;
}

bool writeFile_SystemUtilities(const char *fileName, void *buf, size_t length) {
    if (length > sizeof files[0].data) return false;
    int i = 0;
    while (i < fileCount && strcmp(files[i].name, fileName)) i++;
    if (i == fileCount) {
        if (fileCount == MAX_FILES) return false;
        strlcpy(files[fileCount++].name, fileName, sizeof files[0].name);
    }
    memcpy(files[i].data, buf, length);
    files[i].length = length;
    return true;
}

// ---- the rest: board, power, watchdog, timers registry ----------------------------------------

// The bootloader's flags, kept across reboots in RAM on the ring: a normal first boot here.
static BootFlags_t bootFlags = {.normalReboot = 1};
BootFlags_t *BF = &bootFlags;

uint8_t get_BoardRev(void) { return 5; }
void stayAwake_Power(const char *calledFrom) {}
void sleepAllowed_Power(bool canSleep, const char *func) {}
void shwd_KeepAlive(ESHWD_Bits_t task) {}
void storeTimer(TimerHandle_t timer) {}
