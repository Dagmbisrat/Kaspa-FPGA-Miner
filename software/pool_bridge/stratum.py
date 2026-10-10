"""stratum: Kaspa stratum client and the pool <-> miner value conversions.

Message formats follow kaspa-stratum-bridge (onemorebsmith), which most Kaspa
pools and miners speak:

  -> mining.subscribe  [agent]
  -> mining.authorize  ["wallet.worker", password]
  <- set_extranonce / mining.set_extranonce  [hex prefix, (size)]
  <- mining.set_difficulty  [diff]
  <- mining.notify  [job_id, [w0, w1, w2, w3], timestamp]   pph as 4 LE u64s
     or           [job_id, "<80 hex>"]                       "big job": pph
                                                             bytes + LE ts
  -> mining.submit  ["wallet.worker", job_id, "0x<16 hex nonce>"]
"""
import asyncio
import itertools
import json
import logging
import random
from dataclasses import dataclass
from fractions import Fraction

log = logging.getLogger("stratum")

MASK64 = (1 << 64) - 1
MAX_TARGET = (1 << 256) - 1
# kaspa-stratum-bridge: target = 0xFFFF...FF (224 bits) / difficulty
DIFF1_TARGET = (1 << 224) - 1
# Free nonce bits we want below the extranonce: 2^32 is ~11 min at 6.5 MH/s.
MIN_FREE_BITS = 32


@dataclass(frozen=True)
class Job:
    job_id: str
    pph: bytes      # pre_pow_hash, 32 bytes in header-hash order
    ts: int         # header timestamp (ms)


def diff_to_target(diff):
    """Share difficulty -> 256-bit target (hash <= target is a share)."""
    if diff <= 0:
        raise ValueError(f"difficulty must be > 0, got {diff}")
    return min(int(Fraction(DIFF1_TARGET) / Fraction(diff)), MAX_TARGET)


def hashes_per_share(target):
    """Expected hashes to find one hash <= target."""
    return (MAX_TARGET + 1) / (target + 1)


def parse_notify(params):
    """mining.notify params -> Job (both the 4-word and the big-job format)."""
    job_id = str(params[0])
    if isinstance(params[1], list):
        words = params[1]
        if len(words) != 4 or len(params) < 3:
            raise ValueError(f"bad notify: {params!r}")
        pph = b"".join((int(w) & MASK64).to_bytes(8, "little") for w in words)
        return Job(job_id, pph, int(params[2]))
    blob = bytes.fromhex(params[1])
    if len(blob) != 40:
        raise ValueError(f"big-job notify should be 80 hex chars: {params[1]!r}")
    return Job(job_id, blob[:32], int.from_bytes(blob[32:], "little"))


def parse_extranonce(params):
    """set_extranonce params -> (prefix value, prefix bits)."""
    text = str(params[0]).removeprefix("0x") if params else ""
    if not text:
        return 0, 0
    bits = 4 * len(text)
    if bits > 64 - MIN_FREE_BITS:
        raise ValueError(f"extranonce {text!r} leaves < {MIN_FREE_BITS} nonce bits")
    return int(text, 16), bits


def pick_nonce_base(prefix, prefix_bits, rng=random):
    """Random start nonce under the pool's extranonce prefix, with at least
    2^MIN_FREE_BITS nonces of room before the counter could carry into it."""
    free = 64 - prefix_bits
    span = 1 << free
    start = rng.randrange(0, span - (1 << MIN_FREE_BITS) + 1)
    return (prefix << free) | start


def has_prefix(nonce, prefix, prefix_bits):
    return prefix_bits == 0 or nonce >> (64 - prefix_bits) == prefix


def _is_hex(text):
    if not isinstance(text, str) or not text:
        return False
    try:
        int(text, 16)
        return True
    except ValueError:
        return False


def submit_params(login, job_id, nonce):
    return [login, job_id, f"0x{nonce & MASK64:016x}"]


class StratumError(Exception):
    pass


