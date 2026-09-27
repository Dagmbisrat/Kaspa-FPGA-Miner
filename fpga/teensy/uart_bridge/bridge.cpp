// Teensy 4.1 USB <-> UART bridge.
//   Serial1: pin 1 TX -> J10.37, pin 0 RX <- J10.38
//   Serial2: pin 7 RX <- J10.40 (diag, Dual Serial only)
// Code lives in .cpp to avoid Arduino prototype rewriting.
#include <Arduino.h>

static const uint32_t FPGA_BAUD   = 115200;
static const int      LED_PIN     = 13;
static const uint32_t LED_HOLD_MS = 30;

static uint32_t last_traffic_ms = 0;

#if defined(USB_DUAL_SERIAL) || defined(USB_TRIPLE_SERIAL)
#define HAVE_DIAG_PORT 1
#endif

void setup() {
  pinMode(LED_PIN, OUTPUT);
  Serial.begin(115200);         // USB, rate ignored
  Serial1.begin(FPGA_BAUD);     // FPGA, 8N1
#ifdef HAVE_DIAG_PORT
  SerialUSB1.begin(115200);     // USB port 2
  Serial2.begin(FPGA_BAUD);     // diag rx
#endif
}

void loop() {
  uint8_t buf[64];

  // PC -> FPGA
  int n = Serial.available();
  if (n > 0) {
    n = Serial.readBytes((char *)buf, min(n, (int)sizeof(buf)));
    Serial1.write(buf, n);
    last_traffic_ms = millis();
  }

  // FPGA -> PC
  n = Serial1.available();
  if (n > 0) {
    n = Serial1.readBytes((char *)buf, min(n, (int)sizeof(buf)));
    Serial.write(buf, n);
    Serial.send_now();
    last_traffic_ms = millis();
  }

#ifdef HAVE_DIAG_PORT
  // diag -> USB port 2
  n = Serial2.available();
  if (n > 0) {
    n = Serial2.readBytes((char *)buf, min(n, (int)sizeof(buf)));
    SerialUSB1.write(buf, n);
    SerialUSB1.send_now();
  }
#endif

  digitalWrite(LED_PIN, millis() - last_traffic_ms < LED_HOLD_MS);
}
