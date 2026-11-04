# Log Format v1

Live recordings use UTF-8 JSON Lines (`.canlog.jsonl`): one JSON object followed
by `\n` per record. The first line is a `header`. Writers emit nondecreasing
`t_ns` values measured in nanoseconds from the recording start. Boolean frame
flags are omitted when false; readers ignore unknown properties and record
types.

The schema is [can-log-v1.schema.json](../schema/can-log-v1.schema.json).

## Header

```json
{"type":"header","format":"can_dbz_vis/log","version":1,"created_utc":"2026-11-04T10:15:30.123456789Z","tool":"can_dbz_vis 0.1.0","database":{"file":"vehicle.dbc","sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},"buses":[{"index":0,"name":"powertrain","backend":"socketcan","channel":"vcan0","bitrate":500000,"fd":false,"timestamps":"software"}]}
```

`database` is either `null` or the database basename plus its SHA-256 content
hash. Bus indices are the logical database bus indices used by subsequent
records. The optional `data_bitrate` is present for CAN FD buses.

## Records

Frame records contain `dir` (`rx` or `tx`), an uppercase hexadecimal `id`
without a prefix, `len`, and uppercase hexadecimal `data`. `ext`, `fd`, `brs`,
`esi`, `rtr`, and `echo` are optional booleans. A `tx` frame also has a `status`:
`ok`, `queue_full`, `bus_off`, or `error`. `ok` means accepted by the driver or
kernel transmit queue; it does not mean the frame was acknowledged on the bus.

Error frames use `type: "error_frame"`, a bus index, a class string, and raw
hexadecimal data. Events use `type: "event"` with an event name and optional
bus, state, or dropped count. Markers contain user text and a timestamp. A
footer summarizes records, frames, and dropped records; it is optional, so a
truncated recording remains readable through its last complete line.

```json
{"type":"frame","t_ns":1523000123,"bus":0,"dir":"rx","id":"0C0","len":8,"data":"1D095800FF000000"}
{"type":"frame","t_ns":1524000000,"bus":0,"dir":"tx","id":"100","len":8,"data":"7800020000000000","status":"ok"}
{"type":"event","t_ns":1532000000,"bus":0,"event":"rx_overflow","dropped":17}
{"type":"marker","t_ns":1540000000,"text":"engine start"}
{"type":"footer","t_ns":3600000000000,"records":144,"frames":140,"dropped":0}
```

Each line is independently parseable. Readers stop at an incomplete final line,
skip malformed complete lines, and continue to ignore unknown record types for
forward compatibility. Replay uses the same decoded records as live ingest.
The optional footer is written only after a clean recording shutdown.
