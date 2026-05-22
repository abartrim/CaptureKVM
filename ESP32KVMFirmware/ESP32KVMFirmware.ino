#include <Arduino.h>
#include <USB.h>
#include <USBHIDKeyboard.h>
#include <USBHIDMouse.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

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

namespace {

constexpr size_t kMaxEncodedFrameSize = 32;
constexpr size_t kMaxDecodedFrameSize = 16;
constexpr uint32_t kUartBaud = 921600;
constexpr uint8_t kPongByte = 0xAA;

// BLE GATT UUIDs (must match the Mac app's CaptureKVM/BluetoothTransport.swift).
constexpr const char *kBLEServiceUUID = "c0ffee00-cafe-4001-a001-beefd00dbeef";
constexpr const char *kBLEFrameWriteUUID = "c0ffee01-cafe-4001-a001-beefd00dbeef";
constexpr const char *kBLEFrameNotifyUUID = "c0ffee02-cafe-4001-a001-beefd00dbeef";
constexpr const char *kBLEDeviceName = "ESP32 KVM HID Bridge";

enum FrameType : uint8_t {
  FRAME_TYPE_KEYBOARD_BOOT = 0x01,
  FRAME_TYPE_MOUSE_BOOT = 0x02,
  FRAME_TYPE_PING = 0x80,
};

using PongFn = void (*)();

HardwareSerial gUartLink(0);
USBHIDKeyboard gKeyboard;
USBHIDMouse gMouse;

BLECharacteristic *gNotifyChar = nullptr;
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
  // Minimum frame: 1 type byte + 1 CRC byte. Empty-payload frames (e.g., ping) are valid.
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

// BLE callbacks ----------------------------------------------------------

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer * /*srv*/) override {
    gBLEClientConnected = true;
  }
  void onDisconnect(BLEServer *srv) override {
    gBLEClientConnected = false;
    // Restart advertising immediately so the host can reconnect.
    srv->getAdvertising()->start();
  }
};

class FrameWriteCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *c) override {
    String val = c->getValue();
    const size_t n = val.length();
    for (size_t i = 0; i < n; ++i) {
      collectorIngest(gBleCollector, static_cast<uint8_t>(val[i]), blePong);
    }
  }
};

void setupBLE() {
  BLEDevice::init(kBLEDeviceName);
  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  BLEService *svc = server->createService(kBLEServiceUUID);
  BLECharacteristic *writeChar = svc->createCharacteristic(
      kBLEFrameWriteUUID,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  writeChar->setCallbacks(new FrameWriteCallbacks());

  gNotifyChar = svc->createCharacteristic(
      kBLEFrameNotifyUUID,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  gNotifyChar->addDescriptor(new BLE2902());

  svc->start();

  BLEAdvertising *adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(kBLEServiceUUID);
  adv->setScanResponse(true);
  adv->setMinPreferred(0x06);  // 7.5 ms interval — low latency
  adv->setMinPreferred(0x12);
  BLEDevice::startAdvertising();
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
    b = 32;  // Brief blue flash on frame accepted (UART or BLE).
  } else if (usbMounted) {
    if (now - lastToggleMs >= 1000U) {
      lastToggleMs = now;
      blinkOn = !blinkOn;
    }
    // Tint green slightly cyan when a BLE client is also connected.
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

  gKeyboard.begin();
  gMouse.begin();
  USB.begin();

  setupBLE();
}

void loop() {
  readUartFrames();
  updateStatusLed();
}
