// The hardware the display firmware drives, as the simulator reports it.
//
// - LED ring: what the animations hand to update_HaloLedsDriver(), before the driver's gamma (the
//   website's renderer applies that table itself).
// - Display: the firmware's own OLEDDriver.c talks SPI to a model of the SSD1305 controller here, so
//   what comes out is the controller's memory, as written.
// - Front light and buzzer: the levels and tones their drivers are asked for.
#include <stdio.h>
#include <string.h>

#include "FrontLEDDriver.h"
#include "HaloLedsDriver.h"
#include "PiezoDriver.h"
#include "main.h"
#include "sim.h"
#include "spi.h"

GPIO_TypeDef simGPIOA, simGPIOB, simGPIOC, simGPIOH;
SPI_HandleTypeDef hspi2;

// ---- LED ring --------------------------------------------------------------------------------

static uint8_t leds[72], shownLeds[72];
static bool ledsDirty;

bool init_HaloLedsDriver(void) { return true; }
bool sleep_HaloLedsDriver(void) { return true; }
bool setCurrent_HaloLedsDriver(haloLedDriverCurrent_t currentSetting) { return true; }

bool update_HaloLedsDriver(uint8_t *ledData) {
    memcpy(leds, ledData, sizeof leds);
    ledsDirty = true;
    return true;
}

// ---- SSD1305 ---------------------------------------------------------------------------------

#define COLUMNS 132   // the controller's memory is 132 columns wide; the panel shows 128 of them

static struct {
    uint8_t ram[8][COLUMNS];
    uint8_t page, column;
    bool on, powered, dataMode;
    uint8_t contrast, brightness;
    uint8_t command, argsLeft;
} oled = {.contrast = 0x7f, .brightness = 0x7f};

static uint8_t shownRam[1024];
static bool shownOn, shownOnce;
static uint8_t shownContrast, shownBrightness;

void HAL_GPIO_WritePin(GPIO_TypeDef *port, uint16_t pin, GPIO_PinState state) {
    if (port == OLED_DC_GPIO_Port && pin == OLED_DC_Pin) oled.dataMode = state == GPIO_PIN_SET;
    if (port == OLED_VDD_PWR_EN_GPIO_Port && pin == OLED_VDD_PWR_EN_Pin) {
        oled.powered = state == GPIO_PIN_SET;
        if (!oled.powered) oled.on = false;
    }
}

GPIO_PinState HAL_GPIO_ReadPin(GPIO_TypeDef *port, uint16_t pin) { return GPIO_PIN_RESET; }

// Commands followed by arguments, and how many.
static uint8_t argumentCount(uint8_t c) {
    switch (c) {
    case 0x20: case 0x81: case 0x82: case 0xA8: case 0xAD: case 0xD3: case 0xD5: case 0xD8: case 0xD9:
    case 0xDA: case 0xDB: case 0xDC:
        return 1;
    case 0x21: case 0x22:
        return 2;
    case 0x91:
        return 4;
    default:
        return 0;
    }
}

static void oledCommand(uint8_t b) {
    if (oled.argsLeft) {
        if (oled.command == 0x81) oled.contrast = b;
        if (oled.command == 0x82) oled.brightness = b;
        oled.argsLeft--;
        return;
    }
    if (b <= 0x0f) oled.column = (oled.column & 0xf0) | b;
    else if (b <= 0x1f) oled.column = (oled.column & 0x0f) | (uint8_t)((b & 0x0f) << 4);
    else if (b >= 0xb0 && b <= 0xb7) oled.page = b & 7;
    else if (b == 0xae) oled.on = false;
    else if (b == 0xaf) oled.on = true;
    else {
        oled.command = b;
        oled.argsLeft = argumentCount(b);
    }
}

// The time the bus takes, which the firmware's animations rely on: GraphicsTask redraws the display
// for as long as a sliding animation lasts, and on the ring each frame takes its time on the wire
// (spi.c waits for the DMA to finish), while the tick goes on. SPI2 runs at 80 MHz / 16 = 5 MHz,
// 1.6 µs a byte; the 20 µs a transfer for the semaphores and the DMA set-up is an estimate. A full
// frame comes to about 2 ms.
static uint32_t busMicros;

static void spendBusTime(uint16_t length) {
    busMicros += 20 + length * 16u / 10u;
    if (busMicros < 1000) return;
    TickType_t ticks = busMicros / 1000;
    busMicros %= 1000;
    vTaskDelay(ticks);
}

bool HAL_SPI_Write_DMA(SPI_HandleTypeDef *pspi, GPIO_TypeDef *pPort, uint32_t u32Pin, uint8_t *data,
                       uint16_t length, bool *response) {
    if (response) *response = true;
    if (pspi != &hspi2) return true;
    spendBusTime(length);
    for (uint16_t i = 0; i < length; i++) {
        if (!oled.dataMode) {
            oledCommand(data[i]);
        } else {
            if (oled.column < COLUMNS) oled.ram[oled.page][oled.column] = data[i];
            oled.column++;
        }
    }
    return true;
}

// ---- front light -----------------------------------------------------------------------------

static uint8_t frontLight, shownFrontLight;

bool init_FrontLEDDriver(void) { return true; }
void setFrontLEDPercentage_FrontLEDDriver(uint8_t percentage) { frontLight = percentage; }

// ---- buzzer ----------------------------------------------------------------------------------

static struct { float hz; uint8_t volume; bool tone, amp; } piezo, shownPiezo;

bool init_PiezoDriver(void) { return true; }
bool setFrequency_PiezoDriver(float frequency) { piezo.hz = frequency; return true; }
bool setVolume_PiezoDriver(uint8_t volume) { piezo.volume = volume; return true; }
bool setToneDriverState_PiezoDriver(bool state) { piezo.tone = state; return true; }
bool setVolumeAmpState_PiezoDriver(bool state) { piezo.amp = state; return true; }
void singleStateChange_PiezoDriver(void) {}

// ---- output ----------------------------------------------------------------------------------

void sim_devices_flush(void) {
    TickType_t t = sim_now();
    if (ledsDirty && memcmp(leds, shownLeds, sizeof leds)) {
        memcpy(shownLeds, leds, sizeof leds);
        sim_out_hex('L', leds, sizeof leds);
    }
    ledsDirty = false;

    uint8_t ram[1024];
    for (int p = 0; p < 8; p++) memcpy(&ram[p * 128], oled.ram[p], 128);
    if (!shownOnce || memcmp(ram, shownRam, sizeof ram)) {
        memcpy(shownRam, ram, sizeof ram);
        sim_out_hex('O', ram, sizeof ram);
    }
    bool on = oled.on && oled.powered;
    if (!shownOnce || on != shownOn || oled.contrast != shownContrast || oled.brightness != shownBrightness) {
        shownOn = on;
        shownContrast = oled.contrast;
        shownBrightness = oled.brightness;
        sim_out("P %u %d %u %u", t, on, oled.contrast, oled.brightness);
    }

    if (!shownOnce || frontLight != shownFrontLight) {
        shownFrontLight = frontLight;
        sim_out("F %u %u", t, frontLight);
    }

    bool sounding = piezo.tone && piezo.amp && piezo.volume;
    bool wasSounding = shownPiezo.tone && shownPiezo.amp && shownPiezo.volume;
    if (sounding != wasSounding || (sounding && (piezo.hz != shownPiezo.hz || piezo.volume != shownPiezo.volume))) {
        sim_out("N %u %.0f %u %d", t, piezo.hz, piezo.volume, sounding);
    }
    shownPiezo = piezo;
    shownOnce = true;
}
