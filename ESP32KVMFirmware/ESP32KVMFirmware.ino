#include <Arduino.h>
#include <USB.h>
#include <USBHIDKeyboard.h>
#include <USBHIDMouse.h>
#include <NimBLEDevice.h>
#include <Preferences.h>

#ifndef ARDUINO_USB_MODE
#error This sketch requires an ESP32-S2 or ESP32-S3 board with native USB support.
#endif

// Board notes (ESP32-S3-DevKitC "Dual Type-C" variant):
// - Mac (control host) plugs into the "COM" port -> USB-UART bridge chip -> UART0.
// - Target machine plugs into the "USB" port -> native USB OTG -> enumerates as HID KB+MS.
// - Control frames arrive over UART0 at kUartBaud OR over BLE GATT writes; HID reports go
//   out over native USB. Both transports run concurrently and feed independent COBS frame
//   collectors so interleaved bytes from each source don't corrupt the other.
//
// Security model:
// - BLE writes require encrypted + MITM-protected pairing using a 6-digit numeric
//   passkey. The passkey is randomly generated on first boot, persisted in NVS, and
//   only readable / rotatable via UART (i.e. requires physical USB access).
// - BLE radio can be fully disabled ("hardware-only mode") via UART command. The
//   setting is persisted across reboots.
// - Pairing method: "Passkey Entry: Display Only" on the ESP32 side; macOS prompts
//   the user to enter the 6-digit code.

