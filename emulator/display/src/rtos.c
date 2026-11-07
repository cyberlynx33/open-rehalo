// A deterministic FreeRTOS for the firmware's tasks on a computer.
//
// Every task gets its own thread, but only one runs at a time: it holds the baton until it blocks
// (delay, notification, event bits, queue), like a single-core scheduler without time slicing. Time
// is a virtual tick of 1 ms (configTICK_RATE_HZ 1000) that main.c advances with sim_tick(): timers
// that expire on that tick fire first, then every task that can run does, highest priority first,
// until all of them are blocked again.
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "FreeRTOS.h"
#include "sim.h"

enum Wait { W_NONE, W_DELAY, W_NOTIFY, W_EVENTS, W_QUEUE_RX, W_QUEUE_TX, W_SUSPENDED };

struct SimEventGroup { EventBits_t bits; };

struct SimQueue {
    uint8_t *buf;
    UBaseType_t length, itemSize, head, count;
};

struct SimTask {
    char name[32];
    TaskFunction_t fn;
    void *params;
    UBaseType_t priority;
    pthread_t thread;
    pthread_cond_t cv;
    enum Wait wait;
    TickType_t wake;
    bool forever;
    uint32_t notify;
    struct SimEventGroup *group;
    EventBits_t want;
    bool all;
    struct SimQueue *queue;
    bool finished;
};

struct SimTimer {
    const char *name;
    TickType_t period;
    bool autoReload, active;
    TickType_t expiry;
    void *id;
    TimerCallbackFunction_t cb;
};

#define MAX_TASKS 32
#define MAX_TIMERS 64

static struct SimTask *tasks[MAX_TASKS];
static int taskCount;
static struct SimTimer *timers[MAX_TIMERS];
static int timerCount;

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t schedulerCv = PTHREAD_COND_INITIALIZER;
static struct SimTask *running;   // the task holding the baton; NULL = the scheduler (main.c, timers)
static TickType_t now;

void simAssertFailed(const char *file, int line) {
    fprintf(stderr, "halo-display: assertion failed at %s:%d\n", file, line);
    abort();
}

// ---- scheduler -------------------------------------------------------------------------------

// A task that keeps the baton for seconds never blocks: name it and stop, rather than hang.
static volatile unsigned long handoffs;

static void *watchdog(void *arg) {
    unsigned long seen = 0;
    int still = 0;
    for (;;) {
        struct timespec second = {1, 0};
        nanosleep(&second, NULL);
        struct SimTask *t = running;
        if (t && handoffs == seen) {
            if (++still == 3) {
                fprintf(stderr, "halo-display: task \"%s\" has run for 3 s without blocking (tick %u)\n", t->name, now);
                abort();
            }
        } else {
            still = 0;
        }
        seen = handoffs;
    }
    return NULL;
}

void sim_init(void) {
    pthread_mutex_lock(&lock);
    pthread_t thread;
    pthread_create(&thread, NULL, watchdog, NULL);
    pthread_detach(thread);
}

TickType_t sim_now(void) { return now; }

static bool reached(struct SimTask *t) { return !t->forever && (int32_t)(now - t->wake) >= 0; }

static bool eventsMet(struct SimEventGroup *g, EventBits_t want, bool all) {
    return all ? (g->bits & want) == want : (g->bits & want) != 0;
}

static bool canRun(struct SimTask *t) {
    if (t->finished) return false;
    switch (t->wait) {
    case W_NONE: return true;
    case W_DELAY: return reached(t);
    case W_NOTIFY: return t->notify > 0 || reached(t);
    case W_EVENTS: return eventsMet(t->group, t->want, t->all) || reached(t);
    case W_QUEUE_RX: return t->queue->count > 0 || reached(t);
    case W_QUEUE_TX: return t->queue->count < t->queue->length || reached(t);
    case W_SUSPENDED: return false;
    }
    return false;
}

static void runTasks(void) {
    for (int turns = 0; turns < 100000; turns++) {
        struct SimTask *next = NULL;
        for (int i = 0; i < taskCount; i++) {
            if (canRun(tasks[i]) && (!next || tasks[i]->priority > next->priority)) next = tasks[i];
        }
        if (!next) return;
        running = next;
        handoffs++;
        pthread_cond_signal(&next->cv);
        while (running) pthread_cond_wait(&schedulerCv, &lock);
    }
    fprintf(stderr, "halo-display: a task never blocks at tick %u\n", now);
    abort();
}

