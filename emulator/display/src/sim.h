// The simulator's own interface between rtos.c, comm.c, devices.c and main.c.
#ifndef SIM_H
#define SIM_H

#include <stdbool.h>
#include <stdint.h>
#include "FreeRTOS.h"

// rtos.c
void sim_init(void);          // takes the scheduler lock: call once, before the firmware's init_*
void sim_tick(void);          // one millisecond: due timers, then every task that can run
void sim_run_ready(void);     // run tasks that can run now, without advancing time
TickType_t sim_now(void);

// comm.c: the BLE link, as the STM32 sees it from the nRF52
void sim_comm_init(void);
void sim_comm_receive(const uint8_t *bytes, uint16_t length);   // a command [service, cmd, payload…]
void sim_comm_connection(bool connected);                       // the app (dis)connects

// sensors.c: the touch pad and the accelerometer
void sim_sensors_init(void);
void sim_sensors_tap(uint8_t code, uint8_t length);   // bit i of code: tap i was long
void sim_sensors_swipe(bool right);
void sim_sensors_motion(bool moving);

// stubs.c: the rest of the system (the language command)
void sim_system_init(void);

// devices.c: what the firmware drives, reported on stdout
void sim_devices_flush(void);  // print the LEDs and the display if they changed since the last flush

// main.c: output lines (see the protocol at the top of main.c)
void sim_out(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void sim_out_hex(char kind, const uint8_t *bytes, uint32_t length);

#endif
