// Copyright (C) 2026 Girts Folkmanis.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import i2c
import tca9548a

/**
Scans all channels of a TCA9548A and reads a register from a device
  behind channel 0.
*/
main:
  bus := i2c.Bus
      --sda=21
      --scl=22
  mux := tca9548a.Driver bus

  // Devices on the upstream bus are visible on every channel.
  mux.disable-all
  upstream := bus.scan

  tca9548a.CHANNEL-COUNT.repeat: | channel/int |
    mux.select channel
    found := bus.scan.filter: not upstream.contains it
    print "channel $channel: $(found.map: "0x$(%02x it)")"
  mux.disable-all

  // A device behind channel 0, e.g. a BME280 at 0x76.
  device := mux.device --channel=0 0x76
  print "chip id: 0x$(%02x (device.read-reg 0xd0 1)[0])"
  device.close

  mux.close
  bus.close