static void fireTimers(void) {
    for (int i = 0; i < timerCount; i++) {
        struct SimTimer *t = timers[i];
        if (!t->active || (int32_t)(now - t->expiry) < 0) continue;
        if (t->autoReload) t->expiry += t->period ? t->period : 1;
        else t->active = false;
        t->cb(t);
    }
}

void sim_tick(void) {
    now++;
    fireTimers();
    runTasks();
}

void sim_run_ready(void) { runTasks(); }

// Called by the running task: hand the baton back and wait to get it again.
static void yieldBaton(struct SimTask *t) {
    running = NULL;
    pthread_cond_signal(&schedulerCv);
    while (running != t) pthread_cond_wait(&t->cv, &lock);
}

static void waitFor(struct SimTask *t, enum Wait w, TickType_t ticks) {
    t->wait = w;
    t->forever = ticks == portMAX_DELAY;
    t->wake = now + ticks;
    yieldBaton(t);
}

static void *taskEntry(void *arg) {
    struct SimTask *t = arg;
    pthread_mutex_lock(&lock);
    while (running != t) pthread_cond_wait(&t->cv, &lock);
    t->fn(t->params);
    t->finished = true;
    running = NULL;
    pthread_cond_signal(&schedulerCv);
    pthread_mutex_unlock(&lock);
    return NULL;
}

// ---- tasks -----------------------------------------------------------------------------------

TaskHandle_t xTaskCreateStatic(TaskFunction_t fn, const char *name, uint32_t stackDepth, void *params,
                               UBaseType_t priority, StackType_t *stack, StaticTask_t *buffer) {
    configASSERT(taskCount < MAX_TASKS);
    struct SimTask *t = calloc(1, sizeof *t);
    strncpy(t->name, name ? name : "", sizeof t->name - 1);
    t->fn = fn;
    t->params = params;
    t->priority = priority;
    pthread_cond_init(&t->cv, NULL);
    tasks[taskCount++] = t;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 1 << 20);
    pthread_create(&t->thread, &attr, taskEntry, t);
    pthread_attr_destroy(&attr);
    return t;
}

BaseType_t xTaskCreate(TaskFunction_t fn, const char *name, uint16_t stackDepth, void *params,
                       UBaseType_t priority, TaskHandle_t *created) {
    TaskHandle_t t = xTaskCreateStatic(fn, name, stackDepth, params, priority, NULL, NULL);
    if (created) *created = t;
    return pdPASS;
}

void vTaskDelay(TickType_t ticks) {
    struct SimTask *t = running;
    if (!t) return;
    waitFor(t, W_DELAY, ticks ? ticks : 1);
    t->wait = W_NONE;
}

void vTaskDelayUntil(TickType_t *previousWake, TickType_t increment) {
    *previousWake += increment;
    struct SimTask *t = running;
    if (!t) return;
    TickType_t ticks = (int32_t)(*previousWake - now) > 0 ? *previousWake - now : 1;
    waitFor(t, W_DELAY, ticks);
    t->wait = W_NONE;
}

TickType_t xTaskGetTickCount(void) { return now; }
TickType_t xTaskGetTickCountFromISR(void) { return now; }
uint32_t HAL_GetTick(void) { return now; }

BaseType_t xTaskNotifyGive(TaskHandle_t task) {
    if (task) task->notify++;
    return pdPASS;
}

void vTaskNotifyGiveFromISR(TaskHandle_t task, BaseType_t *woken) {
    xTaskNotifyGive(task);
    if (woken) *woken = pdFALSE;
}

uint32_t ulTaskNotifyTake(BaseType_t clearOnExit, TickType_t wait) {
    struct SimTask *t = running;
    if (!t) return 0;
    if (!t->notify && wait) {
        t->wait = W_NOTIFY;
        t->forever = wait == portMAX_DELAY;
        t->wake = now + wait;
        while (!t->notify && !reached(t)) yieldBaton(t);
        t->wait = W_NONE;
    }
    uint32_t value = t->notify;
    if (value) t->notify = clearOnExit ? 0 : value - 1;
    return value;
}

