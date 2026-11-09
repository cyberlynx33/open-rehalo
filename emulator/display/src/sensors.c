// Stand-in for SensorsTask.c: the touch pad, the accelerometer and the light sensor. Taps, swipes and
// motion come from main.c and reach the firmware's subscribers the way SensorsTask delivers them
// (a task holding the lock gets them alone, and an unlocked tap code is also notified to the app).
#include <string.h>

#include "CommunicationTask.h"
#include "SHTaskUtils.h"
#include "SensorsTask.h"
#include "sim.h"

#define LIMIT 8

typedef void (*TapFn)(uint8_t code, uint8_t len, bool adjusted);
typedef void (*SwipeFn)(touch_swipe_state_t state);
typedef void (*ReleaseFn)(bool released);
typedef void (*AccFn)(void);
typedef void (*AccDataFn)(float *x, float *y, float *z);
typedef void (*LightFn)(uint16_t *magnitude);

static TapFn taps[LIMIT], tapLock;
static SwipeFn swipes[LIMIT], swipeLock;
static ReleaseFn releases[LIMIT];
static AccFn accInterrupts[LIMIT];
static AccDataFn accData[LIMIT];
static LightFn lights[LIMIT];
static uint8_t tapCount, swipeCount, releaseCount, accCount, accDataCount, lightCount;
static char tapLockName[32], swipeLockName[32];

#define ADD(list, count, fn) do { if ((count) < LIMIT) (list)[(count)++] = (fn); } while (0)
#define REMOVE(list, count, fn) do { \
        for (int i_ = 0; i_ < (count); i_++) if ((list)[i_] == (fn)) { \
            memmove(&(list)[i_], &(list)[i_ + 1], ((count) - i_ - 1) * sizeof (list)[0]); (count)--; break; } \
    } while (0)

void subscribeToTaps_SensorsTask(TapFn fn) { ADD(taps, tapCount, fn); }
void unsubscribeToTaps_SensorsTask(TapFn fn) { REMOVE(taps, tapCount, fn); }
void subscribeToSwipes_SensorsTask(SwipeFn fn) { ADD(swipes, swipeCount, fn); }
void unsubscribeToSwipes_SensorsTask(SwipeFn fn) { REMOVE(swipes, swipeCount, fn); }
void subscribeToRelease_SensorsTask(ReleaseFn fn) { ADD(releases, releaseCount, fn); }
void unsubscribeToRelease_SensorsTask(ReleaseFn fn) { REMOVE(releases, releaseCount, fn); }
void subscribeToAccInterrupt_SensorsTask(AccFn fn) { ADD(accInterrupts, accCount, fn); }
void unsubscribeToAccInterrupt_SensorsTask(AccFn fn) { REMOVE(accInterrupts, accCount, fn); }
void subscribeToAccData_SensorsTask(AccDataFn fn) { ADD(accData, accDataCount, fn); }
void unsubscribeToAccData_SensorsTask(AccDataFn fn) { REMOVE(accData, accDataCount, fn); }
void subscribeToLightSensorMagnitude_SensorsTask(LightFn fn) { ADD(lights, lightCount, fn); }
void unsubscribeToLightSensorMagnitude_SensorsTask(LightFn fn) { REMOVE(lights, lightCount, fn); }

void lockTaps_SensorsTask(TapFn fn, const char *const taskName) {
    if (!tapLockName[0] || !strcmp(tapLockName, taskName)) {
        tapLock = fn;
        strncpy(tapLockName, taskName, sizeof tapLockName - 1);
    }
}

void unlockTaps_SensorsTask(const char *const taskName) {
    if (!tapLockName[0] || !strcmp(tapLockName, taskName)) {
        memset(tapLockName, 0, sizeof tapLockName);
        tapLock = NULL;
    }
}

void lockSwipes_SensorsTask(SwipeFn fn, const char *const taskName) {
    if (!swipeLockName[0] || !strcmp(swipeLockName, taskName)) {
        swipeLock = fn;
        strncpy(swipeLockName, taskName, sizeof swipeLockName - 1);
    }
}

void unlockSwipes_SensorsTask(const char *const taskName) {
    if (!swipeLockName[0] || !strcmp(swipeLockName, taskName)) {
        memset(swipeLockName, 0, sizeof swipeLockName);
        swipeLock = NULL;
    }
}

