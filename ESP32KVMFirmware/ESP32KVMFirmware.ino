#include <Arduino.h>
#include <USB.h>
#include <USBHIDKeyboard.h>
#include <USBHIDMouse.h>
#include <NimBLEDevice.h>

#ifndef ARDUINO_USB_MODE
#error This sketch requires an ESP32-S2 or ESP32-S3 board with native USB support.
#endif

// Board notes (ESP32-S3-DevKitC "Dual Type-C" variant):
// - Mac (control host) plugs into the "COM" port -> USB-UART bridge chip -> UART0.
// - Target machine plugs into the "USB" port -> native USB OTG -> enumerates as HID KB+MS.
// - Control frames arrive over UART0 at kUartBaud OR over BLE GATT writes; HID reports go
//   out over native USB. Both transports run concurrently and feed independent COBS frame
//   collectors so interleaved bytes from each source don't corrupt the other.
// - The host probes baud rates via frame type 0x80 (ping); we reply with a single 0xAA
//   byte on the same transport so the host's negotiation can settle on the highest
//   working rate.
// - BLE stack is h2zero's NimBLE-Arduino library, not the bundled Arduino-ESP32 BLE
//   (Bluedroid). The bundled stack in arduino-esp32 3.3.7/3.3.8 is broken on macOS/iOS
//   for custom GATT services (espressif/esp-idf #15578, espressif/arduino-esp32 #12362).