TaskHandle_t xTaskGetHandle(const char *name) {
    for (int i = 0; i < taskCount; i++) {
        if (!strcmp(tasks[i]->name, name)) return tasks[i];
    }
    return NULL;
}

TaskHandle_t xTaskGetCurrentTaskHandle(void) { return running; }
char *pcTaskGetName(TaskHandle_t task) { task = task ? task : running; return task ? task->name : "scheduler"; }
UBaseType_t uxTaskGetStackHighWaterMark(TaskHandle_t task) { return 256; }
UBaseType_t uxTaskGetNumberOfTasks(void) { return taskCount; }

void vTaskSuspend(TaskHandle_t task) {
    struct SimTask *t = task ? task : running;
    if (!t) return;
    t->wait = W_SUSPENDED;
    if (t == running) yieldBaton(t);
}

void vTaskResume(TaskHandle_t task) {
    if (task && task->wait == W_SUSPENDED) task->wait = W_NONE;
}

// ---- timers ----------------------------------------------------------------------------------

TimerHandle_t xTimerCreateStatic(const char *name, TickType_t period, UBaseType_t autoReload, void *id,
                                 TimerCallbackFunction_t cb, StaticTimer_t *buffer) {
    configASSERT(timerCount < MAX_TIMERS);
    struct SimTimer *t = calloc(1, sizeof *t);
    t->name = name;
    t->period = period;
    t->autoReload = autoReload;
    t->id = id;
    t->cb = cb;
    timers[timerCount++] = t;
    return t;
}

TimerHandle_t xTimerCreate(const char *name, TickType_t period, UBaseType_t autoReload, void *id,
                           TimerCallbackFunction_t cb) {
    return xTimerCreateStatic(name, period, autoReload, id, cb, NULL);
}

BaseType_t xTimerStart(TimerHandle_t t, TickType_t wait) {
    if (!t) return pdFAIL;
    t->active = true;
    t->expiry = now + t->period;
    return pdPASS;
}

BaseType_t xTimerStop(TimerHandle_t t, TickType_t wait) {
    if (!t) return pdFAIL;
    t->active = false;
    return pdPASS;
}

BaseType_t xTimerReset(TimerHandle_t t, TickType_t wait) { return xTimerStart(t, wait); }

BaseType_t xTimerChangePeriod(TimerHandle_t t, TickType_t period, TickType_t wait) {
    if (!t) return pdFAIL;
    t->period = period;
    return xTimerStart(t, wait);
}

BaseType_t xTimerIsTimerActive(TimerHandle_t t) { return t && t->active; }
TickType_t xTimerGetExpiryTime(TimerHandle_t t) { return t ? t->expiry : 0; }
TickType_t xTimerGetPeriod(TimerHandle_t t) { return t ? t->period : 0; }
const char *pcTimerGetName(TimerHandle_t t) { return t ? t->name : ""; }
void *pvTimerGetTimerID(TimerHandle_t t) { return t ? t->id : NULL; }

// ---- event groups ----------------------------------------------------------------------------

EventGroupHandle_t xEventGroupCreateStatic(StaticEventGroup_t *buffer) { return calloc(1, sizeof(struct SimEventGroup)); }
EventGroupHandle_t xEventGroupCreate(void) { return xEventGroupCreateStatic(NULL); }

EventBits_t xEventGroupSetBits(EventGroupHandle_t g, EventBits_t bits) { return g->bits |= bits; }

EventBits_t xEventGroupClearBits(EventGroupHandle_t g, EventBits_t bits) {
    EventBits_t before = g->bits;
    g->bits &= ~bits;
    return before;
}

EventBits_t xEventGroupGetBits(EventGroupHandle_t g) { return g->bits; }

EventBits_t xEventGroupWaitBits(EventGroupHandle_t g, EventBits_t want, BaseType_t clear, BaseType_t all,
                                TickType_t wait) {
    struct SimTask *t = running;
    if (t && wait && !eventsMet(g, want, all)) {
        t->group = g;
        t->want = want;
        t->all = all;
        t->wait = W_EVENTS;
        t->forever = wait == portMAX_DELAY;
        t->wake = now + wait;
        while (!eventsMet(g, want, all) && !reached(t)) yieldBaton(t);
        t->wait = W_NONE;
    }
    EventBits_t bits = g->bits;
    if (clear && eventsMet(g, want, all)) g->bits &= ~want;
    return bits;
}