namespace {

// Inbound HID frames are tiny (4-byte mouse, 8-byte keyboard) but our outbound
// management responses (GET_STATE) can run up to ~16 bytes payload + type + CRC.
// Give both buffers comfortable headroom.
constexpr size_t kMaxEncodedFrameSize = 48;
constexpr size_t kMaxDecodedFrameSize = 32;
constexpr uint32_t kUartBaud = 921600;
constexpr uint8_t kPongByte = 0xAA;

// BLE GATT UUIDs (must match the Mac app's CaptureKVM/BluetoothTransport.swift).
constexpr const char *kBLEServiceUUID = "c0ffee00-cafe-4001-a001-beefd00dbeef";
constexpr const char *kBLEFrameWriteUUID = "c0ffee01-cafe-4001-a001-beefd00dbeef";
constexpr const char *kBLEFrameNotifyUUID = "c0ffee02-cafe-4001-a001-beefd00dbeef";

char gBLEDeviceName[16] = "KVM";

enum FrameType : uint8_t {
  FRAME_TYPE_KEYBOARD_BOOT = 0x01,
  FRAME_TYPE_MOUSE_BOOT    = 0x02,
  FRAME_TYPE_PING          = 0x80,  // both transports
  FRAME_TYPE_GET_PIN       = 0x81,  // UART only
  FRAME_TYPE_ROTATE_PIN    = 0x82,  // UART only
  FRAME_TYPE_BLE_ENABLE    = 0x83,  // UART only
  FRAME_TYPE_BLE_DISABLE   = 0x84,  // UART only
  FRAME_TYPE_GET_STATE     = 0x85,  // UART only
};

using PongFn = void (*)();
enum class FrameSource { UART, BLE };

HardwareSerial gUartLink(0);
USBHIDKeyboard gKeyboard;
USBHIDMouse gMouse;
Preferences gPrefs;

NimBLECharacteristic *gNotifyChar = nullptr;
NimBLEServer *gBLEServer = nullptr;
volatile bool gBLEClientConnected = false;
uint32_t gActivityUntilMs = 0;

uint32_t gBLEPasskey = 0;
bool gBLEEnabled = true;

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

// COBS encoder for outgoing UART response frames. Output buffer must be at least
// inputLength + 2 bytes.
size_t cobsEncode(const uint8_t *input, size_t inputLength, uint8_t *output, size_t outputCapacity) {
  if (outputCapacity < inputLength + 2) return 0;
  size_t outIdx = 1;
  size_t codeIdx = 0;
  uint8_t code = 1;
  for (size_t i = 0; i < inputLength; ++i) {
    if (input[i] == 0) {
      output[codeIdx] = code;
      codeIdx = outIdx++;
      code = 1;
    } else {
      output[outIdx++] = input[i];
      ++code;
      if (code == 0xFF) {
        output[codeIdx] = code;
        codeIdx = outIdx++;
        code = 1;
      }
    }
  }
  output[codeIdx] = code;
  return outIdx;
}

// Send a framed UART response: [type, payload..., crc] COBS-encoded, 0x00 terminated.
void sendUartFrame(uint8_t type, const uint8_t *payload, size_t payloadLen) {
  uint8_t raw[kMaxDecodedFrameSize];
  if (payloadLen + 2 > sizeof(raw)) return;
  raw[0] = type;
  if (payloadLen > 0) memcpy(raw + 1, payload, payloadLen);
  raw[1 + payloadLen] = crc8(raw, 1 + payloadLen);

  uint8_t encoded[kMaxEncodedFrameSize];
  const size_t encLen = cobsEncode(raw, 1 + payloadLen + 1, encoded, sizeof(encoded));
  if (encLen == 0) return;
  gUartLink.write(encoded, encLen);
  gUartLink.write(static_cast<uint8_t>(0x00));
  gUartLink.flush();
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

// Format helpers
void writePin6(char out[6], uint32_t pin) {
  for (int i = 5; i >= 0; --i) {
    out[i] = '0' + (pin % 10);
    pin /= 10;
  }
}

// Persisted state ------------------------------------------------------------

void loadPersistedState() {
  gPrefs.begin("kvm", false);
  gBLEPasskey = gPrefs.getUInt("passkey", 0);
  if (gBLEPasskey == 0 || gBLEPasskey > 999999) {
    gBLEPasskey = esp_random() % 1000000U;
    if (gBLEPasskey < 100000) gBLEPasskey += 100000;  // keep it 6 digits for nicer UX
    gPrefs.putUInt("passkey", gBLEPasskey);
  }
  gBLEEnabled = gPrefs.getBool("ble_on", true);
  gPrefs.end();
}

void persistPasskey() {
  gPrefs.begin("kvm", false);
  gPrefs.putUInt("passkey", gBLEPasskey);
  gPrefs.end();
}

void persistBLEEnabled() {
  gPrefs.begin("kvm", false);
  gPrefs.putBool("ble_on", gBLEEnabled);
  gPrefs.end();
}

// Forward decl
void setupBLE();
void teardownBLE();

// BLE callbacks (NimBLE-Arduino API) -----------------------------------------

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer * /*srv*/, NimBLEConnInfo & /*info*/) override {
    gBLEClientConnected = true;
  }
  void onDisconnect(NimBLEServer *srv, NimBLEConnInfo & /*info*/, int /*reason*/) override {
    gBLEClientConnected = false;
    if (gBLEEnabled) {
      srv->getAdvertising()->start();
    }
  }
};

class FrameWriteCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *c, NimBLEConnInfo & /*info*/) override;
};

void handleDecodedFrame(const uint8_t *decoded, size_t decodedLength, FrameSource src, PongFn pong);
void collectorIngest(FrameCollector &fc, uint8_t byte, FrameSource src, PongFn pong);

void FrameWriteCallbacks::onWrite(NimBLECharacteristic *c, NimBLEConnInfo & /*info*/) {
  std::string val = c->getValue();
  for (size_t i = 0; i < val.size(); ++i) {
    collectorIngest(gBleCollector, static_cast<uint8_t>(val[i]), FrameSource::BLE, blePong);
  }
}

