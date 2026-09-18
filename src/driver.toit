// Copyright (C) 2026 Girts Folkmanis.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import gpio
import i2c
import io
import monitor
import serial.device as serial
import serial.registers as serial

/** Default I2C address of the TCA9548A (A0, A1 and A2 tied low). */
I2C-ADDRESS ::= 0x70

/** Highest I2C address of the TCA9548A (A0, A1 and A2 tied high). */
I2C-ADDRESS-MAX ::= 0x77

/** Number of downstream channels. */
CHANNEL-COUNT ::= 8

/**
Driver for the TCA9548A 8-channel I2C multiplexer.

Opens chips behind the multiplexer with $device, and controls the channels
  manually with $select and $enabled-mask.
*/
class Driver:
  mux_ := ?
  open_/Lambda
  reset-pin_/gpio.Pin?
  mutex_/monitor.Mutex ::= monitor.Mutex
  // Cached control register. Null if unknown.
  mask_/int? := null
  // Map from address to the shared upstream device.
  shared_/Map ::= {:}
  // Set of (channel, address) keys of open channel devices.
  open-keys_/Set ::= {}
  is-closed_/bool := false

  /**
  Constructs a driver for the multiplexer on the given $bus at the given
    $address.

  If a $reset pin is given, it is configured as output and driven high. It
    is then used by $reset. Without a $reset pin, the chip's RESET pin must be
    pulled high; a floating RESET keeps the chip in reset.

  The driver does not take ownership of the $bus or the $reset pin.
  */
  constructor bus/i2c.Bus --address/int=I2C-ADDRESS --reset/gpio.Pin?=null:
    if not I2C-ADDRESS <= address <= I2C-ADDRESS-MAX: throw "INVALID_ARGUMENT"
    mux := bus.device address
    return Driver.from-devices_ mux --reset=reset --open=:: bus.device it

  /**
  Constructs a driver from the multiplexer device $mux_.

  The $open lambda is called with an I2C address and must return a device
    with the same interface as $i2c.Device.

  Takes ownership of $mux_.
  */
  constructor.from-devices_ .mux_ --open/Lambda --reset/gpio.Pin?=null:
    open_ = open
    reset-pin_ = reset
    if reset:
      reset.configure --output
      reset.set 1

  /**
  Enables only the given $channel.

  The $channel must be in range 0 to $CHANNEL-COUNT (exclusive).
  */
  select channel/int -> none:
    check-channel_ channel
    mutex_.do: set-mask_ (1 << channel)

  /**
  Enables exactly the channels whose bits are set in the $mask.

  Bit 0 corresponds to channel 0. A $mask of 0 disables all channels.
  */
  enabled-mask= mask/int -> none:
    if not 0 <= mask <= 0xff: throw "INVALID_ARGUMENT"
    mutex_.do: set-mask_ mask

  /**
  Reads the control register from the chip.

  Returns a mask where bit n is set if channel n is enabled.
  */
  enabled-mask -> int:
    return mutex_.do:
      check-open_
      mask_ = null
      mask := (mux_.read 1)[0]
      mask_ = mask
      mask

  /** Disables all channels. */
  disable-all -> none:
    enabled-mask = 0

  /**
  Pulses the reset pin, disabling all channels.

  Throws if no reset pin was given to the constructor.
  */
  reset -> none:
    if not reset-pin_: throw "NO_RESET_PIN"
    mutex_.do:
      check-open_
      mask_ = null
      reset-pin_.set 0
      sleep --ms=1
      reset-pin_.set 1
      mask_ = 0

  /**
  Opens the device at the given I2C $address on the given $channel.

  Throws if a device with the same $address on the same $channel is
    already open.
  */
  device --channel/int address/int -> ChannelDevice:
    check-channel_ channel
    return mutex_.do:
      check-open_
      key := (channel << 16) | address
      if open-keys_.contains key: throw "Device already connected"
      shared/SharedDevice_? := shared_.get address
      if not shared:
        shared = SharedDevice_ (open_.call address)
        shared_[address] = shared
      shared.count++
      open-keys_.add key
      ChannelDevice.init_ this channel address shared.device

  /**
  Disables all channels and releases the multiplexer and all devices
    opened with $device.

  Does not close the bus or the reset pin.
  */
  close -> none:
    mutex_.do:
      if is-closed_: continue.do
      is-closed_ = true
      try:
        mux_.write #[0]
        mask_ = 0
      finally:
        shared_.do --values: it.device.close
        shared_.clear
        open-keys_.clear
        mux_.close

  /**
  Runs the $block with only the $channel enabled.

  Holds the lock while running the $block.
  */
  with-channel_ channel/int [block]:
    return mutex_.do:
      check-open_
      set-mask_ (1 << channel)
      block.call

  release_ channel/int address/int -> none:
    mutex_.do:
      if is-closed_: continue.do
      key := (channel << 16) | address
      if not open-keys_.contains key: continue.do
      open-keys_.remove key
      shared/SharedDevice_ := shared_[address]
      shared.count--
      if shared.count == 0:
        shared_.remove address
        shared.device.close

  /** Caller must hold $mutex_. */
  set-mask_ mask/int -> none:
    check-open_
    if mask_ == mask: return
    // If the write fails, the state of the register is unknown.
    mask_ = null
    mux_.write #[mask]
    mask_ = mask

  check-open_ -> none:
    if is-closed_: throw "CLOSED"

  static check-channel_ channel/int -> none:
    if not 0 <= channel < CHANNEL-COUNT: throw "INVALID_ARGUMENT"

