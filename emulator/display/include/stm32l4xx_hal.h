// Stand-in for the STM32L4 HAL: only the names the display code mentions.
#ifndef SIM_STM32L4XX_HAL_H
#define SIM_STM32L4XX_HAL_H

#include <stdint.h>

typedef enum { HAL_OK = 0, HAL_ERROR = 1, HAL_BUSY = 2, HAL_TIMEOUT = 3 } HAL_StatusTypeDef;
typedef enum { GPIO_PIN_RESET = 0, GPIO_PIN_SET } GPIO_PinState;
typedef enum { RESET = 0, SET = !RESET } FlagStatus, ITStatus;
typedef enum { DISABLE = 0, ENABLE = !DISABLE } FunctionalState;

typedef struct { int unused; } GPIO_TypeDef;
typedef struct { int unused; } TIM_HandleTypeDef;
typedef struct { int unused; } I2C_HandleTypeDef;
typedef struct { int unused; } SPI_HandleTypeDef;
typedef struct { int unused; } UART_HandleTypeDef;
typedef struct { int unused; } RTC_HandleTypeDef;
typedef struct { int unused; } ADC_HandleTypeDef;
typedef struct { uint8_t Hours, Minutes, Seconds, TimeFormat; uint32_t SubSeconds, SecondFraction,
                 DayLightSaving, StoreOperation; } RTC_TimeTypeDef;
typedef struct { uint8_t WeekDay, Month, Date, Year; } RTC_DateTypeDef;

extern GPIO_TypeDef simGPIOA, simGPIOB, simGPIOC, simGPIOH;
#define GPIOA (&simGPIOA)
#define GPIOB (&simGPIOB)
#define GPIOC (&simGPIOC)
#define GPIOH (&simGPIOH)
#define GPIO_PIN_0 ((uint16_t)0x0001)
#define GPIO_PIN_1 ((uint16_t)0x0002)
#define GPIO_PIN_2 ((uint16_t)0x0004)
#define GPIO_PIN_3 ((uint16_t)0x0008)
#define GPIO_PIN_4 ((uint16_t)0x0010)
#define GPIO_PIN_5 ((uint16_t)0x0020)
#define GPIO_PIN_6 ((uint16_t)0x0040)
#define GPIO_PIN_7 ((uint16_t)0x0080)
#define GPIO_PIN_8 ((uint16_t)0x0100)
#define GPIO_PIN_9 ((uint16_t)0x0200)
#define GPIO_PIN_10 ((uint16_t)0x0400)
#define GPIO_PIN_11 ((uint16_t)0x0800)
#define GPIO_PIN_12 ((uint16_t)0x1000)
#define GPIO_PIN_13 ((uint16_t)0x2000)
#define GPIO_PIN_14 ((uint16_t)0x4000)
#define GPIO_PIN_15 ((uint16_t)0x8000)

void HAL_GPIO_WritePin(GPIO_TypeDef *port, uint16_t pin, GPIO_PinState state);
GPIO_PinState HAL_GPIO_ReadPin(GPIO_TypeDef *port, uint16_t pin);

uint32_t HAL_GetTick(void);
void HAL_Delay(uint32_t ms);

#define __REV16(x) ((uint16_t)((((x) & 0xff) << 8) | (((x) >> 8) & 0xff)))
#define __REV(x) __builtin_bswap32(x)
#define UNUSED(x) ((void)(x))

#endif