void setupBLE() {
  if (NimBLEDevice::isInitialized()) return;

  const uint64_t mac = ESP.getEfuseMac();
  const uint16_t suffix = static_cast<uint16_t>(mac & 0xFFFFULL);
  snprintf(gBLEDeviceName, sizeof(gBLEDeviceName), "KVM-%04X", suffix);

  NimBLEDevice::init(gBLEDeviceName);
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);

  // Pairing security: bond + MITM-protected + LE Secure Connections.
  // Display Only on our side: macOS will prompt the user to type the 6-digit passkey.
  NimBLEDevice::setSecurityAuth(true, true, true);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_DISPLAY_ONLY);
  NimBLEDevice::setSecurityPasskey(gBLEPasskey);

  gBLEServer = NimBLEDevice::createServer();
  gBLEServer->setCallbacks(new ServerCallbacks());

  NimBLEService *svc = gBLEServer->createService(kBLEServiceUUID);

  // Encrypted+authenticated write — pairing required.
  NimBLECharacteristic *writeChar = svc->createCharacteristic(
      kBLEFrameWriteUUID,
      NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR |
      NIMBLE_PROPERTY::WRITE_AUTHEN);
  writeChar->setCallbacks(new FrameWriteCallbacks());

  // Subscribing to notifications requires authentication. This is the trigger
  // CoreBluetooth needs to initiate pairing: our Mac app calls setNotifyValue
  // on connect, which is an ACKed GATT op that surfaces the "insufficient
  // authentication" error to the OS, which then prompts the user for the PIN.
  // (Our writes are fire-and-forget so they don't trigger pairing themselves.)
  gNotifyChar = svc->createCharacteristic(
      kBLEFrameNotifyUUID,
      NIMBLE_PROPERTY::READ_AUTHEN | NIMBLE_PROPERTY::NOTIFY);

  svc->start();

  NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(kBLEServiceUUID);
  adv->setName(gBLEDeviceName);
  adv->enableScanResponse(true);
  adv->setPreferredParams(0x06, 0x12);
  NimBLEDevice::startAdvertising();
}

void teardownBLE() {
  if (!NimBLEDevice::isInitialized()) return;
  NimBLEDevice::stopAdvertising();
  NimBLEDevice::deinit(true);
  gBLEServer = nullptr;
  gNotifyChar = nullptr;
  gBLEClientConnected = false;
}

void rotatePasskey() {
  gBLEPasskey = esp_random() % 1000000U;
  if (gBLEPasskey < 100000) gBLEPasskey += 100000;
  persistPasskey();
  if (NimBLEDevice::isInitialized()) {
    NimBLEDevice::deleteAllBonds();
    NimBLEDevice::setSecurityPasskey(gBLEPasskey);
  }
}

// Command handling -----------------------------------------------------------

void respondPin(uint8_t responseType) {
  uint8_t payload[6];
  char buf[6];
  writePin6(buf, gBLEPasskey);
  memcpy(payload, buf, 6);
  sendUartFrame(responseType, payload, sizeof(payload));
}

void respondState() {
  // payload: [ble_enabled(1), hid_mounted(1), ble_client(1), pin(6 ASCII), name(remaining)]
  uint8_t payload[24];
  size_t p = 0;
  payload[p++] = gBLEEnabled ? 1 : 0;
  payload[p++] = USB ? 1 : 0;                      // target-side USB HID is enumerated
  payload[p++] = gBLEClientConnected ? 1 : 0;      // some BLE central is connected
  char buf[6];
  writePin6(buf, gBLEPasskey);
  memcpy(payload + p, buf, 6); p += 6;
  const size_t nameLen = strnlen(gBLEDeviceName, sizeof(gBLEDeviceName));
  const size_t copyLen = (nameLen > (sizeof(payload) - p)) ? (sizeof(payload) - p) : nameLen;
  memcpy(payload + p, gBLEDeviceName, copyLen); p += copyLen;
  sendUartFrame(FRAME_TYPE_GET_STATE, payload, p);
}

void handleDecodedFrame(const uint8_t *decoded, size_t decodedLength, FrameSource src, PongFn pong) {
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

    // -- UART-only management commands --
    case FRAME_TYPE_GET_PIN:
      if (src == FrameSource::UART) {
        respondPin(FRAME_TYPE_GET_PIN);
        dispatched = true;
      }
      break;
    case FRAME_TYPE_ROTATE_PIN:
      if (src == FrameSource::UART) {
        rotatePasskey();
        respondPin(FRAME_TYPE_ROTATE_PIN);
        dispatched = true;
      }
      break;
    case FRAME_TYPE_BLE_ENABLE:
      if (src == FrameSource::UART) {
        gBLEEnabled = true;
        persistBLEEnabled();
        setupBLE();
        respondState();
        dispatched = true;
      }
      break;
    case FRAME_TYPE_BLE_DISABLE:
      if (src == FrameSource::UART) {
        gBLEEnabled = false;
        persistBLEEnabled();
        teardownBLE();
        respondState();
        dispatched = true;
      }
      break;
    case FRAME_TYPE_GET_STATE:
      if (src == FrameSource::UART) {
        respondState();
        dispatched = true;
      }
      break;

    default:
      break;
  }
  if (dispatched) {
    gActivityUntilMs = millis() + 50U;
  }
}

