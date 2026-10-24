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

A multiplexer behind a channel of another one is opened with $nested.
*/
class Driver:
  // The multiplexer chip. Like an i2c.Device; untyped so tests can pass a fake.
  mux_ := ?
  // Opens upstream devices. Null for nested drivers, which use the root's.
  open_/Lambda?
  // The multiplexer this one is behind, and the channel and address there.
  parent_/Driver?
  parent-channel_/int
  address_/int
  reset-pin_/gpio.Pin?
  // Shared by all drivers of a tree of nested multiplexers.
  mutex_/monitor.Mutex
  // Cached control register. Null if unknown.
  mask_/int? := null
  // Map from address to the shared upstream device. Only used by the root.
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
    check-address_ address
    mux := bus.device address
    return Driver.from-devices_ mux --reset=reset --open=:: bus.device it

  constructor.from-devices_ .mux_ --open/Lambda --reset/gpio.Pin?=null:
    open_ = open
    parent_ = null
    parent-channel_ = 0
    address_ = 0
    mutex_ = monitor.Mutex
    reset-pin_ = reset
    if reset:
      reset.configure --output
      reset.set 1

  constructor.nested_ parent/Driver --channel/int address/int --reset/gpio.Pin?:
    open_ = null
    parent_ = parent
    parent-channel_ = channel
    address_ = address
    mutex_ = parent.mutex_
    reset-pin_ = reset
    mux_ = parent.mutex_.do: parent.open-device_ channel address
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
      // Not the parent's with-channel: the tree's lock is already held.
      select-upstream_
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
  Opens the multiplexer at the given I2C $address behind the given $channel.

  Every transaction of the returned driver, and of the devices opened with its
    $device, first selects the $channel on this multiplexer. All drivers of a
    tree share one lock, so transactions of different tasks are serialized.

  The nested multiplexer keeps its channels enabled while this one talks to
    other devices on the same $channel. Such devices see the chips behind the
    enabled nested channels, so their addresses must not clash; call
    $disable-all on the nested driver before using them.

  The $reset pin is handled as for the main constructor.

  Closing this driver closes the nested one too.

  Throws if a device with the same $address on the same $channel is
    already open.
  */
  nested --channel/int address/int --reset/gpio.Pin?=null -> Driver:
    check-channel_ channel
    check-address_ address
    return Driver.nested_ this --channel=channel address --reset=reset

  /**
  Opens the device at the given I2C $address on the given $channel.

  Throws if a device with the same $address on the same $channel is
    already open.
  */
  device --channel/int address/int -> ChannelDevice:
    check-channel_ channel
    return mutex_.do:
      ChannelDevice.init_ this channel address (open-device_ channel address)

  /**
  Disables all channels and releases the multiplexer and all devices
    opened with $device.

  Does not close the bus or the reset pin.
  */
  close -> none:
    mutex_.do:
      if is-closed_: continue.do
      if parent_ and not parent_.is-open_:
        // The root already released all devices.
        is-closed_ = true
        continue.do
      is-closed_ = true
      try:
        select-upstream_
        mux_.write #[0]
        mask_ = 0
      finally:
        if parent_:
          open-keys_.do: | key/int | release-upstream_ (key & 0xffff)
          open-keys_.clear
          parent_.close-device_ parent-channel_ address_
        else:
          shared_.do --values: | shared/SharedDevice_ | shared.device.close
          shared_.clear
          open-keys_.clear
          mux_.close

  /**
  Runs the $block with only the $channel enabled, and returns its result.

  For a nested driver (see $nested), the path through the parents is
    selected too.

  Holds the lock of the whole tree of multiplexers while running the $block,
    so other tasks can't switch channels in between. Use it for chips whose
    driver doesn't take a $serial.Device, or for transactions that must not be
    interleaved. The $block must not use this driver, the devices opened with
    $device, or any other driver of the tree; the lock isn't reentrant.

  The $channel must be in range 0 to $CHANNEL-COUNT (exclusive).
  */
  with-channel channel/int [block]:
    check-channel_ channel
    return mutex_.do:
      set-mask_ (1 << channel)
      block.call

  release_ channel/int address/int -> none:
    mutex_.do:
      if is-open_: close-device_ channel address

  /**
  Opens the upstream device for the $address on the $channel.

  Caller must hold $mutex_.
  */
  open-device_ channel/int address/int:
    check-open_
    key := (channel << 16) | address
    if open-keys_.contains key: throw "Device already connected"
    device := acquire-upstream_ address
    open-keys_.add key
    return device

  /** Caller must hold $mutex_. */
  close-device_ channel/int address/int -> none:
    key := (channel << 16) | address
    if not open-keys_.contains key: return
    open-keys_.remove key
    release-upstream_ address

  /** Caller must hold $mutex_. */
  acquire-upstream_ address/int:
    if parent_: return parent_.acquire-upstream_ address
    shared/SharedDevice_? := shared_.get address
    if not shared:
      shared = SharedDevice_ (open_.call address)
      shared_[address] = shared
    shared.count++
    return shared.device

  /** Caller must hold $mutex_. */
  release-upstream_ address/int -> none:
    if parent_:
      parent_.release-upstream_ address
      return
    shared/SharedDevice_ := shared_[address]
    shared.count--
    if shared.count == 0:
      shared_.remove address
      shared.device.close

  /**
  Selects the channel this multiplexer is behind, on all its ancestors.

  Caller must hold $mutex_.
  */
  select-upstream_ -> none:
    if parent_: parent_.set-mask_ (1 << parent-channel_)

  /** Caller must hold $mutex_. */
  set-mask_ mask/int -> none:
    check-open_
    select-upstream_
    if mask_ == mask: return
    // If the write fails, the state of the register is unknown.
    mask_ = null
    mux_.write #[mask]
    mask_ = mask

  is-open_ -> bool:
    return not is-closed_ and (not parent_ or parent_.is-open_)

  check-open_ -> none:
    if not is-open_: throw "CLOSED"

  static check-channel_ channel/int -> none:
    if not 0 <= channel < CHANNEL-COUNT: throw "INVALID_ARGUMENT"

  static check-address_ address/int -> none:
    if not I2C-ADDRESS <= address <= I2C-ADDRESS-MAX: throw "INVALID_ARGUMENT"

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
    return driver.with-channel channel block

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
