// The part of the FreeRTOS API the SmartHalo 2 display code uses, for a computer. The simulator in
// src/rtos.c runs every task on its own thread, one at a time, on a virtual 1 ms tick.
#ifndef SIM_FREERTOS_H
#define SIM_FREERTOS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef uint32_t TickType_t;
typedef long BaseType_t;
typedef unsigned long UBaseType_t;
typedef uint32_t StackType_t;
typedef uint32_t EventBits_t;

typedef struct SimTask *TaskHandle_t;
typedef TaskHandle_t xTaskHandle;
typedef struct SimTimer *TimerHandle_t;
typedef struct SimEventGroup *EventGroupHandle_t;
typedef struct SimQueue *QueueHandle_t;
typedef QueueHandle_t SemaphoreHandle_t;
typedef void (*TaskFunction_t)(void *);
typedef void (*TimerCallbackFunction_t)(TimerHandle_t);

// The firmware hands these buffers to the *Static calls; the simulator allocates its own.
typedef struct { int unused; } StaticTask_t;
typedef struct { int unused; } StaticTimer_t;
typedef struct { int unused; } StaticEventGroup_t;
typedef struct { int unused; } StaticQueue_t;
typedef StaticQueue_t StaticSemaphore_t;

#define pdFALSE ((BaseType_t)0)
#define pdTRUE ((BaseType_t)1)
#define pdPASS pdTRUE
#define pdFAIL pdFALSE
#define portMAX_DELAY ((TickType_t)0xffffffffUL)
#define portTICK_PERIOD_MS ((TickType_t)1)
#define pdMS_TO_TICKS(ms) ((TickType_t)(ms))
#define portYIELD_FROM_ISR(x) ((void)(x))
#define portEND_SWITCHING_ISR(x) ((void)(x))

#define configTICK_RATE_HZ ((TickType_t)1000)
#define configMINIMAL_STACK_SIZE ((uint16_t)512)
#define configMAX_PRIORITIES 7
#define configMAX_TASK_NAME_LEN 16
#define configUSE_TRACE_FACILITY 1

void simAssertFailed(const char *file, int line);
#define configASSERT(x) do { if ((x) == 0) simAssertFailed(__FILE__, __LINE__); } while (0)

#define taskENTER_CRITICAL() ((void)0)
#define taskEXIT_CRITICAL() ((void)0)
#define taskENTER_CRITICAL_FROM_ISR() 0
#define taskEXIT_CRITICAL_FROM_ISR(x) ((void)(x))
#define taskDISABLE_INTERRUPTS() ((void)0)
#define taskENABLE_INTERRUPTS() ((void)0)
#define taskYIELD() ((void)0)

// Tasks
TaskHandle_t xTaskCreateStatic(TaskFunction_t fn, const char *name, uint32_t stackDepth, void *params,
                               UBaseType_t priority, StackType_t *stack, StaticTask_t *buffer);
BaseType_t xTaskCreate(TaskFunction_t fn, const char *name, uint16_t stackDepth, void *params,
                       UBaseType_t priority, TaskHandle_t *created);
void vTaskDelay(TickType_t ticks);
void vTaskDelayUntil(TickType_t *previousWake, TickType_t increment);
TickType_t xTaskGetTickCount(void);
TickType_t xTaskGetTickCountFromISR(void);
BaseType_t xTaskNotifyGive(TaskHandle_t task);
void vTaskNotifyGiveFromISR(TaskHandle_t task, BaseType_t *woken);
uint32_t ulTaskNotifyTake(BaseType_t clearOnExit, TickType_t wait);
TaskHandle_t xTaskGetHandle(const char *name);
TaskHandle_t xTaskGetCurrentTaskHandle(void);
char *pcTaskGetName(TaskHandle_t task);
UBaseType_t uxTaskGetStackHighWaterMark(TaskHandle_t task);
UBaseType_t uxTaskGetNumberOfTasks(void);
void vTaskSuspend(TaskHandle_t task);
void vTaskResume(TaskHandle_t task);

// Software timers (run on the simulator's timer service, at the tick they expire)
TimerHandle_t xTimerCreateStatic(const char *name, TickType_t period, UBaseType_t autoReload, void *id,
                                 TimerCallbackFunction_t cb, StaticTimer_t *buffer);
