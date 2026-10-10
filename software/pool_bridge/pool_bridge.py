#!/usr/bin/env python3
"""pool_bridge: mine on a Kaspa stratum pool with the FPGA miner.

  pool_bridge.py --pool stratum+tcp://HOST:PORT --wallet kaspa:qr... \\
                 [--worker fpga1] [--password x] [--port /dev/ttyUSB0]

Pool jobs go to the miner over UART (miner_link.Miner, same as ./uart).
Every find is re-hashed with the Python reference before it is submitted,
so a byte-order or target bug shows up as an "hw error", not a pool reject.

Setup: pip install pyserial pycryptodome (same as ./uart verify).
"""
import argparse
import asyncio
import logging
import os
import sys
import threading
import time
from dataclasses import dataclass, field
from urllib.parse import urlparse

import stratum
from stratum import Job, MAX_TARGET

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
BOARD_DIR = os.path.join(REPO, "fpga", "boards", "k325t_ffg900")
REF_DIR = os.path.join(REPO, "software", "referance")

log = logging.getLogger("bridge")

WID_MASK = 0xFF         # core.sv: 8-bit work_id, +1 per START
WORK_HISTORY = 64       # recent work ids whose late finds still get submitted
POLL_S = 0.01           # FIFO is only 4 deep, poll often
RESYNC_AFTER = 3        # consecutive bad finds before re-learning work_id
# Sync/park block: ./uart verify's pph. Not 0 - an all-zero pph seeds xoshiro
# with zeros, so matrix generation never finds a full-rank matrix.
SYNC_PPH = int.from_bytes(bytes.fromhex(
    "deadbeefcafebabe0123456789abcdef0123456789abcdeffeedfacedeadbeef"), "little")


@dataclass(frozen=True)
class Work:
    job: Job
    target: int
    nonce_base: int
    prefix: int
    prefix_bits: int
    session: int


@dataclass
class Stats:
    started: float = field(default_factory=time.monotonic)
    jobs: int = 0
    load_s: float = 0.0
    finds: int = 0
    hw_errors: int = 0
    stale: int = 0
    accepted: int = 0
    rejected: int = 0
    work_done: float = 0.0   # expected hashes behind the valid finds

    def line(self):
        up = time.monotonic() - self.started
        rate = self.work_done / up / 1e6 if up else 0.0
        load = 1e3 * self.load_s / self.jobs if self.jobs else 0.0
        return (f"up {up / 60:.1f}m  jobs {self.jobs} ({load:.0f} ms/load)  "
                f"finds {self.finds}  accepted {self.accepted}  rejected {self.rejected}  "
                f"stale {self.stale}  hw-err {self.hw_errors}  ~{rate:.2f} MH/s (from shares)")


class SyncError(Exception):
    pass


class MinerWorker(threading.Thread):
    """Owns the UART. Loads the newest work, polls the found FIFO, checks each
    find with the reference and hands good ones to on_find(work, nonce)."""

    def __init__(self, miner, hasher, on_find, stats, io_errors=()):
        super().__init__(daemon=True, name="miner")
        self.m, self.kh, self.on_find, self.stats = miner, hasher, on_find, stats
        self.io_errors = io_errors
        self.lock = threading.Lock()
        self.pending = None
        self.works = {}           # work_id -> Work
        self.next_wid = None
        self.bad_streak = 0
        self.last_work = None
        self.stop = threading.Event()

    def set_work(self, work):
        """Called from the network side; only the newest work is kept."""
        with self.lock:
            self.pending = work

    def run(self):
        while not self.stop.is_set():
            try:
                if self.next_wid is None:
                    self.sync()
                with self.lock:
                    work, self.pending = self.pending, None
                if work:
                    self.load(work)
                found = self.m.pop_found()
                if found:
                    self.check(*found)
                else:
                    time.sleep(POLL_S)
            except (SyncError, *self.io_errors) as e:
                log.error("miner link: %s - resyncing in 1s", e)
                self.next_wid = None
                time.sleep(1)

    def sync(self):
        """Learn the core's current work_id (it can't be read directly): run
        an all-ones-target job so the first find carries its id, then park on
        an impossible target and drain the FIFO."""
        self.m.forget()
        self.m.load_job(SYNC_PPH, 0, MAX_TARGET, 0)
        deadline = time.monotonic() + 2.0
        found = None
        while found is None:
            if time.monotonic() > deadline:
                raise SyncError("no find from an all-ones target - is the miner bitstream loaded?")
            found = self.m.pop_found()
        self.m.load_job(SYNC_PPH, 0, 0, 0)
        time.sleep(0.05)
        while self.m.pop_found():
            pass
        self.next_wid = (found[1] + 2) & WID_MASK
        self.works.clear()
        self.bad_streak = 0
        with self.lock:
            if self.pending is None and self.last_work:
                self.pending = self.last_work     # reload what was running
        log.info("synced to the miner (next work_id %d)", self.next_wid)

    def load(self, work):
        t0 = time.monotonic()
        self.m.load_job(int.from_bytes(work.job.pph, "little"), work.job.ts,
                        work.target, work.nonce_base, only_changed=True)
        dt = time.monotonic() - t0
        self.stats.jobs += 1
        self.stats.load_s += dt
        wid = self.next_wid
        self.works[wid] = work
        self.works.pop((wid - WORK_HISTORY) & WID_MASK, None)
        self.next_wid = (wid + 1) & WID_MASK
        self.last_work = work
        log.debug("job %s -> work_id %d (%.0f ms)", work.job.job_id, wid, dt * 1e3)

    def check(self, nonce, wid):
        self.stats.finds += 1
        work = self.works.get(wid)
        if work is None:
            log.warning("find 0x%016x for unknown work_id %d", nonce, wid)
            return self.bad()
        h = int.from_bytes(self.kh.hash(work.job.pph, work.job.ts, nonce), "little")
        if h > work.target or not stratum.has_prefix(nonce, work.prefix, work.prefix_bits):
            self.stats.hw_errors += 1
            log.error("HW ERROR job %s nonce 0x%016x hash 0x%064x > target or outside "
                      "the extranonce", work.job.job_id, nonce, h)
            return self.bad()
        self.bad_streak = 0
        self.stats.work_done += stratum.hashes_per_share(work.target)
        self.on_find(work, nonce)

    def bad(self):
        self.bad_streak += 1
        if self.bad_streak >= RESYNC_AFTER:
            log.error("%d bad finds in a row - resyncing work_id", self.bad_streak)
            self.next_wid = None


