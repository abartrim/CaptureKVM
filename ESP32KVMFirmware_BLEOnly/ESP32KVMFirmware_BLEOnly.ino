// Minimal BLE-only diagnostic sketch using h2zero's NimBLE-Arduino library.
// Works around the Arduino-ESP32 3.3.7+ regression where the built-in NimBLE
// stack isn't discoverable on macOS / iOS (see espressif/esp-idf #15578 and
// espressif/arduino-esp32 #12362).

#include <Arduino.h>
#include <NimBLEDevice.h>

constexpr const char *kBLEServiceUUID    = "c0ffee00-cafe-4001-a001-beefd00dbeef";
constexpr const char *kBLEFrameWriteUUID = "c0ffee01-cafe-4001-a001-beefd00dbeef";
constexpr const char *kBLEFrameNotifyUUID= "c0ffee02-cafe-4001-a001-beefd00dbeef";

char gBLEDeviceName[16] = "KVM";

HardwareSerial gUart(0);  // UART0 for diagnostic prints

class FrameWriteCallbacks : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic *c, NimBLEConnInfo & /*conn*/) override {
        std::string val = c->getValue();
        gUart.printf("[WRITE] %u bytes received\r\n", (unsigned)val.size());
    }
};

void setup() {
    pinMode(LED_BUILTIN, OUTPUT);
    rgbLedWrite(RGB_BUILTIN, 0, 0, 0);

    gUart.begin(115200);
    delay(500);
    gUart.println("\r\n[BLE-ONLY-NIMBLE] booting...");

    const uint64_t mac = ESP.getEfuseMac();
    const uint16_t suffix = static_cast<uint16_t>(mac & 0xFFFFULL);
    snprintf(gBLEDeviceName, sizeof(gBLEDeviceName), "KVM-%04X", suffix);
    gUart.printf("[BLE-ONLY-NIMBLE] name='%s'\r\n", gBLEDeviceName);

    NimBLEDevice::init(gBLEDeviceName);
    NimBLEDevice::setPower(ESP_PWR_LVL_P9);  // Max TX power -> +9 dBm

    NimBLEServer *server = NimBLEDevice::createServer();
    NimBLEService *svc = server->createService(kBLEServiceUUID);

    NimBLECharacteristic *writeChar = svc->createCharacteristic(
        kBLEFrameWriteUUID,
        NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
    writeChar->setCallbacks(new FrameWriteCallbacks());

    NimBLECharacteristic *notifyChar = svc->createCharacteristic(
        kBLEFrameNotifyUUID,
        NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
    (void)notifyChar;

    svc->start();

    NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
    adv->addServiceUUID(kBLEServiceUUID);
    adv->setName(gBLEDeviceName);
    adv->enableScanResponse(true);
    adv->setPreferredParams(0x06, 0x12);  // 7.5 ms .. 22.5 ms preferred conn interval
    NimBLEDevice::startAdvertising();

    gUart.printf("[BLE-ONLY-NIMBLE] BLE init=%d, advertising started\r\n",
                 NimBLEDevice::isInitialized() ? 1 : 0);

    // 3 blue flashes to confirm setup ran end-to-end
    for (int i = 0; i < 3; ++i) {
        rgbLedWrite(RGB_BUILTIN, 0, 0, 64);
        delay(200);
        rgbLedWrite(RGB_BUILTIN, 0, 0, 0);
        delay(200);
    }
}

void loop() {
    static uint32_t last = 0;
    static bool blink = false;
    uint32_t now = millis();
    if (now - last >= 1000U) {
        last = now;
        blink = !blink;
        rgbLedWrite(RGB_BUILTIN, 0, blink ? 4 : 0, 0);
        gUart.printf("[HB] up=%lus init=%d advertising=%d\r\n",
                     now / 1000UL,
                     NimBLEDevice::isInitialized() ? 1 : 0,
                     NimBLEDevice::getAdvertising()->isAdvertising() ? 1 : 0);
    }
}
