// Copyright (C) 2026 Girts Folkmanis.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import expect show *
import tca9548a

/** A fake I2C device that logs all operations. */
class FakeDevice:
  address/int
  log/List
  is-closed/bool := false
  register/int := 0

  constructor .address .log:

  write bytes/ByteArray -> none:
    log.add "$(%02x address) write $bytes"
    if address == tca9548a.I2C-ADDRESS: register = bytes[0]

  read size/int -> ByteArray:
    log.add "$(%02x address) read $size"
    if address == tca9548a.I2C-ADDRESS: return #[register]
    return ByteArray size

  read-reg reg/int size/int -> ByteArray:
    log.add "$(%02x address) read-reg $reg $size"
    return ByteArray size

  write-reg reg/int bytes/ByteArray -> none:
    log.add "$(%02x address) write-reg $reg $bytes"

  read-address address-bytes/ByteArray size/int -> ByteArray:
    log.add "$(%02x address) read-address $address-bytes $size"
    return ByteArray size: it + 1

  write-address address-bytes/ByteArray bytes/ByteArray -> none:
    log.add "$(%02x address) write-address $address-bytes $bytes"

  close -> none:
    log.add "$(%02x address) close"
    is-closed = true

class Fixture:
  log/List
  mux/FakeDevice
  driver/tca9548a.Driver
  opened/Map

  constructor:
    fake-log := []
    fake-opened := {:}
    mux = FakeDevice tca9548a.I2C-ADDRESS fake-log
    driver = tca9548a.Driver.from-devices_ mux --open=:: | address/int |
      if fake-opened.contains address: throw "Device already connected"
      device := FakeDevice address fake-log
      fake-opened[address] = device
      device
    log = fake-log
    opened = fake-opened

  take-log -> List:
    result := log.copy
    log.clear
    return result

main:
  test-select
  test-mask
  test-channel-devices
  test-registers
  test-close
  test-invalid
  test-with-channel
  test-nested
  test-nested-close
  print "ok"

test-select:
  f := Fixture
  f.driver.select 3
  expect-equals ["70 write #[0x08]"] f.take-log
  // Cached: no second write.
  f.driver.select 3
  expect-equals [] f.take-log
  f.driver.select 0
  expect-equals ["70 write #[0x01]"] f.take-log

test-mask:
  f := Fixture
  f.driver.enabled-mask = 0x81
  expect-equals ["70 write #[0x81]"] f.take-log
  expect-equals 0x81 f.driver.enabled-mask
  expect-equals ["70 read 1"] f.take-log
  f.driver.disable-all
  expect-equals ["70 write #[0x00]"] f.take-log
  // Resynchronize after an external change.
  f.mux.register = 0x02
  expect-equals 0x02 f.driver.enabled-mask
  f.take-log
  f.driver.select 1
  expect-equals [] f.take-log

test-channel-devices:
  f := Fixture
  a := f.driver.device --channel=0 0x40
  b := f.driver.device --channel=5 0x40
  c := f.driver.device --channel=5 0x41
  expect-equals 5 b.channel
  expect-equals 0x40 b.address
  // Same address on different channels shares the upstream device.
  expect-equals 2 f.opened.size
  expect-throw "Device already connected": f.driver.device --channel=0 0x40

  a.write #[1, 2]
  b.read 2
  c.write-reg 7 #[3]
  a.read-reg 9 1
  a.read-reg 9 1
  expect-equals [
    "70 write #[0x01]",
    "40 write #[0x01, 0x02]",
    "70 write #[0x20]",
    "40 read 2",
    "41 write-reg 7 #[0x03]",
    "70 write #[0x01]",
    "40 read-reg 9 1",
    "40 read-reg 9 1",
  ] f.take-log

  a.close
  a.close
  expect-throw "CLOSED": a.read 1
  expect-not f.opened[0x40].is-closed
  b.close
  expect f.opened[0x40].is-closed
  expect-not f.opened[0x41].is-closed
  // Can be reopened after closing.
  f.opened.remove 0x40
  a = f.driver.device --channel=0 0x40
  expect-equals 2 f.opened.size