void touchSensorResetThreshold_SensorTask(void) {}
void tsl_user_ConfigureMaxThreshold(uint8_t threshold) {}

// ---- events from main.c, delivered on the sensors task ---------------------------------------

enum EventKind { EV_TAP, EV_SWIPE, EV_MOTION };

typedef struct {
    enum EventKind kind;
    uint8_t a, b;
} Event;

static QueueHandle_t events;
static StaticTask_t taskBuffer;
static bool moving;

static void tapUpdate(uint8_t code, uint8_t length) {
    if (tapLock) tapLock(code, length, false);
    else for (int i = 0; i < tapCount; i++) taps[i](code, length, false);
}

static void releaseUpdate(bool released) {
    for (int i = 0; i < releaseCount; i++) releases[i](released);
}

// A tap code the way SensorsTask reports it while the finger is on the pad: each tap as it starts
// (short), again when it's held past LONG_TAP_TIME_MS (240 ms), then the release; DISMISS_TIME_MS
// (720 ms) after the last one, the code goes to the app and an empty code ends it for the tasks.
static void playTaps(uint8_t code, uint8_t length) {
    uint8_t sofar = 0;
    for (uint8_t i = 0; i < length && i < 8; i++) {
        bool longTap = (code >> i) & 1;
        releaseUpdate(false);
        tapUpdate(sofar, i + 1);
        if (longTap) {
            vTaskDelay(LONG_TAP_TIME_MS + 60);
            sofar |= 1 << i;
            tapUpdate(sofar, i + 1);
            vTaskDelay(100);
        } else {
            vTaskDelay(120);
        }
        releaseUpdate(true);
        if (i + 1 < length) vTaskDelay(180);
    }
    vTaskDelay(DISMISS_TIME_MS + 10);
    if (!tapLock) {
        uint8_t note[3] = {BLE_NOTIFY_TOUCH, sofar, length};
        sendData_CommunicationTask(BLE_TYPE_MSG, BLE_TX_COMMAND_BLE_NOTIFY, 3, note);
    }
    tapUpdate(0, 0);
}

static void deliver(Event *e) {
    switch (e->kind) {
    case EV_TAP:
        playTaps(e->a, e->b);
        break;
    case EV_SWIPE: {
        touch_swipe_state_t s = {.direction = e->a ? oled_right : oled_left};
        if (swipeLock) swipeLock(s);
        else for (int i = 0; i < swipeCount; i++) swipes[i](s);
        break;
    }
    case EV_MOTION:
        moving = e->a;
        break;
    }
}

// While the bike moves, every 100 ms the accelerometer interrupts (RideTask counts the interrupts to
// tell a moving bike from a parked one) and, to whoever streams it (the alarm), reads a jolt in mg
// as the LSM303 gives it: about 1 g down, with ±0.2 g that changes sign each time, well past the
// alarm's 0.05 g threshold.
static void sensorsTask(void *params) {
    Event e;
    unsigned jolt = 0;
    for (;;) {
        if (xQueueReceive(events, &e, moving ? 100 : portMAX_DELAY) == pdPASS) {
            deliver(&e);
        } else if (moving) {
            for (int i = 0; i < accCount; i++) accInterrupts[i]();
            float s = (jolt++ & 1) ? 200.0f : -200.0f, x = s, y = -s / 2, z = 1000.0f + s / 4;
            for (int i = 0; i < accDataCount; i++) accData[i](&x, &y, &z);
        }
    }
}

void sim_sensors_init(void) {
    events = xQueueCreate(16, sizeof(Event));
    xTaskCreateStatic(sensorsTask, TASKNAME_SENSORS, 0, NULL, PRIORITY_NORMAL, NULL, &taskBuffer);
}

static void post(enum EventKind kind, uint8_t a, uint8_t b) {
    Event e = {kind, a, b};
    xQueueSend(events, &e, 0);
}

void sim_sensors_tap(uint8_t code, uint8_t length) { post(EV_TAP, code, length); }
void sim_sensors_swipe(bool right) { post(EV_SWIPE, right, 0); }
void sim_sensors_motion(bool on) { post(EV_MOTION, on, 0); }
