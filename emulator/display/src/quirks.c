// Where the firmware relies on the STM32 itself, not on C.
//
// RideTask.c starts some animations with a NULL payload, and for the fitness intro GraphicsTask.c reads
// the payload anyway (HaloAnimation_display_progressIntro). On the STM32L451 address 0 is the boot
// flash, so the ring reads the start of the bootloader's vector table there; on a computer it would
// crash. build.mjs renames RideTask.c's calls to come through here, and a NULL payload becomes those
// bytes: the initial stack pointer from the bootloader's linker script (0x20027ff0), then handler
// addresses whose low bytes depend on the bootloader's build, given here as 0x08000000.
#include "GraphicsTask.h"

static uint8_t addressZero[16] = {
    0xf0, 0x7f, 0x02, 0x20,   // initial stack pointer
    0x00, 0x00, 0x00, 0x08,   // Reset_Handler
    0x00, 0x00, 0x00, 0x08,   // NMI_Handler
    0x00, 0x00, 0x00, 0x08,   // HardFault_Handler
};

bool sim_startAnimation_GraphicsTask(HaloAnimation_function_e type, uint8_t *payload) {
    return startAnimation_GraphicsTask(type, payload ? payload : addressZero);
}