class Bridge:
    """Glue between the pool connection and the miner thread."""

    def __init__(self, client, worker, stats):
        self.client, self.worker, self.stats = client, worker, stats
        self.job = None
        self.target = None
        self.prefix, self.prefix_bits = 0, 0
        self.nonce_base = stratum.pick_nonce_base(0, 0)
        client.on_job = self.on_job
        client.on_target = self.on_target
        client.on_extranonce = self.on_extranonce
        self.loop = None
        self.tasks = set()

    def on_job(self, job):
        self.job = job
        self.push()

    def on_target(self, target):
        log.info("share target 0x%064x (~%.3g hashes/share)", target,
                 stratum.hashes_per_share(target))
        self.target = target
        self.push()

    def on_extranonce(self, prefix, bits):
        log.info("extranonce 0x%0*x (%d bits)", bits // 4, prefix, bits)
        self.prefix, self.prefix_bits = prefix, bits
        self.nonce_base = stratum.pick_nonce_base(prefix, bits)
        self.push()

    def push(self):
        if self.job is None or self.target is None:
            return
        self.worker.set_work(Work(self.job, self.target, self.nonce_base,
                                  self.prefix, self.prefix_bits, self.client.session))

    # Miner thread -> event loop
    def on_find_threadsafe(self, work, nonce):
        self.loop.call_soon_threadsafe(self.on_find, work, nonce)

    def on_find(self, work, nonce):
        if work.session != self.client.session or not self.client.connected.is_set():
            self.stats.stale += 1
            log.info("dropping find for job %s from a previous pool session", work.job.job_id)
            return
        task = asyncio.create_task(self.submit(work, nonce))
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)

    async def submit(self, work, nonce):
        try:
            ok, err = await self.client.submit(work.job.job_id, nonce)
        except (stratum.StratumError, asyncio.TimeoutError) as e:
            ok, err = False, str(e) or type(e).__name__
        if ok:
            self.stats.accepted += 1
            log.info("share ACCEPTED  job %s nonce 0x%016x", work.job.job_id, nonce)
        else:
            self.stats.rejected += 1
            log.warning("share REJECTED  job %s nonce 0x%016x: %s", work.job.job_id, nonce, err)

    async def report(self, interval):
        while True:
            await asyncio.sleep(interval)
            log.info("%s", self.stats.line())

    async def run(self, stats_interval):
        self.loop = asyncio.get_running_loop()
        self.worker.on_find = self.on_find_threadsafe
        self.worker.start()
        try:
            await asyncio.gather(self.client.run(), self.report(stats_interval))
        finally:
            self.worker.stop.set()
            await asyncio.to_thread(self.worker.join, 2)


def parse_pool(url):
    u = urlparse(url if "://" in url else "stratum+tcp://" + url)
    if u.scheme not in ("stratum+tcp", "stratum", "tcp"):
        sys.exit(f"unsupported pool scheme '{u.scheme}' (only stratum+tcp, no TLS yet)")
    if not u.hostname or not u.port:
        sys.exit(f"pool needs host and port: {url}")
    return u.hostname, u.port


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pool", required=True, help="stratum+tcp://HOST:PORT")
    ap.add_argument("--wallet", required=True, help="kaspa:... payout address")
    ap.add_argument("--worker", default="fpga", help="worker name (default fpga)")
    ap.add_argument("--password", default="x",
                    help="pool password; some pools take a difficulty here, e.g. d=1")
    ap.add_argument("--port", default=os.environ.get("UART_PORT"),
                    help="miner serial port (default: $UART_PORT)")
    ap.add_argument("--baud", type=int, default=int(os.environ.get("UART_BAUD", 115200)))
    ap.add_argument("--stats", type=float, default=60, help="stats interval, s (default 60)")
    ap.add_argument("-v", "--verbose", action="store_true", help="log every stratum message")
    args = ap.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)-7s %(message)s", datefmt="%H:%M:%S")
    if not args.port:
        sys.exit("no serial port: use --port /dev/ttyUSB0 (or set UART_PORT)")
    host, port = parse_pool(args.pool)

    sys.path[:0] = [BOARD_DIR, REF_DIR]
    try:
        import serial
        from miner_link import Miner, ProtocolError
        from kheavyhash_ref import KHeavyhash
    except ImportError as e:
        sys.exit(f"{e} - run: pip install pyserial pycryptodome")

    stats = Stats()
    miner = Miner(args.port, args.baud, quiet=True)
    worker = MinerWorker(miner, KHeavyhash(), None, stats,
                         io_errors=(ProtocolError, serial.SerialException))
    client = stratum.StratumClient(host, port, f"{args.wallet}.{args.worker}", args.password)
    try:
        asyncio.run(Bridge(client, worker, stats).run(args.stats))
    except KeyboardInterrupt:
        print("\n" + stats.line())


if __name__ == "__main__":
    main()