TimerHandle_t xTimerCreate(const char *name, TickType_t period, UBaseType_t autoReload, void *id,
                           TimerCallbackFunction_t cb);
BaseType_t xTimerStart(TimerHandle_t t, TickType_t wait);
BaseType_t xTimerStop(TimerHandle_t t, TickType_t wait);
BaseType_t xTimerReset(TimerHandle_t t, TickType_t wait);
BaseType_t xTimerChangePeriod(TimerHandle_t t, TickType_t period, TickType_t wait);
BaseType_t xTimerIsTimerActive(TimerHandle_t t);
TickType_t xTimerGetExpiryTime(TimerHandle_t t);
TickType_t xTimerGetPeriod(TimerHandle_t t);
const char *pcTimerGetName(TimerHandle_t t);
void *pvTimerGetTimerID(TimerHandle_t t);
#define xTimerStartFromISR(t, w) xTimerStart((t), 0)
#define xTimerStopFromISR(t, w) xTimerStop((t), 0)
#define xTimerResetFromISR(t, w) xTimerReset((t), 0)
#define xTimerChangePeriodFromISR(t, p, w) xTimerChangePeriod((t), (p), 0)

// Event groups
EventGroupHandle_t xEventGroupCreateStatic(StaticEventGroup_t *buffer);
EventGroupHandle_t xEventGroupCreate(void);
EventBits_t xEventGroupSetBits(EventGroupHandle_t g, EventBits_t bits);
EventBits_t xEventGroupClearBits(EventGroupHandle_t g, EventBits_t bits);
EventBits_t xEventGroupGetBits(EventGroupHandle_t g);
EventBits_t xEventGroupWaitBits(EventGroupHandle_t g, EventBits_t bits, BaseType_t clear, BaseType_t all,
                                TickType_t wait);
#define xEventGroupSetBitsFromISR(g, b, w) xEventGroupSetBits((g), (b))

// Queues and semaphores (copying queues; a semaphore is a queue of empty items)
QueueHandle_t xQueueCreateStatic(UBaseType_t length, UBaseType_t itemSize, uint8_t *storage, StaticQueue_t *buffer);
QueueHandle_t xQueueCreate(UBaseType_t length, UBaseType_t itemSize);
BaseType_t xQueueSend(QueueHandle_t q, const void *item, TickType_t wait);
BaseType_t xQueueSendToFront(QueueHandle_t q, const void *item, TickType_t wait);
BaseType_t xQueueReceive(QueueHandle_t q, void *item, TickType_t wait);
BaseType_t xQueuePeek(QueueHandle_t q, void *item, TickType_t wait);
UBaseType_t uxQueueMessagesWaiting(QueueHandle_t q);
BaseType_t xQueueReset(QueueHandle_t q);
#define xQueueSendToBack xQueueSend
#define xQueueSendFromISR(q, i, w) xQueueSend((q), (i), 0)
#define xQueueSendToBackFromISR(q, i, w) xQueueSend((q), (i), 0)
#define xQueueReceiveFromISR(q, i, w) xQueueReceive((q), (i), 0)
#define xQueueOverwrite(q, i) (xQueueReset(q), xQueueSend((q), (i), 0))

SemaphoreHandle_t xSemaphoreCreateBinaryStatic(StaticSemaphore_t *buffer);
SemaphoreHandle_t xSemaphoreCreateMutexStatic(StaticSemaphore_t *buffer);
SemaphoreHandle_t xSemaphoreCreateCountingStatic(UBaseType_t max, UBaseType_t initial, StaticSemaphore_t *buffer);
SemaphoreHandle_t xSemaphoreCreateBinary(void);
SemaphoreHandle_t xSemaphoreCreateMutex(void);
BaseType_t xSemaphoreTake(SemaphoreHandle_t s, TickType_t wait);
BaseType_t xSemaphoreGive(SemaphoreHandle_t s);
#define xSemaphoreTakeFromISR(s, w) xSemaphoreTake((s), 0)
#define xSemaphoreGiveFromISR(s, w) xSemaphoreGive(s)
#define xSemaphoreCreateRecursiveMutex xSemaphoreCreateMutex
#define xSemaphoreTakeRecursive xSemaphoreTake
#define xSemaphoreGiveRecursive xSemaphoreGive

#endif