class SharedDevice_:
  device ::= ?
  count/int := 0

  constructor .device:

/**
A device behind a TCA9548A channel.

Mirrors the transaction methods of $i2c.Device. Each transaction first
  selects the device's channel on the multiplexer.
*/
class ChannelDevice implements serial.Device:
  /** The multiplexer channel of this device. */
  channel/int
  /** The I2C address of this device. */
  address/int

  driver_/Driver? := ?
  device_ := ?
  registers_/ChannelRegisters_? := null

  constructor.init_ .driver_ .channel .address .device_:

  /**
  See $serial.Device.registers.

  The $byte-size and $byte-order describe the register address, as for
    $i2c.Device.registers.
  */
  registers --byte-size/int=1 --byte-order/io.ByteOrder=io.BIG-ENDIAN -> serial.Registers:
    if byte-size <= 0: throw "OUT_OF_RANGE"
    if not registers_:
      registers_ = ChannelRegisters_ this --byte-size=byte-size --byte-order=byte-order
    else if registers_.byte-size_ != byte-size or registers_.byte-order_ != byte-order:
      return ChannelRegisters_ this --byte-size=byte-size --byte-order=byte-order
    return registers_

  /** See $i2c.Device.write. */
  write bytes/ByteArray -> none:
    with-channel_: device_.write bytes

  /** See $i2c.Device.write-reg. */
  write-reg register/int bytes/ByteArray -> none:
    with-channel_: device_.write-reg register bytes

  /** See $i2c.Device.write-address. */
  write-address address/ByteArray bytes/ByteArray -> none:
    with-channel_: device_.write-address address bytes

  /** See $i2c.Device.read. */
  read size/int -> ByteArray:
    return with-channel_: device_.read size

  /** See $i2c.Device.read-into. */
  read-into buffer/ByteArray size/int=buffer.size -> none:
    with-channel_: device_.read-into buffer size

  /** See $i2c.Device.read-reg. */
  read-reg register/int size/int -> ByteArray:
    return with-channel_: device_.read-reg register size

  /** See $i2c.Device.read-address. */
  read-address address/ByteArray size/int -> ByteArray:
    return with-channel_: device_.read-address address size

  /** See $i2c.Device.write-read. */
  write-read tx-buffer/io.Data size/int -> ByteArray:
    return with-channel_: device_.write-read tx-buffer size

  /** See $i2c.Device.write-read-into. */
  write-read-into --tx-buffer/io.Data --rx-buffer/ByteArray size/int=rx-buffer.size -> none:
    with-channel_:
      device_.write-read-into --tx-buffer=tx-buffer --rx-buffer=rx-buffer size

  /**
  Closes this device.

  The underlying $i2c.Device is closed once no other channel uses the same
    address.
  */
  close -> none:
    if not driver_: return
    driver := driver_
    driver_ = null
    device_ = null
    driver.release_ channel address

  with-channel_ [block]:
    driver := driver_
    if not driver: throw "CLOSED"
    return driver.with-channel_ channel block

class ChannelRegisters_ extends serial.Registers:
  device_/ChannelDevice

  constructor .device_ --byte-size/int --byte-order/io.ByteOrder:
    super --byte-size=byte-size --byte-order=byte-order

  read-bytes register/int count/int -> ByteArray:
    return device_.read-address (address-bytes_ register) count

  write-bytes register/int bytes/ByteArray -> none:
    device_.write-address (address-bytes_ register) bytes

  write-bytes_ bytes/ByteArray -> none:
    device_.write bytes

  address-bytes_ register/int -> ByteArray:
    if not 0 <= register < (1 << (byte-size_ * 8)): throw "OUT_OF_RANGE"
    result := ByteArray byte-size_
    byte-order_.put-uint result byte-size_ 0 register
    return result
