# TCA9548A

Toit driver for the TI TCA9548A 8-channel I2C multiplexer (also PCA9548A).

## Usage

```toit
import i2c
import tca9548a

main:
  bus := i2c.Bus --sda=21 --scl=22
  mux := tca9548a.Driver bus  // Address 0x70..0x77, default 0x70.

  // Two sensors with the same address on different channels.
  left := mux.device --channel=0 0x76
  right := mux.device --channel=1 0x76
  print (left.read-reg 0xd0 1)
  print (right.read-reg 0xd0 1)

  mux.close
  bus.close
```

A `ChannelDevice` mirrors the transaction methods of `i2c.Device` (`read`,
`write`, `read-reg`, `write-reg`, `write-read`, `registers`, ...) and
implements `serial.Device`, so most drivers that take a `serial.Device` work
unchanged. Every transaction selects the device's channel first; the driver
caches the control register and only writes it when the channel changes.
Devices with the same address on different channels share one upstream
`i2c.Device`.

`with-channel ch: ...` runs a block with the channel selected and the lock
held, e.g. for a multi-step transaction or a chip on a plain `i2c.Device`.

Manual channel control: `select`, `enabled-mask`, `enabled-mask=`,
`disable-all`, and `reset` (with `--reset` pin).

Nested multiplexers can be instantiated with `mux.nested --channel=2 0x71`,
lock the whole bus on operations and select parent channels automatically.

Limitations:
- A downstream address must not also be used on the upstream bus.
- With several multiplexers on one bus, only one should have channels
  enabled at a time; the driver does not coordinate between them. Nested
  multiplexers are isolated by the parent's channel.
- A nested multiplexer keeps its channels enabled while the parent talks to
  other devices on the same channel; their addresses must not clash.

See `examples/i2c.toit` for a channel scan.

## AI Disclosure

Robots wrote most of this.