test-registers:
  f := Fixture
  d := f.driver.device --channel=2 0x40
  regs := d.registers
  expect-equals 0x0201 (regs.read-u16-le 0x10)
  regs.write-u8 0x11 0xab
  expect-equals [
    "70 write #[0x04]",
    "40 read-address #[0x10] 2",
    "40 write #[0x11, 0xab]",
  ] f.take-log

test-close:
  f := Fixture
  a := f.driver.device --channel=1 0x40
  a.read 1
  f.take-log
  f.driver.close
  expect-equals [
    "70 write #[0x00]",
    "40 close",
    "70 close",
  ] f.take-log
  expect-throw "CLOSED": a.read 1
  expect-throw "CLOSED": f.driver.select 0
  expect-throw "CLOSED": f.driver.device --channel=0 0x41
  // Closing again, and closing a device after the driver, are no-ops.
  f.driver.close
  a.close
  expect-equals [] f.take-log

test-invalid:
  f := Fixture
  expect-throw "INVALID_ARGUMENT": f.driver.select -1
  expect-throw "INVALID_ARGUMENT": f.driver.select 8
  expect-throw "INVALID_ARGUMENT": f.driver.enabled-mask = 0x100
  expect-throw "INVALID_ARGUMENT": f.driver.device --channel=8 0x40
  expect-throw "NO_RESET_PIN": f.driver.reset
  expect-equals [] f.take-log

test-with-channel:
  f := Fixture
  result := f.driver.with-channel 6:
    f.log.add "block"
    42
  expect-equals 42 result
  expect-equals ["70 write #[0x40]", "block"] f.take-log
  expect-throw "INVALID_ARGUMENT": f.driver.with-channel 8: null

  inner := f.driver.nested --channel=2 0x71
  inner.with-channel 3: f.log.add "block"
  expect-equals ["70 write #[0x04]", "71 write #[0x08]", "block"] f.take-log

test-nested:
  f := Fixture
  inner := f.driver.nested --channel=2 0x71
  expect-equals 1 f.opened.size
  expect-throw "Device already connected": f.driver.device --channel=2 0x71
  expect-throw "Device already connected":
    f.driver.nested --channel=2 0x71
  // Upstream devices are shared with the parent.
  a := inner.device --channel=3 0x44
  b := f.driver.device --channel=0 0x44
  expect-equals 2 f.opened.size

  a.read 2
  a.read 2
  b.read 2
  a.read 2
  inner.select 1
  expect-equals [
    "70 write #[0x04]",
    "71 write #[0x08]",
    "44 read 2",
    "44 read 2",
    "70 write #[0x01]",
    "44 read 2",
    "70 write #[0x04]",
    "44 read 2",
    "71 write #[0x02]",
  ] f.take-log

  // Doubly nested.
  inner2 := inner.nested --channel=1 0x72
  c := inner2.device --channel=7 0x45
  inner.select 7
  f.driver.select 7
  f.take-log
  c.read 1
  expect-equals [
    "70 write #[0x04]",
    "71 write #[0x02]",
    "72 write #[0x80]",
    "45 read 1",
  ] f.take-log

test-nested-close:
  f := Fixture
  inner := f.driver.nested --channel=2 0x71
  a := inner.device --channel=3 0x44
  b := f.driver.device --channel=0 0x44
  b.read 1
  f.take-log
  inner.close
  expect-equals [
    "70 write #[0x04]",
    "71 write #[0x00]",
    "71 close",
  ] f.take-log
  expect-throw "CLOSED": a.read 1
  expect-throw "CLOSED": inner.select 0
  // Still used by the parent.
  expect-not f.opened[0x44].is-closed
  b.close
  expect f.opened[0x44].is-closed
  // The address can be reopened on the parent.
  f.opened.clear
  f.driver.device --channel=2 0x71

  // Closing the parent closes the nested driver.
  f = Fixture
  inner = f.driver.nested --channel=2 0x71
  a = inner.device --channel=3 0x44
  f.driver.close
  f.take-log
  expect-throw "CLOSED": a.read 1
  expect-throw "CLOSED": inner.select 0
  inner.close
  a.close
  expect-equals [] f.take-log
