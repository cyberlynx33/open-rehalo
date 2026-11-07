// Stand-in for CommunicationTask.c: the STM32's end of the BLE link. Commands arrive from main.c
// instead of the nRF52's UART, already decrypted and authenticated (the simulator is always paired),
// and go to the handler the firmware assigned, on a task of the same priority as the original.
// Replies and notifications go to stdout.
#include <stdio.h>
#include <string.h>

#include "CommunicationTask.h"
#include "SHTaskUtils.h"
#include "Shell.h"
#include "sim.h"

#define MAX_PAYLOAD 256
#define SUBSCRIBER_LIMIT 8

typedef void (*Handler)(uint16_t, uint8_t *);

static Handler authFunctions[AUTH_ENUM_SIZE];
static Handler uiFunctions[UI_ENUM_SIZE];
static Handler soundFunctions[SOUND_ENUM_SIZE];
static Handler alarmFunctions[ALARM_ENUM_SIZE];
static Handler deviceFunctions[DEVICE_ENUM_SIZE];
static Handler testFunctions[TEST_ENUM_SIZE];
static Handler experimentalFunctions[EXP_ENUM_SIZE];

static void (*connectionSubscribers[SUBSCRIBER_LIMIT])(bool);
static uint8_t connectionSubscriberCount;
static void (*pairedSubscribers[SUBSCRIBER_LIMIT])(bool);
static uint8_t pairedSubscriberCount;

enum MessageKind { MSG_COMMAND, MSG_CONNECTION };

typedef struct {
    enum MessageKind kind;
    uint16_t length;
    uint8_t data[MAX_PAYLOAD];
} Message;

static QueueHandle_t inbox;
static StaticTask_t taskBuffer;

uint8_t version[4] = {2, 3, 1, 0};

static Handler *table(uint8_t category, uint8_t *limit) {
    switch (category) {
    case COM_AUTH: *limit = AUTH_ENUM_SIZE; return authFunctions;
    case COM_UI: *limit = UI_ENUM_SIZE; return uiFunctions;
    case COM_SOUND: *limit = SOUND_ENUM_SIZE; return soundFunctions;
    case COM_ALARM: *limit = ALARM_ENUM_SIZE; return alarmFunctions;
    case COM_DEVICE: *limit = DEVICE_ENUM_SIZE; return deviceFunctions;
    case COM_TEST: *limit = TEST_ENUM_SIZE; return testFunctions;
    case COM_EXP: *limit = EXP_ENUM_SIZE; return experimentalFunctions;
    default: *limit = 0; return NULL;
    }
}

static void dispatch(Message *m) {
    // Disconnecting isn't unpairing: the ring stays paired with the app (the alarm, for one, forgets
    // its settings when it's unpaired), so the paired subscribers never hear from the simulator.
    if (m->kind == MSG_CONNECTION) {
        bool connected = m->data[0];
        for (int i = 0; i < connectionSubscriberCount; i++) connectionSubscribers[i](connected);
        return;
    }
    if (m->length < 2) {
        genericResponse_CommunicationTask(eCOM_RETURN_STATUS_FAIL);
        return;
    }
    uint8_t limit;
    Handler *handlers = table(m->data[0], &limit);
    uint8_t type = m->data[1];
    if (!handlers || type >= limit || !handlers[type]) {
        log_Shell("Unsupported Command category: %x type: %x", m->data[0], type);
        genericResponse_CommunicationTask(eCOM_RETURN_STATUS_UNIMPLEMENTED);
        return;
    }
    handlers[type](m->length - 2, &m->data[2]);
}

static void commTask(void *params) {
    static Message m;
    for (;;) {
        if (xQueueReceive(inbox, &m, portMAX_DELAY) == pdPASS) dispatch(&m);
    }
}

void sim_comm_init(void) {
    inbox = xQueueCreate(16, sizeof(Message));
    xTaskCreateStatic(commTask, TASKNAME_COMMUNICATION, 0, NULL, PRIORITY_NORMAL, NULL, &taskBuffer);
}

