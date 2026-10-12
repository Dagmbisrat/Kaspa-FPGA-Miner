"""miner_link: the host side of the miner's UART register protocol.

Shared by the `uart` CLI and the pool bridge (software/pool_bridge).
Register map: docs/work_controller.md.
Frame: AA CMD ADDR D0 D1 D2 D3 CHK (little-endian, CHK = XOR(CMD..D3)).
"""
import struct
import time

import serial

SOF = 0xAA
CMD_READ, CMD_WRITE = 0x00, 0x01
RESP_READ, RESP_WRITE_ACK, RESP_NACK = 0x80, 0x81, 0x82
CMD_NAMES = {CMD_READ: "READ", CMD_WRITE: "WRITE", RESP_READ: "READ-RESP",
             RESP_WRITE_ACK: "WRITE-ACK", RESP_NACK: "NACK"}

# work_controller register map (docs/work_controller.md)
REGS = {"CTRL": 0x00, "STATUS": 0x04}
REGS.update({f"PPH{i}": 0x08 + 4 * i for i in range(8)})
REGS.update({"TS0": 0x28, "TS1": 0x2C})
REGS.update({f"TGT{i}": 0x30 + 4 * i for i in range(8)})
REGS.update({"NONCE0": 0x50, "NONCE1": 0x54,
             "FOUND_NONCE0": 0x58, "FOUND_NONCE1": 0x5C,
             "FOUND_WORKID": 0x60, "FOUND_COUNT": 0x64})
# Diag regs (uart_test_top only)
DIAG_REGS = {"DIAG_ID": 0x80, "UPTIME": 0x84, "TEMP": 0x88, "TEMP_MAX": 0x8C,
             "TEMP_MIN": 0x90, "VCCINT": 0x94, "VCCAUX": 0x9C, "VCCBRAM": 0xA0,
             "JOBS": 0xA4, "FINDS": 0xA8, "REQUESTS": 0xAC, "CLK_FREQ": 0xB0,
             "CYCLES": 0xB4}
DIAG_ID = 0x44494147  # "DIAG"
MINER_REGS = dict(REGS)
REGS.update(DIAG_REGS)
ADDR_NAMES = {a: n for n, a in REGS.items()}
REG_NOTES = {"CTRL": "W  bit0=START", "STATUS": "R  bit1=found pending",
             "FOUND_NONCE0": "R  low word, POPS the FIFO",
             "FOUND_NONCE1": "R  high word of last pop",
             "FOUND_WORKID": "R  work id of last pop",
             "FOUND_COUNT": "R  finds waiting"}
for _n in DIAG_REGS:
    REG_NOTES[_n] = "R  diag (debug bitstream only)"
# Skipped by dump (write-only / pops FIFO)
DUMP_SKIP = {"CTRL", "FOUND_NONCE0"}

MASK32 = 0xFFFFFFFF


def checksum(body):
    chk = 0
    for b in body:
        chk ^= b
    return chk


def build_frame(cmd, addr, data=0, corrupt=False):
    body = bytes([cmd, addr]) + struct.pack("<I", data & MASK32)
    return bytes([SOF]) + body + bytes([checksum(body) ^ (0xFF if corrupt else 0)])


def reg_name(addr):
    return ADDR_NAMES.get(addr, f"0x{addr:02X}")


class ProtocolError(Exception):
    pass