namespace {

constexpr size_t kMaxEncodedFrameSize = 32;
constexpr size_t kMaxDecodedFrameSize = 16;
constexpr uint32_t kUartBaud = 921600;
constexpr uint8_t kPongByte = 0xAA;

// BLE GATT UUIDs (must match the Mac app's CaptureKVM/BluetoothTransport.swift).
constexpr const char *kBLEServiceUUID = "c0ffee00-cafe-4001-a001-beefd00dbeef";
constexpr const char *kBLEFrameWriteUUID = "c0ffee01-cafe-4001-a001-beefd00dbeef";
constexpr const char *kBLEFrameNotifyUUID = "c0ffee02-cafe-4001-a001-beefd00dbeef";

// "KVM-XXXX" at runtime where XXXX is the last 4 hex digits of the chip's
// eFuse MAC. Short enough to fit in the 31-byte BLE advertising packet
// alongside the 128-bit service UUID + flags, but unique per device.
char gBLEDeviceName[16] = "KVM";

enum FrameType : uint8_t {
  FRAME_TYPE_KEYBOARD_BOOT = 0x01,
  FRAME_TYPE_MOUSE_BOOT = 0x02,
  FRAME_TYPE_PING = 0x80,
};

using PongFn = void (*)();

HardwareSerial gUartLink(0);
USBHIDKeyboard gKeyboard;
USBHIDMouse gMouse;

NimBLECharacteristic *gNotifyChar = nullptr;
volatile bool gBLEClientConnected = false;
uint32_t gActivityUntilMs = 0;

struct FrameCollector {
  uint8_t buffer[kMaxEncodedFrameSize];
  size_t length = 0;
  bool overflow = false;
};
FrameCollector gUartCollector;
FrameCollector gBleCollector;

uint8_t crc8(const uint8_t *data, size_t length) {
  uint8_t crc = 0x00;
  for (size_t i = 0; i < length; ++i) {
    crc ^= data[i];
    for (uint8_t b = 0; b < 8; ++b) {
      crc = (crc & 0x80U) ? static_cast<uint8_t>((crc << 1U) ^ 0x07U) : static_cast<uint8_t>(crc << 1U);
    }
  }
  return crc;
}

bool cobsDecode(const uint8_t *input, size_t inputLength, uint8_t *output,
                size_t outputCapacity, size_t *outputLength) {
  size_t readIndex = 0;
  size_t writeIndex = 0;
  while (readIndex < inputLength) {
    const uint8_t code = input[readIndex++];
    if (code == 0) return false;
    for (uint8_t copyIndex = 1; copyIndex < code; ++copyIndex) {
      if (readIndex >= inputLength || writeIndex >= outputCapacity) return false;
      output[writeIndex++] = input[readIndex++];
    }
    if (code != 0xFF && readIndex < inputLength) {
      if (writeIndex >= outputCapacity) return false;
      output[writeIndex++] = 0x00;
    }
  }
  *outputLength = writeIndex;
  return true;
}

void sendKeyboardReport(const uint8_t *reportBytes) {
  KeyReport report = {};
  report.modifiers = reportBytes[0];
  report.reserved = 0;
  memcpy(report.keys, &reportBytes[2], sizeof(report.keys));
  gKeyboard.sendReport(&report);
}

void sendMouseReport(const uint8_t *reportBytes) {
  gMouse.buttons(reportBytes[0]);
  const int8_t dx = static_cast<int8_t>(reportBytes[1]);
  const int8_t dy = static_cast<int8_t>(reportBytes[2]);
  const int8_t wheel = static_cast<int8_t>(reportBytes[3]);
  if (dx != 0 || dy != 0 || wheel != 0) {
    gMouse.move(dx, dy, wheel);
  }
}

void uartPong() {
  gUartLink.write(kPongByte);
  gUartLink.flush();
}

void blePong() {
  if (gNotifyChar == nullptr) return;
  uint8_t b = kPongByte;
  gNotifyChar->setValue(&b, 1);
  gNotifyChar->notify();
}

void handleDecodedFrame(const uint8_t *decoded, size_t decodedLength, PongFn pong) {
  if (decodedLength < 2) return;
  const uint8_t frameCrc = decoded[decodedLength - 1U];
  const size_t payloadLength = decodedLength - 1U;
  if (crc8(decoded, payloadLength) != frameCrc) return;

  const uint8_t frameType = decoded[0];
  const uint8_t *reportBytes = &decoded[1];
  const size_t reportLength = payloadLength - 1U;

  bool dispatched = false;
  switch (frameType) {
    case FRAME_TYPE_KEYBOARD_BOOT:
      if (reportLength == 8 && reportBytes[1] == 0x00) {
        sendKeyboardReport(reportBytes);
        dispatched = true;
      }
      break;
    case FRAME_TYPE_MOUSE_BOOT:
      if (reportLength == 4) {
        sendMouseReport(reportBytes);
        dispatched = true;
      }
      break;
    case FRAME_TYPE_PING:
      if (pong) pong();
      dispatched = true;
      break;
    default:
      break;
  }
  if (dispatched) {
    gActivityUntilMs = millis() + 50U;
  }
}

void collectorIngest(FrameCollector &fc, uint8_t byte, PongFn pong) {
  if (byte == 0x00) {
    if (!fc.overflow && fc.length > 0) {
      uint8_t decoded[kMaxDecodedFrameSize];
      size_t decodedLength = 0;
      if (cobsDecode(fc.buffer, fc.length, decoded, sizeof(decoded), &decodedLength)) {
        handleDecodedFrame(decoded, decodedLength, pong);
      }
    }
    fc.length = 0; fc.overflow = false;
    return;
  }
  if (fc.overflow) return;
  if (fc.length >= kMaxEncodedFrameSize) { fc.overflow = true; return; }
  fc.buffer[fc.length++] = byte;
}

void readUartFrames() {
  while (gUartLink.available() > 0) {
    const int incoming = gUartLink.read();
    if (incoming < 0) break;
    collectorIngest(gUartCollector, static_cast<uint8_t>(incoming), uartPong);
  }
}

// BLE callbacks (NimBLE-Arduino API) -----------------------------------------

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer * /*srv*/, NimBLEConnInfo & /*info*/) override {
    gBLEClientConnected = true;
  }
  void onDisconnect(NimBLEServer *srv, NimBLEConnInfo & /*info*/, int /*reason*/) override {
    gBLEClientConnected = false;
    // Restart advertising immediately so the host can reconnect.
    srv->getAdvertising()->start();
  }
};

class FrameWriteCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *c, NimBLEConnInfo & /*info*/) override {
    std::string val = c->getValue();
    for (size_t i = 0; i < val.size(); ++i) {
      collectorIngest(gBleCollector, static_cast<uint8_t>(val[i]), blePong);
    }
  }
};