void sim_comm_receive(const uint8_t *bytes, uint16_t length) {
    static Message m;
    m.kind = MSG_COMMAND;
    m.length = length > MAX_PAYLOAD ? MAX_PAYLOAD : length;
    memset(m.data, 0, sizeof m.data);
    memcpy(m.data, bytes, m.length);
    if (xQueueSend(inbox, &m, 0) != pdPASS) sim_out("G %u inbox full: command dropped", sim_now());
}

void sim_comm_connection(bool connected) {
    static Message m;
    m.kind = MSG_CONNECTION;
    m.length = 1;
    m.data[0] = connected;
    xQueueSend(inbox, &m, 0);
}

// ---- the firmware's API ----------------------------------------------------------------------

void init_CommunicationTask(void) {}

void assignFunction_CommunicationTask(eComCategory_t category, uint8_t type, void *function) {
    uint8_t limit;
    Handler *handlers = table(category, &limit);
    if (handlers && type < limit) handlers[type] = (Handler)function;
}

bool sendData_CommunicationTask(uint8_t type, uint8_t command, uint16_t length, void *data) {
    if (!data) return false;
    sim_out_hex(command == BLE_TX_COMMAND_BLE_NOTIFY ? 'U' : 'R', data, length);
    return true;
}

void responseWithPayload_CommunicationTask(uint16_t length, void *data) {
    sendData_CommunicationTask(BLE_TYPE_MSG, BLE_TX_COMMAND_BLE_RESPONSE, length, data);
}

void deniedResponse_CommunicationTask(eDenyReason_t reason) {
    uint8_t reply[2] = {eCOM_RETURN_STATUS_DENIED, reason};
    responseWithPayload_CommunicationTask(2, reply);
}

void genericResponse_CommunicationTask(eCOM_RETURN_STATUS_t status) {
    uint8_t reply[1] = {status};
    responseWithPayload_CommunicationTask(1, reply);
}

void responseFromResult_CommunicationTask(bool result) {
    genericResponse_CommunicationTask(result ? eCOM_RETURN_STATUS_OK : eCOM_RETURN_STATUS_FAIL);
}

void subscribeToConnectionState_CommunicationTask(void (*function)(bool isConnected)) {
    if (connectionSubscriberCount < SUBSCRIBER_LIMIT) connectionSubscribers[connectionSubscriberCount++] = function;
}

void unsubscribeToConnectionState_CommunicationTask(void (*function)(bool isConnected)) {
    for (int i = 0; i < connectionSubscriberCount; i++) {
        if (connectionSubscribers[i] != function) continue;
        memmove(&connectionSubscribers[i], &connectionSubscribers[i + 1],
                (connectionSubscriberCount - i - 1) * sizeof connectionSubscribers[0]);
        connectionSubscriberCount--;
        return;
    }
}

void subscribeToPairedState_CommunicationTask(void (*function)(bool isPaired)) {
    if (pairedSubscriberCount < SUBSCRIBER_LIMIT) pairedSubscribers[pairedSubscriberCount++] = function;
}

void unsubscribeToPairedState_CommunicationTask(void (*function)(bool isPaired)) {
    for (int i = 0; i < pairedSubscriberCount; i++) {
        if (pairedSubscribers[i] != function) continue;
        memmove(&pairedSubscribers[i], &pairedSubscribers[i + 1],
                (pairedSubscriberCount - i - 1) * sizeof pairedSubscribers[0]);
        pairedSubscriberCount--;
        return;
    }
}

eStandbyReason_t getStandbyReason_CommunicationTask(void) { return StandbyOff; }
void toggleStandby_CommunicationTask(eStandbyReason_t reason) {}
void testOledDisplay_CommunicationTask(void) {}
uint8_t *getVersion_CommunicationTask(void) { return version; }
