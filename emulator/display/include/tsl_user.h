// Stand-in for the touch sensing library: the simulator has no touch pad.
#ifndef __TSL_USER_H
#define __TSL_USER_H

#include <stdint.h>

void tsl_user_ConfigureMaxThreshold(uint8_t threshold);

#endif