class StratumClient:
    """One stratum connection. Callbacks (plain functions, run on the event
    loop): on_job(Job), on_target(int), on_extranonce(prefix, bits)."""

    def __init__(self, host, port, login, password="x", agent="KasMiner-FPGA/0.1",
                 on_job=None, on_target=None, on_extranonce=None):
        self.host, self.port = host, port
        self.login, self.password, self.agent = login, password, agent
        self.on_job = on_job or (lambda job: None)
        self.on_target = on_target or (lambda target: None)
        self.on_extranonce = on_extranonce or (lambda prefix, bits: None)
        self._ids = itertools.count(1)
        self._pending = {}
        self._writer = None
        self.connected = asyncio.Event()
        # Bumped on every login: job ids from an older session are void.
        self.session = 0

    async def run(self, retry_delay=5.0):
        """Connect, log in, dispatch messages; reconnect forever on drop."""
        while True:
            try:
                await self._session()
            except (OSError, asyncio.IncompleteReadError, StratumError,
                    json.JSONDecodeError) as e:
                log.warning("pool connection lost: %s", e)
            finally:
                self._close()
            log.info("reconnecting in %.0fs", retry_delay)
            await asyncio.sleep(retry_delay)

    async def submit(self, job_id, nonce, timeout=10.0):
        """Send a share; returns (accepted, error)."""
        reply = await self._call("mining.submit",
                                 submit_params(self.login, job_id, nonce), timeout)
        return reply.get("result") is True, reply.get("error")

    async def _session(self):
        log.info("connecting to %s:%d", self.host, self.port)
        reader, self._writer = await asyncio.open_connection(self.host, self.port)
        self.session += 1
        reader_task = asyncio.create_task(self._read_loop(reader))
        try:
            reply = await self._call("mining.subscribe", [self.agent])
            # Some pools put the extranonce in the subscribe result instead:
            # [subscriptions, "extranonce hex", size]
            result = reply.get("result")
            if isinstance(result, list) and len(result) > 1 and _is_hex(result[1]):
                self.on_extranonce(*parse_extranonce([result[1]]))
            reply = await self._call("mining.authorize", [self.login, self.password])
            if reply.get("result") is not True:
                raise StratumError(f"authorize rejected: {reply.get('error')}")
            log.info("authorized as %s", self.login)
            self.connected.set()
            await reader_task
        finally:
            reader_task.cancel()

    def _close(self):
        self.connected.clear()
        for fut in self._pending.values():
            if not fut.done():
                fut.set_exception(StratumError("disconnected"))
        self._pending.clear()
        if self._writer:
            self._writer.close()
            self._writer = None

    async def _call(self, method, params, timeout=10.0):
        if not self._writer:
            raise StratumError("not connected")
        msg_id = next(self._ids)
        fut = asyncio.get_running_loop().create_future()
        self._pending[msg_id] = fut
        line = json.dumps({"id": msg_id, "method": method, "params": params})
        log.debug(">> %s", line)
        self._writer.write(line.encode() + b"\n")
        await self._writer.drain()
        try:
            return await asyncio.wait_for(fut, timeout)
        finally:
            self._pending.pop(msg_id, None)

    async def _read_loop(self, reader):
        while True:
            line = await reader.readline()
            if not line:
                raise StratumError("pool closed the connection")
            line = line.strip()
            if not line:
                continue
            log.debug("<< %s", line.decode(errors="replace"))
            self._dispatch(json.loads(line))

    def _dispatch(self, msg):
        method = msg.get("method")
        if not method:
            fut = self._pending.get(msg.get("id"))
            if fut and not fut.done():
                fut.set_result(msg)
            return
        params = msg.get("params") or []
        try:
            if method == "mining.notify":
                self.on_job(parse_notify(params))
            elif method == "mining.set_difficulty":
                self.on_target(diff_to_target(float(params[0])))
            elif method in ("set_extranonce", "mining.set_extranonce"):
                self.on_extranonce(*parse_extranonce(params))
            else:
                log.debug("ignoring %s", method)
        except (ValueError, IndexError, TypeError) as e:
            log.error("bad %s %r: %s", method, params, e)
