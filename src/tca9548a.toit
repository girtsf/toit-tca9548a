// Copyright (C) 2026 Girts Folkmanis.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import i2c
import serial.device as serial
import .driver

export *

/**
Driver for the TI TCA9548A (and the compatible PCA9548A) 8-channel I2C
  multiplexer.

# Usage
Construct a $Driver on the upstream $i2c.Bus. Pass `--address` to match the
  A0-A2 pins: $I2C-ADDRESS (0x70, all low) up to $I2C-ADDRESS-MAX (0x77, all
  high). Then open the chips behind the multiplexer with $Driver.device. The
  returned $ChannelDevice has the same transaction methods as $i2c.Device and
  implements $serial.Device, so it can be passed to most existing drivers.

Every transaction on a $ChannelDevice first enables its channel and disables
  all others. Transactions of different tasks are serialized, so chips with
  the same address on different channels can be used concurrently. The driver
  caches the control register and only writes it when the channel changes.

Chips at the same address share one $i2c.Device, as Toit doesn't allow more
  than one device with the same address on the same bus.

A multiplexer behind a channel of another one is opened with
  $Driver.nested. Its transactions first select that channel on the parent.

$Driver.with-channel runs a block with a channel selected and the lock held,
  for chips whose driver doesn't take a $serial.Device, or for transactions
  that must not be interleaved with other tasks.

For manual control (for example to scan a channel with $i2c.Bus.scan), use
  $Driver.select, $Driver.enabled-mask, $Driver.disable-all, and
  $Driver.reset.

# Limitations
Chips on the upstream bus, including the multiplexer itself, answer on every
  channel. A downstream chip must not use an address that is also used
  upstream.

When several multiplexers share an upstream bus, their enabled channels are
  connected in parallel. The driver does not coordinate between multiplexers;
  at most one of them should have channels enabled at a time. Nested
  multiplexers (see $Driver.nested) are the exception: the parent's
  channel isolates them.

A nested multiplexer keeps its channels enabled while the parent talks to
  other devices on the same channel. Their addresses must not clash with the
  chips behind the enabled nested channels.

The cached control register is only valid if no one else writes it. After an
  external change (another program, or a brown-out of the chip), call
  $Driver.enabled-mask to resynchronize.

# Errors
Operations throw "CLOSED" after $Driver.close, and "INVALID_ARGUMENT" for
  channels outside 0 to $CHANNEL-COUNT (exclusive). Opening the same address
  on the same channel twice throws "Device already connected". Bus errors
  (like "I2C_NACK") are propagated from the $i2c.Device.

# Examples
```
import i2c
import tca9548a

main:
  bus := i2c.Bus --sda=21 --scl=22
  mux := tca9548a.Driver bus

  // Two chips with the same address on different channels.
  left := mux.device --channel=0 0x76
  right := mux.device --channel=1 0x76
  print (left.read-reg 0xd0 1)
  print (right.read-reg 0xd0 1)

  mux.close
  bus.close
```
*/
