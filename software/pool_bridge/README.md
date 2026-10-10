# pool_bridge

Mines on a Kaspa stratum pool with the FPGA miner. Pool jobs go to the miner
over the command UART (the same `Miner` class as `./uart`, from
`fpga/boards/k325t_ffg900/miner_link.py`). Every find is re-hashed with the
Python reference before it is submitted.

```sh
pip install pyserial pycryptodome
./pool_bridge.py --pool stratum+tcp://HOST:PORT --wallet kaspa:qr... \
                 --worker fpga1 --port /dev/ttyUSB0
```

`--password` goes to the pool as-is. Some pools read a share difficulty from
it, e.g. `d=0.01`.

## Share difficulty

One share at difficulty 1 takes ~2^32 hashes, about 11 minutes at 6.5 MH/s.
Pick a pool, or a password setting, that allows a difficulty well below 1, or
shares will be rare.

## How it works

- Only the newest job is loaded. Jobs that arrive while the UART is busy
  are skipped, and only register words that changed are rewritten.
- The core's 8-bit `work_id` can't be read back. At startup the bridge runs
  an all-ones-target job, takes the `work_id` of the first find, then
  counts STARTs from there. Finds are matched to pool jobs through it.
- A find whose hash fails the target, or whose `work_id` is unknown, counts
  as an hw error. After 3 in a row the bridge re-syncs (e.g. after a board
  reset).

## Tests

Offline, no hardware: `python -m pytest` in this folder. `test_bridge.py`
runs the bridge end to end against a fake pool and a software model of the
miner. The fake pool encodes jobs and parses shares the same way
kaspa-stratum-bridge does.