class Miner:
    def __init__(self, port, baud, quiet=False, timeout=0.5):
        self.ser = serial.Serial(port, baud, timeout=timeout)
        # FTDI on Linux holds short replies for its 16 ms latency timer by
        # default; low-latency mode drops it to 1 ms (no root needed).
        try:
            self.ser.set_low_latency_mode(True)
        except (AttributeError, NotImplementedError, OSError, ValueError):
            pass
        self.quiet = quiet
        # Last value written per register, for load_job(only_changed=True).
        # Stale after a board reset - call forget() then.
        self.written = {}
        time.sleep(0.05)
        self.ser.reset_input_buffer()

    def log(self, text):
        if not self.quiet:
            print(text)

    def transact(self, cmd, addr, data=0, corrupt=False):
        tx = build_frame(cmd, addr, data, corrupt)
        note = f"{CMD_NAMES.get(cmd, hex(cmd))} {reg_name(addr)}"
        if cmd == CMD_WRITE:
            note += f" = 0x{data & MASK32:08X}"
        if corrupt:
            note += "  (checksum deliberately wrong)"
        self.log(f">> {tx.hex(' ')}   {note}")
        self.ser.write(tx)

        rx = self.ser.read(8)
        if len(rx) != 8:
            self.log(f"<< {rx.hex(' ') or '(nothing)'}")
            raise ProtocolError(f"timeout: got {len(rx)}/8 response bytes")
        (rdata,) = struct.unpack("<I", rx[3:7])
        rcmd, raddr = rx[1], rx[2]
        self.log(f"<< {rx.hex(' ')}   {CMD_NAMES.get(rcmd, hex(rcmd))} "
                 f"{reg_name(raddr)} = 0x{rdata:08X}")
        if rx[0] != SOF:
            raise ProtocolError("response doesn't start with 0xAA")
        if checksum(rx[1:7]) != rx[7]:
            raise ProtocolError("response checksum is wrong")
        if raddr != addr:
            raise ProtocolError(f"response is for 0x{raddr:02X}, asked 0x{addr:02X}")
        return rcmd, rdata

    def read(self, addr):
        rcmd, data = self.transact(CMD_READ, addr)
        if rcmd != RESP_READ:
            raise ProtocolError(f"expected READ-RESP, got {CMD_NAMES.get(rcmd, hex(rcmd))}")
        return data

    def write(self, addr, data):
        self.written.pop(addr, None)
        rcmd, echo = self.transact(CMD_WRITE, addr, data)
        if rcmd != RESP_WRITE_ACK:
            raise ProtocolError(f"expected WRITE-ACK, got {CMD_NAMES.get(rcmd, hex(rcmd))}")
        if echo != data & MASK32:
            raise ProtocolError(f"ack echoed 0x{echo:08X}, wrote 0x{data & MASK32:08X}")
        self.written[addr] = data & MASK32

    def forget(self):
        self.written.clear()

    def write_wide(self, first, value, words, only_changed=False):
        for i in range(words):
            addr, word = first + 4 * i, (value >> (32 * i)) & MASK32
            if not (only_changed and self.written.get(addr) == word):
                self.write(addr, word)

    def read_wide(self, first, words):
        return sum(self.read(first + 4 * i) << (32 * i) for i in range(words))

    def load_job(self, pph, ts, target, nonce, start=True, only_changed=False):
        """Stage a job and START it. only_changed skips words that already
        hold the value (the core re-reads all of them on START)."""
        self.write_wide(REGS["PPH0"], pph, 8, only_changed)
        self.write_wide(REGS["TS0"], ts, 2, only_changed)
        self.write_wide(REGS["TGT0"], target, 8, only_changed)
        self.write_wide(REGS["NONCE0"], nonce, 2, only_changed)
        if start:
            self.write(REGS["CTRL"], 1)

    def pop_found(self):
        """Pop one entry: (nonce, work_id), or None if the FIFO is empty."""
        if self.read(REGS["FOUND_COUNT"]) == 0:
            return None
        lo = self.read(REGS["FOUND_NONCE0"])
        hi = self.read(REGS["FOUND_NONCE1"])
        wid = self.read(REGS["FOUND_WORKID"])
        return (hi << 32) | lo, wid

    def wait_found(self, count, timeout):
        deadline = time.monotonic() + timeout
        n = 0
        while time.monotonic() < deadline:
            n = self.read(REGS["FOUND_COUNT"])
            if n >= count:
                return n
            time.sleep(0.02)
        return n