void setupBLE() {
  const uint64_t mac = ESP.getEfuseMac();
  const uint16_t suffix = static_cast<uint16_t>(mac & 0xFFFFULL);
  snprintf(gBLEDeviceName, sizeof(gBLEDeviceName), "KVM-%04X", suffix);

  NimBLEDevice::init(gBLEDeviceName);
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);  // Max TX power for best discoverability.

  NimBLEServer *server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  NimBLEService *svc = server->createService(kBLEServiceUUID);
  NimBLECharacteristic *writeChar = svc->createCharacteristic(
      kBLEFrameWriteUUID,
      NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  writeChar->setCallbacks(new FrameWriteCallbacks());

  gNotifyChar = svc->createCharacteristic(
      kBLEFrameNotifyUUID,
      NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);

  svc->start();

  NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(kBLEServiceUUID);
  adv->setName(gBLEDeviceName);
  adv->enableScanResponse(true);
  adv->setPreferredParams(0x06, 0x12);  // 7.5 ms .. 22.5 ms preferred connection interval
  NimBLEDevice::startAdvertising();
}

void blinkLedDiagnostic(uint8_t r, uint8_t g, uint8_t b, int times) {
#ifdef RGB_BUILTIN
  for (int i = 0; i < times; ++i) {
    rgbLedWrite(RGB_BUILTIN, r, g, b);
    delay(150);
    rgbLedWrite(RGB_BUILTIN, 0, 0, 0);
    delay(150);
  }
#endif
}

void updateStatusLed() {
#ifdef RGB_BUILTIN
  static uint32_t lastToggleMs = 0;
  static bool blinkOn = false;
  static uint8_t lastR = 255, lastG = 255, lastB = 255;

  const uint32_t now = millis();
  const bool usbMounted = USB;
  uint8_t r = 0, g = 0, b = 0;

  if (now < gActivityUntilMs) {
    b = 32;
  } else if (usbMounted) {
    if (now - lastToggleMs >= 1000U) {
      lastToggleMs = now;
      blinkOn = !blinkOn;
    }
    g = blinkOn ? 4 : 0;
    if (gBLEClientConnected) { b = blinkOn ? 4 : 0; }
  } else {
    if (now - lastToggleMs >= 250U) {
      lastToggleMs = now;
      blinkOn = !blinkOn;
    }
    r = blinkOn ? 12 : 0;
  }

  if (r != lastR || g != lastG || b != lastB) {
    rgbLedWrite(RGB_BUILTIN, r, g, b);
    lastR = r; lastG = g; lastB = b;
  }
#endif
}

}  // namespace

void setup() {
#ifdef RGB_BUILTIN
  rgbLedWrite(RGB_BUILTIN, 0, 0, 0);
#endif

  gUartLink.begin(kUartBaud);

  USB.VID(0xCAFE);
  USB.PID(0x4001);
  USB.productName("ESP32 KVM HID Bridge");
  USB.manufacturerName("Cafe Labs");

  // Bring BLE up BEFORE USB so the BT controller initialises with a clean radio
  // power-on sequence; on the S3, USB.begin() can change power domains in a way
  // that occasionally prevents the BT controller from radiating.
  setupBLE();

  gKeyboard.begin();
  gMouse.begin();
  USB.begin();

  const bool bleOK = NimBLEDevice::isInitialized();
  gUartLink.printf("\r\n[BOOT] CaptureKVM HID Bridge - BLE init=%s, name='%s', adv=ON\r\n",
                   bleOK ? "OK" : "FAIL", gBLEDeviceName);
  gUartLink.flush();

  blinkLedDiagnostic(bleOK ? 0 : 64, 0, bleOK ? 64 : 0, 3);
}

void loop() {
  readUartFrames();
  updateStatusLed();

  static uint32_t lastHeartbeatMs = 0;
  const uint32_t now = millis();
  if (now - lastHeartbeatMs >= 5000U) {
    lastHeartbeatMs = now;
    gUartLink.printf("[HB] uptime=%lus, ble_client=%d, ble_initialized=%d, advertising=%d\r\n",
                     now / 1000UL,
                     gBLEClientConnected ? 1 : 0,
                     NimBLEDevice::isInitialized() ? 1 : 0,
                     NimBLEDevice::getAdvertising()->isAdvertising() ? 1 : 0);
  }
}
