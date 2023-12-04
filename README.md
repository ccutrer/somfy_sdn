# Somfy SDN Gem

This gem is a Ruby library for interacting with Somfy RS-485 motorized shades.
Both older ST50 shades speaking ILT2 protocol and newer shades (ST30, LT50)
are supported. There is very little documentation on the protocol, and it has
been further reverse engineered by various individuals by various means:
 * capturing traffic from a Somfy UAI+
 * capturing traffic various Somfy configuration tools
 * referencing the output of the Somfy SDN Frame Builder tool

If you're really just interested in the protocol, and not this library or
utilities, take a look at [the protocol reference](doc/protocol.md).

## Installation

Install ruby first, then:

```sh
gem install somfy_sdn
```

## Provisioning

A utility is provided to provision a motor (set a label, set up limits).

It's likely easiest to connect directly to the shade you're going to provision,
or you can connect to a full bus network, but you'll want to provide the address
of the motor you want to configure if you do that.

```sh
somfy_sdn provision /path/to/serial_port
```

```sh
somfy_sdn provision /path/to/serial_port AB.CD.EF
```

One major caveat is that for ILT2 motors, there's not a way to ask the motor
if rotation direction has been reversed, but you need to know that in order
to set limits. So it's recommended that if you need to reverse the motor,
press reverse, then jog up. If it didn't reverse, jog back down to restore
your initial position, hit lower case `r` to restore the position memory
(relative to the limits), then use capital `R` instead of lowercase `r` to
reverse direction without re-calculating position. This will get the
provisioning utility to the point that it knows what direction the motor is
running.

## MQTT/Homie Bridge

An MQTT Bridge is provided to allow easy integration with other systems. You
will need a separate MQTT server running ([Mosquitto](https://mosquitto.org) is
a relatively easy and robust one). The MQTT topics follow the [Homie
convention](https://homieiot.github.io), making them self-describing. If you're
using a systemd Linux distribution, an example unit file is provided in
`contrib/sdn_mqtt_bridge.service`. So a full example would be (once you have
Ruby installed):

```sh
sudo curl https://github.com/ccutrer/somfy_sdn/raw/master/contrib/sdn_mqtt_bridge.service -L -o /etc/systemd/system/sdn_mqtt_bridge.service
<modify the file to pass the correct URI to your MQTT server, and path to RS-485 device>
sudo systemctl enable sdn_mqtt_bridge
sudo systemctl start sdn_mqtt_bridge
```

Once you have it connected and running, you'll like want to Publish `true` to
`homie/sdn/discovery/discover/set` to kick off the discovery process and find
existing motors. When motors are commanded to move, it will automatically poll
their status and position until they stop. This also works for groups.

Note that several properties support additional value payloads than Homie would
otherwise define in order to access additional features:

 * <node>/positionpercent: UP, DOWN, and STOP are supported to allow directly
   connecting a single OpenHAB Rollershutter item to it.
 * <node>/downlimit and <node>/uplimit also support `delete`,
   `current_position`, `jog_ms`, and `jog_pulses` in addition to a specified
   position in pulses. For the two jog options, an distance of 10 (ms/pulses)
   is assumed.
 * <node>/ip<number>pulses and <node>/ip<number>percent also support `delete`
   and `current_position`.

Other properties of note:
 * <node>/groups is a comma separated list of group addresses. Groups have
   addresses from 01.01.01 to 01.01.FF. A motor can be a member of up to 16
   groups. Be aware that if you have a UAI+ also on the network, it does
   NOT query group membership from motors, and instead keeps everything cached
   locally, so will not reflect any changes you make outside its control.
   Groups also don't have names.

## OpenHAB
If you're going to integrate with OpenHAB, you'll need to install the
`MQTT Binding` in `Add-ons`. Then go to Inbox, click `+`, select `MQTT Binding`
and click `ADD MANUALLY` near the bottom. First create a Thing for the
`MQTT Broker` and configure it to point to your MQTT server. At this point you
can create a `Homie MQTT Device`, but I don't recommend it because OpenHAB
Homie nodes as channel groups instead of individual things, and this can become
quite cluttered if you have many shades. Instead, you go for generic MQTT
things, and configure them manually.

Example Things file:
```
Thing mqtt:topic:072608 "Master Bedroom Shade" (mqtt:broker:hiome) @ "Master Bedroom"
{
  Channels:
    Type rollershutter : shade "Shade"
      [
        stateTopic = "homie/somfy/072608/positionpercent",
        commandTopic = "homie/somfy/072608/positionpercent/set"
      ]
}
```

Example Items file (including configuration for exposing to HomeKit):

```
Rollershutter MasterShade_Rollershutter "Master Bedroom Shade" [ "WindowCovering" ] { channel="mqtt:topic:072608:shade", autoupdate="false" }
```

Example Rules file for maintaining HomeKit state:

Example sitemap snippet:
```
Text label="Master Bedroom" icon=bedroom {
        Frame {
                Default item=MasterShade_Rollershutter label="Shade"
        }
}
```

## Connecting via RS-485

This gem supports using an RS-485 direct connection. It is possible to directly
connect to the GPIO on a Raspberry Pi, or to use a USB RS-485 dongle such as
[this one from Amazon](https://www.amazon.com/gp/product/B07B416CPK).
Any adapter based on the MAX485 chip is _not_ supported.
The key is identifying the correct wires as RS-485+ and RS-485-.
It's easiest to connect to the Data Pass-through port of the Bus Power Supply
using an ethernet patch cable. You'll cut off the other end, and connect pins
1 and 2 (white/orange and orange for a TIA-568-B configured cable) to + and -
on your dongle:

![Bus Connection](doc/bus.jpg)
![RS-485 Dongle](doc/rs485dongle.jpg)

For an ST50 ILT2 motor with an RJ9 connector, the pins are as follows:

Pin 1: RS-485-
Pin 2: GND
Pin 3: +5VDC
Pin 4: RS-485+

For a newer LT50 motor with an RJ9 connector, crazily Somfy changed the pinout. The pins are as follows:

Pin 1: RS-485+
Pin 2: RS-485-
Pin 3: +5VDC
Pin 4: GND

## Non-local Serial Ports

Serial ports over the network are also supported. Just give a URI like
tcp://192.168.1.10:2000/ instead of a local device. Be sure to set up your
server (like ser2net) to use 4800 baud, ODD. You can also use RFC2217 serial
ports (allowing the serial connection parameters to be set automatically) with
a URI like telnet://192.168.1.10:2217/. Finally, if you're really into hacking,
you can automatically create a virtual serial port by specifying /dev/ptmx.
It will print out the path for a newly created virtual serial port for another
program to connect to. This can be useful for running the motor simulator,
and having a Somfy utility connect to it to capture its traffic (in this case
you'll probably be running the simulator on a Linux computer, and the Somfy
software on a Windows computer, and you'll need to use com2com on the Windows
side to create a virtual serial port of the network).

## Motor Simulator

*INCOMPLETE*. Run the simulator, and it will act like it's a motor. Useful
for deciphering protocols.

```sh
sdn_simulator /path/to/serial_port AB.CD.EF
```

## Capturing Traffic

To capture and print traffic from a live network (i.e. with a UAI+ or ZDMI attached),
without sending to MQTT, just run the bridge with no URL for the MQTT connection:

```sh
sdn_mqtt_bridge "" /path/to/serial_port
```

## Related Projects

These projects are all in various states, and may be more or less developed than this one in varying aspects.

 * https://blog.baysinger.org/2016/03/somfy-protocol.html
 * https://github.com/bhlarson/CurtainControl
