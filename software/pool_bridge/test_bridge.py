"""End-to-end bridge test, offline: a fake kaspa-stratum-bridge-style pool on
localhost and a software model of the miner's register interface."""
import asyncio
import json
import random
import sys
from collections import deque

import pytest

import pool_bridge
import stratum
from pool_bridge import Bridge, MinerWorker, Stats
from test_stratum import ksb_job_header, ksb_large_job

sys.path.insert(0, pool_bridge.REF_DIR)
from kheavyhash_ref import KHeavyhash  # noqa: E402

# The fake miner hashes in Python: sync on all-ones (it has no FIFO overflow bug)
pool_bridge.SYNC_TARGET = stratum.MAX_TARGET
# ~1 share per 16 hashes, so the reference can "mine" it quickly
SHARE_DIFF = 2.0 ** -28
EXTRANONCE = "00ab"


class FakeMiner:
    """Models work_controller/core as the host sees it: START bumps an 8-bit
    work_id, stale-work hits are dropped, finds go into a 4-deep FIFO."""

    def __init__(self, start_wid=None, hashes_per_poll=8):
        self.kh = KHeavyhash()
        self.wid = random.randrange(256) if start_wid is None else start_wid
        self.job = None
        self.fifo = deque()
        self.hashes_per_poll = hashes_per_poll
        self.loads = 0

    def forget(self):
        pass

    def load_job(self, pph, ts, target, nonce, start=True, only_changed=False):
        assert start
        self.wid = (self.wid + 1) & 0xFF
        self.job = (pph.to_bytes(32, "little"), ts, target, nonce)
        self.loads += 1

    def pop_found(self):
        if self.job:
            pph, ts, target, nonce = self.job
            for n in range(nonce, nonce + self.hashes_per_poll):
                if target == stratum.MAX_TARGET or \
                        int.from_bytes(self.kh.hash(pph, ts, n), "little") <= target:
                    if len(self.fifo) < 4:
                        self.fifo.append((n, self.wid))
            self.job = (pph, ts, target, nonce + self.hashes_per_poll)
        return self.fifo.popleft() if self.fifo else None


class FakePool:
    """Speaks like kaspa-stratum-bridge and checks shares with the reference."""

    def __init__(self, big_job=False, n_jobs=3):
        self.big_job = big_job
        self.kh = KHeavyhash()
        rng = random.Random(7)
        self.jobs = {str(i): (rng.randbytes(32), 1_700_000_000_000 + i) for i in range(n_jobs)}
        self.target = stratum.diff_to_target(SHARE_DIFF)
        self.accepted, self.rejected = [], []

    async def handle(self, reader, writer):
        def send(obj):
            writer.write((json.dumps(obj) + "\n").encode())

        while line := await reader.readline():
            msg = json.loads(line)
            method, mid, params = msg["method"], msg["id"], msg["params"]
            if method == "mining.subscribe":
                send({"id": mid, "result": [True, "EthereumStratum/1.0.0"], "error": None})
            elif method == "mining.authorize":
                send({"id": mid, "result": True, "error": None})
                send({"id": None, "method": "set_extranonce", "params": [EXTRANONCE]})
                send({"id": None, "method": "mining.set_difficulty", "params": [SHARE_DIFF]})
                for jid, (pph, ts) in self.jobs.items():
                    p = [jid, ksb_large_job(pph, ts)] if self.big_job \
                        else [jid, ksb_job_header(pph), ts]
                    send({"id": int(jid), "method": "mining.notify", "params": p})
            elif method == "mining.submit":
                ok = self.check(*params)
                (self.accepted if ok else self.rejected).append(params)
                send({"id": mid, "result": ok, "error": None if ok else [23, "bad share"]})
            await writer.drain()

    def check(self, login, job_id, noncestr):
        # Same parsing as share_handler.go
        noncestr = noncestr.replace("0x", "", 1)
        if len(noncestr) <= 16 - len(EXTRANONCE):
            noncestr = EXTRANONCE + noncestr.rjust(16 - len(EXTRANONCE), "0")
        nonce = int(noncestr, 16)
        pph, ts = self.jobs[job_id]
        if nonce >> 48 != int(EXTRANONCE, 16):
            return False
        return int.from_bytes(self.kh.hash(pph, ts, nonce), "little") <= self.target


async def run_bridge(pool, want, timeout=60):
    server = await asyncio.start_server(pool.handle, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    stats = Stats()
    miner = FakeMiner()
    worker = MinerWorker(miner, KHeavyhash(), None, stats)
    client = stratum.StratumClient("127.0.0.1", port, "kaspa:qtest.fpga")
    bridge = Bridge(client, worker, stats)
    task = asyncio.create_task(bridge.run(stats_interval=3600))
    try:
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        while len(pool.accepted) + len(pool.rejected) < want and loop.time() < deadline:
            await asyncio.sleep(0.05)
    finally:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
        server.close()
    return stats, miner


@pytest.mark.parametrize("big_job", [False, True])
def test_shares_accepted_end_to_end(big_job):
    pool = FakePool(big_job=big_job)
    stats, miner = asyncio.run(run_bridge(pool, want=5))
    assert len(pool.accepted) >= 5, (stats.line(), pool.rejected)
    assert pool.rejected == []
    assert stats.hw_errors == 0
    # Only the newest job was mined (older notifies were coalesced)
    newest = max(pool.jobs, key=int)
    assert {p[1] for p in pool.accepted} == {newest}
    assert all(int(p[2], 16) >> 48 == 0xAB for p in pool.accepted)


def test_bad_finds_trigger_resync():
    stats = Stats()
    miner = FakeMiner(start_wid=10)
    worker = MinerWorker(miner, KHeavyhash(), lambda w, n: None, stats)
    worker.sync()
    assert worker.next_wid == 13    # sync job got work_id 11, park job 12
    for _ in range(pool_bridge.RESYNC_AFTER - 1):
        worker.check(0x1234, 200)   # never-loaded work_id
    assert worker.next_wid == 13
    worker.check(0x1234, 200)
    assert worker.next_wid is None  # run() will sync again
    assert stats.finds == pool_bridge.RESYNC_AFTER
