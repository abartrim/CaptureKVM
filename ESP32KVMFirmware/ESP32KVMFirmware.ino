#include <Arduino.h>
#include <USB.h>
#include <USBHIDKeyboard.h>
#include <USBHIDMouse.h>

#ifndef ARDUINO_USB_MODE
#error This sketch requires an ESP32-S2 or ESP32-S3 board with native USB support.
#endif

// Board notes (ESP32-S3-DevKitC "Dual Type-C" variant):
// - Mac (control host) plugs into the "COM" port -> USB-UART bridge chip -> UART0.
// - Target machine plugs into the "USB" port -> native USB OTG -> enumerates as HID KB+MS.
// - Control frames arrive over UART0 at kUartBaud; HID reports go out over native USB.
// - The host sends HID usages directly; this sketch does not translate keycodes.
// - The host probes baud rates via frame type 0x80 (ping); we reply with a single 0xAA
//   byte on UART so the host's baud-negotiation can settle on the highest working rate.

namespace {

constexpr size_t kMaxEncodedFrameSize = 32;
constexpr size_t kMaxDecodedFrameSize = 16;
constexpr uint32_t kUartBaud = 921600;  // Highest supported by CP2102N / CH343 on the dev kit.
constexpr uint8_t kPongByte = 0xAA;     // Response to a FRAME_TYPE_PING for baud negotiation.

enum FrameType : uint8_t {
  FRAME_TYPE_KEYBOARD_BOOT = 0x01,
  FRAME_TYPE_MOUSE_BOOT = 0x02,
  FRAME_TYPE_PING = 0x80,
};

HardwareSerial gUartLink(0);  // UART0 -> USB-UART bridge -> Mac on the "COM" port
USBHIDKeyboard gKeyboard;
USBHIDMouse gMouse;

uint8_t gEncodedFrame[kMaxEncodedFrameSize];
size_t gEncodedFrameLength = 0;
bool gFrameOverflow = false;
uint32_t gActivityUntilMs = 0;  // for brief blue LED flash on received frame

uint8_t crc8(const uint8_t *data, size_t length) {
  uint8_t crc = 0x00;
  for (size_t index = 0; index < length; ++index) {
    crc ^= data[index];
    for (uint8_t bit = 0; bit < 8; ++bit) {
      if ((crc & 0x80U) != 0U) {
        crc = static_cast<uint8_t>((crc << 1U) ^ 0x07U);
      } else {
        crc <<= 1U;
      }
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
    if (code == 0) {
      return false;
    }
    for (uint8_t copyIndex = 1; copyIndex < code; ++copyIndex) {
      if (readIndex >= inputLength || writeIndex >= outputCapacity) {
        return false;
      }
      output[writeIndex++] = input[readIndex++];
    }
    if (code != 0xFF && readIndex < inputLength) {
      if (writeIndex >= outputCapacity) {
        return false;
      }
      output[writeIndex++] = 0x00;
    }
  }
  *outputLength = writeIndex;
  return true;
}

void resetFrameCollector() {
  gEncodedFrameLength = 0;
  gFrameOverflow = false;
}

void sendKeyboardReport(const uint8_t *reportBytes) {
  // reportBytes: [modifiers, reserved(=0), k1, k2, k3, k4, k5, k6]
  KeyReport report = {};
  report.modifiers = reportBytes[0];
  report.reserved = 0;
  memcpy(report.keys, &reportBytes[2], sizeof(report.keys));
  gKeyboard.sendReport(&report);
}

void sendMouseReport(const uint8_t *reportBytes) {
  // reportBytes: [buttons, dx, dy, wheel_vert]
  // buttons(b) updates the internal button state and sends a zero-movement report if it changed.
  // move(dx, dy, wheel) then sends a single combined report with current button state and movement.
  gMouse.buttons(reportBytes[0]);
  const int8_t dx = static_cast<int8_t>(reportBytes[1]);
  const int8_t dy = static_cast<int8_t>(reportBytes[2]);
  const int8_t wheel = static_cast<int8_t>(reportBytes[3]);
  if (dx != 0 || dy != 0 || wheel != 0) {
    gMouse.move(dx, dy, wheel);
  }
}

void handleDecodedFrame(const uint8_t *decoded, size_t decodedLength) {
  // Minimum frame: 1 type byte + 1 CRC byte. Empty-payload frames (e.g., ping) are valid.
  if (decodedLength < 2) {
    return;
  }
  const uint8_t frameCrc = decoded[decodedLength - 1U];
  const size_t payloadLength = decodedLength - 1U;
  if (crc8(decoded, payloadLength) != frameCrc) {
    return;
  }
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
      // Reply with a single byte so the host can confirm UART baud is correct.
      gUartLink.write(kPongByte);
      gUartLink.flush();
      dispatched = true;
      break;
    default:
      break;
  }
  if (dispatched) {
    gActivityUntilMs = millis() + 50U;
  }
}

void finalizeEncodedFrame() {
  if (gFrameOverflow || gEncodedFrameLength == 0) {
    resetFrameCollector();
    return;
  }
  uint8_t decoded[kMaxDecodedFrameSize];
  size_t decodedLength = 0;
  if (cobsDecode(gEncodedFrame, gEncodedFrameLength, decoded, sizeof(decoded), &decodedLength)) {
    handleDecodedFrame(decoded, decodedLength);
  }
  resetFrameCollector();
}

void readUartFrames() {
  while (gUartLink.available() > 0) {
    const int incoming = gUartLink.read();
    if (incoming < 0) {
      break;
    }
    const uint8_t byteValue = static_cast<uint8_t>(incoming);
    if (byteValue == 0x00) {
      finalizeEncodedFrame();
      continue;
    }
    if (gFrameOverflow) {
      continue;
    }
    if (gEncodedFrameLength >= kMaxEncodedFrameSize) {
      gFrameOverflow = true;
      continue;
    }
    gEncodedFrame[gEncodedFrameLength++] = byteValue;
  }
}

void updateStatusLed() {
#ifdef RGB_BUILTIN
  static uint32_t lastToggleMs = 0;
  static bool blinkOn = false;
  static uint8_t lastR = 255, lastG = 255, lastB = 255;  // sentinel forces initial write

  const uint32_t now = millis();
  const bool usbMounted = USB;
  uint8_t r = 0, g = 0, b = 0;

  if (now < gActivityUntilMs) {
    // Brief blue flash on received frame.
    b = 32;
  } else if (usbMounted) {
    // Slow dim-green pulse: connected to target.
    if (now - lastToggleMs >= 1000U) {
      lastToggleMs = now;
      blinkOn = !blinkOn;
    }
    g = blinkOn ? 4 : 0;
  } else {
    // Fast dim-red blink: not enumerated.
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
  // Initialize the addressable LED to off; rgbLedWrite handles the WS2812 protocol.
  rgbLedWrite(RGB_BUILTIN, 0, 0, 0);
#endif

  gUartLink.begin(kUartBaud);

  // Identify the device cleanly so lsusb / IORegistry show useful names.
  USB.VID(0xCAFE);
  USB.PID(0x4001);
  USB.productName("ESP32 KVM HID Bridge");
  USB.manufacturerName("Cafe Labs");

  gKeyboard.begin();
  gMouse.begin();
  USB.begin();
}

void loop() {
  readUartFrames();
  updateStatusLed();
}