void collectorIngest(FrameCollector &fc, uint8_t byte, FrameSource src, PongFn pong) {
  if (byte == 0x00) {
    if (!fc.overflow && fc.length > 0) {
      uint8_t decoded[kMaxDecodedFrameSize];
      size_t decodedLength = 0;
      if (cobsDecode(fc.buffer, fc.length, decoded, sizeof(decoded), &decodedLength)) {
        handleDecodedFrame(decoded, decodedLength, src, pong);
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
    collectorIngest(gUartCollector, static_cast<uint8_t>(incoming), FrameSource::UART, uartPong);
  }
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
  // Activity-driven LED. Idle state is OFF so the LED isn't blinking at you in
  // a dark room; the LED only lights when something interesting is happening:
  //   - Brief dim blue flash for ~50 ms on every accepted control frame.
  //   - Slow dim red blink while the USB-OTG side isn't enumerated by the target
  //     (this is the "something is actually wrong" indicator).
  //   - Otherwise off.
  static uint32_t lastToggleMs = 0;
  static bool blinkOn = false;
  static uint8_t lastR = 255, lastG = 255, lastB = 255;

  const uint32_t now = millis();
  const bool usbMounted = USB;
  uint8_t r = 0, g = 0, b = 0;

  if (!usbMounted) {
    // Error: target hasn't enumerated us. Slow dim red blink.
    if (now - lastToggleMs >= 500U) {
      lastToggleMs = now;
      blinkOn = !blinkOn;
    }
    r = blinkOn ? 6 : 0;
  } else if (now < gActivityUntilMs) {
    // Dim blue flash for the activity window after each valid frame.
    b = 10;
  }
  // else: LED off (idle)

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

  loadPersistedState();

  // Make sure the device name is filled in even if BLE is disabled (for the
  // state-query response).
  const uint64_t mac = ESP.getEfuseMac();
  const uint16_t suffix = static_cast<uint16_t>(mac & 0xFFFFULL);
  snprintf(gBLEDeviceName, sizeof(gBLEDeviceName), "KVM-%04X", suffix);

  if (gBLEEnabled) setupBLE();

  gKeyboard.begin();
  gMouse.begin();
  USB.begin();

  const bool bleOK = gBLEEnabled && NimBLEDevice::isInitialized();
  gUartLink.printf("\r\n[BOOT] CaptureKVM HID Bridge - name='%s' ble=%s pin=%06u\r\n",
                   gBLEDeviceName,
                   gBLEEnabled ? (bleOK ? "ON" : "INIT-FAIL") : "OFF",
                   static_cast<unsigned>(gBLEPasskey));
  gUartLink.flush();

  // Quick triple-blink on boot: dim blue if BLE came up OK, dim red otherwise.
  blinkLedDiagnostic(gBLEEnabled ? 0 : 16, 0, gBLEEnabled ? 16 : 0, 3);
}

void loop() {
  readUartFrames();
  updateStatusLed();

  static uint32_t lastHeartbeatMs = 0;
  const uint32_t now = millis();
  if (now - lastHeartbeatMs >= 5000U) {
    lastHeartbeatMs = now;
    gUartLink.printf("[HB] up=%lus ble=%d client=%d adv=%d pin=%06u\r\n",
                     now / 1000UL,
                     gBLEEnabled ? 1 : 0,
                     gBLEClientConnected ? 1 : 0,
                     (NimBLEDevice::isInitialized() && NimBLEDevice::getAdvertising()->isAdvertising()) ? 1 : 0,
                     static_cast<unsigned>(gBLEPasskey));
  }
}
