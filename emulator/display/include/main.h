// Stand-in for the firmware's main.h: the application defines, without the STM32 HAL.
#ifndef __MAIN_H
#define __MAIN_H

#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include "FreeRTOS.h"
#include "stm32l4xx_hal.h"

void Error_Handler(void);

#define FLASH_ID 0x1540EF
#define CONSOLE_MAX_DATA_SIZE 2048

#define PRIORITY_IDLE (0)
#define PRIORITY_LOW (1)
#define PRIORITY_BELOW_NORMAL (2)
#define PRIORITY_NORMAL (3)
#define PRIORITY_ABOVE_NORMAL (4)
#define PRIORITY_HIGH (5)
#define PRIORITY_REAL_TIME (6)

#define FREE_HEAP_CRITICAL_MIN 10
#define FREE_HEAP_WASTE_MAX 20

#define SPI_EVENT_COMPLETED 0x01
#define SPI_EVENT_ERROR 0x02

// The display's pins (OLEDDriver.c drives them; src/devices.c reads the data/command line).
#define OLED_VDD_PWR_EN_Pin GPIO_PIN_13
#define OLED_VDD_PWR_EN_GPIO_Port GPIOC
#define OLED_VCC_PWR_EN_Pin GPIO_PIN_7
#define OLED_VCC_PWR_EN_GPIO_Port GPIOC
#define OLED_CS_Pin GPIO_PIN_4
#define OLED_CS_GPIO_Port GPIOC
#define OLED_RES_Pin GPIO_PIN_5
#define OLED_RES_GPIO_Port GPIOC
#define OLED_DC_Pin GPIO_PIN_6
#define OLED_DC_GPIO_Port GPIOC
#define OLED_SPI hspi2

#endif