// ---- queues and semaphores -------------------------------------------------------------------

QueueHandle_t xQueueCreateStatic(UBaseType_t length, UBaseType_t itemSize, uint8_t *storage, StaticQueue_t *buffer) {
    struct SimQueue *q = calloc(1, sizeof *q);
    q->length = length;
    q->itemSize = itemSize;
    q->buf = itemSize ? calloc(length, itemSize) : NULL;
    return q;
}

QueueHandle_t xQueueCreate(UBaseType_t length, UBaseType_t itemSize) { return xQueueCreateStatic(length, itemSize, NULL, NULL); }

static bool queueWait(struct SimQueue *q, enum Wait w, TickType_t wait) {
    struct SimTask *t = running;
    bool rx = w == W_QUEUE_RX;
    if ((rx ? q->count > 0 : q->count < q->length)) return true;
    if (!t || !wait) return false;
    t->queue = q;
    t->wait = w;
    t->forever = wait == portMAX_DELAY;
    t->wake = now + wait;
    while (!(rx ? q->count > 0 : q->count < q->length) && !reached(t)) yieldBaton(t);
    t->wait = W_NONE;
    return rx ? q->count > 0 : q->count < q->length;
}

static BaseType_t queuePut(QueueHandle_t q, const void *item, TickType_t wait, bool front) {
    if (!queueWait(q, W_QUEUE_TX, wait)) return pdFAIL;
    if (q->itemSize) {
        UBaseType_t slot = front ? (q->head + q->length - 1) % q->length : (q->head + q->count) % q->length;
        memcpy(q->buf + slot * q->itemSize, item, q->itemSize);
        if (front) q->head = slot;
    }
    q->count++;
    return pdPASS;
}

BaseType_t xQueueSend(QueueHandle_t q, const void *item, TickType_t wait) { return queuePut(q, item, wait, false); }
BaseType_t xQueueSendToFront(QueueHandle_t q, const void *item, TickType_t wait) { return queuePut(q, item, wait, true); }

BaseType_t xQueueReceive(QueueHandle_t q, void *item, TickType_t wait) {
    if (!queueWait(q, W_QUEUE_RX, wait)) return pdFAIL;
    if (q->itemSize) {
        memcpy(item, q->buf + q->head * q->itemSize, q->itemSize);
        q->head = (q->head + 1) % q->length;
    }
    q->count--;
    return pdPASS;
}

BaseType_t xQueuePeek(QueueHandle_t q, void *item, TickType_t wait) {
    if (!queueWait(q, W_QUEUE_RX, wait)) return pdFAIL;
    if (q->itemSize) memcpy(item, q->buf + q->head * q->itemSize, q->itemSize);
    return pdPASS;
}

UBaseType_t uxQueueMessagesWaiting(QueueHandle_t q) { return q->count; }

BaseType_t xQueueReset(QueueHandle_t q) {
    q->head = q->count = 0;
    return pdPASS;
}

static SemaphoreHandle_t semaphore(UBaseType_t max, UBaseType_t initial) {
    SemaphoreHandle_t s = xQueueCreateStatic(max, 0, NULL, NULL);
    s->count = initial;
    return s;
}

SemaphoreHandle_t xSemaphoreCreateBinaryStatic(StaticSemaphore_t *buffer) { return semaphore(1, 0); }
SemaphoreHandle_t xSemaphoreCreateMutexStatic(StaticSemaphore_t *buffer) { return semaphore(1, 1); }
SemaphoreHandle_t xSemaphoreCreateCountingStatic(UBaseType_t max, UBaseType_t initial, StaticSemaphore_t *buffer) {
    return semaphore(max, initial);
}
SemaphoreHandle_t xSemaphoreCreateBinary(void) { return semaphore(1, 0); }
SemaphoreHandle_t xSemaphoreCreateMutex(void) { return semaphore(1, 1); }
BaseType_t xSemaphoreTake(SemaphoreHandle_t s, TickType_t wait) { return xQueueReceive(s, NULL, wait); }
BaseType_t xSemaphoreGive(SemaphoreHandle_t s) { return xQueueSend(s, NULL, 0); }
