"""Offline tests for the stratum conversions (pytest, no hardware/network)."""
import random
import struct

import pytest

import stratum
from stratum import Job

HEADER = bytes.fromhex("deadbeefcafebabe0123456789abcdef0123456789abcdeffeedfacedeadbeef")
TS = 1_700_000_000_123


# The encoders below are line-for-line ports of kaspa-stratum-bridge's
# hasher.go, so the parse tests check against what a real pool sends.
def ksb_job_header(header):
    """GenerateJobHeader: 4 little-endian u64 words."""
    return list(struct.unpack("<4Q", header))


def ksb_large_job(header, ts):
    """GenerateLargeJobParams: 4 big-endian u64s + byte-swapped timestamp."""
    ids = list(struct.unpack(">4Q", header))
    ids.append(struct.unpack("<Q", struct.pack(">Q", ts))[0])
    return "".join(f"{v:016x}" for v in ids)


def test_notify_word_format():
    job = stratum.parse_notify(["42", ksb_job_header(HEADER), TS])
    assert job == Job("42", HEADER, TS)


def test_notify_big_job_format():
    job = stratum.parse_notify(["7", ksb_large_job(HEADER, TS)])
    assert job == Job("7", HEADER, TS)


def test_notify_rejects_garbage():
    with pytest.raises(ValueError):
        stratum.parse_notify(["1", [1, 2, 3], TS])
    with pytest.raises(ValueError):
        stratum.parse_notify(["1", "abcd"])


def test_diff_to_target():
    assert stratum.diff_to_target(1) == (1 << 224) - 1
    assert stratum.diff_to_target(4) == ((1 << 224) - 1) // 4
    assert stratum.diff_to_target(0.5) == (1 << 225) - 2
    assert stratum.diff_to_target(1e-80) == stratum.MAX_TARGET
    with pytest.raises(ValueError):
        stratum.diff_to_target(0)


def test_diff1_is_2_pow_32_hashes():
    assert stratum.hashes_per_share(stratum.diff_to_target(1)) == pytest.approx(2 ** 32)


def test_extranonce():
    assert stratum.parse_extranonce(["00ab"]) == (0xAB, 16)
    assert stratum.parse_extranonce(["0x1f", 1]) == (0x1F, 8)
    assert stratum.parse_extranonce([""]) == (0, 0)
    with pytest.raises(ValueError):
        stratum.parse_extranonce(["0123456789"])    # 40 bits, < 32 left


@pytest.mark.parametrize("prefix,bits", [(0, 0), (0xAB, 16), (0xFFFF, 16), (0x7F, 8)])
def test_nonce_base_keeps_prefix_and_room(prefix, bits):
    rng = random.Random(1)
    for _ in range(200):
        base = stratum.pick_nonce_base(prefix, bits, rng)
        last = base + (1 << stratum.MIN_FREE_BITS) - 1
        assert last <= stratum.MASK64
        assert stratum.has_prefix(base, prefix, bits)
        assert stratum.has_prefix(last, prefix, bits)


def test_submit_params_full_nonce():
    # A full 16-digit nonce is used as-is by the pool (no extranonce prepend).
    assert stratum.submit_params("kaspa:q.w", "5", 0xAB00000000000001) == \
        ["kaspa:q.w", "5", "0xab00000000000001"]
    assert stratum.submit_params("w", "5", 1)[2] == "0x0000000000000001"
