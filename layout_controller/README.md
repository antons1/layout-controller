# Layout Controller

An Erlang/OTP application for controlling DCC model train layouts via a Roco Z21 command station.

The application communicates with the Z21 over UDP using its binary LAN protocol, and manages individual locomotives as supervised Erlang processes.

I want to use my computer to run model trains, but I don't want to pay for the software to do it. I also want to learn a bit about erlang. What is the simplest solution? Of course to build a system for running trains, in erlang!

It is also a learning project for me to get more familiar with in which ways it makes sense to use Claude, and how best to utilise it. 

The plan is for this to be able to run my own train layot, with whatever hardware I have. I want to create some sort of UI, and I want to be able to use this to automate parts of the layout - e.g. running some background trains, running switches etc. It should also be doable to run against different DCC hardware than z21, but that is a future endeavor.

## Quick start

Prerequisites: [Erlang/OTP 28+](https://www.erlang.org/), [rebar3](https://rebar3.org/), and a Roco Z21 command station on your network. If you want the MQTT interface, install [Mosquitto](https://mosquitto.org/) as well.

```bash
git clone https://github.com/hakon/layout_controller.git
cd layout_controller

# Set your Z21's IP address (find it via the Z21 Maintenance app)
# Edit config/sys.config and change z21_ip if it's not 192.168.0.111

# If you don't have Mosquitto installed, disable MQTT:
# Set {mqtt_enabled, false} in config/sys.config

rebar3 compile
rebar3 shell
```

Once in the shell, turn on track power and drive a train:

```erlang
z21_connection:track_power_on().
train_sup:add_train(3).          % use your locomotive's DCC address
train:set_speed(3, 50).
train:set_direction(3, reverse).
train:stop(3).
```

## Architecture

```
layout_controller_sup (rest_for_one)
  ├── z21_events        event pub/sub bus
  ├── z21_connection    UDP connection to the Z21
  ├── train_sup         dynamic supervisor
  │     └── train       one process per locomotive
  ├── mqtt_broker       manages Mosquitto process (optional)
  └── mqtt_bridge       MQTT client bridging to controller (optional)
```

**z21_protocol** encodes and decodes the Z21 binary protocol. It is stateless and used by z21_connection for all packet handling.

**z21_connection** manages the UDP socket, sends commands to the Z21, and forwards incoming broadcasts (track power, loco state, emergency stop) to z21_events. It sends periodic keep-alive packets to maintain the connection.

**z21_events** is a pub/sub server. Any process can subscribe and receive `{z21_event, Event}` messages. Subscribers are monitored and cleaned up automatically on exit.

**train** is a per-locomotive gen_server that holds the desired speed and direction, sends drive commands through z21_connection, and reacts to Z21 events. Each train is registered via gproc using its DCC address.

**train_sup** is a dynamic supervisor. Locomotives are added and removed at runtime.

**mqtt_broker** manages an embedded Mosquitto MQTT broker as an Erlang port. Only started when `mqtt_enabled` is `true`.

**mqtt_bridge** connects to the MQTT broker and translates between MQTT messages and the internal Erlang API. Publishes train state and track power status, and accepts commands on MQTT topics.

The supervisor uses a `rest_for_one` strategy. If z21_connection crashes, downstream children restart. train_sup is placed before MQTT children so that MQTT failures don't cascade to running trains.

## Building and running

```bash
rebar3 compile
rebar3 shell
```

## Dependencies

- [Erlang/OTP](https://www.erlang.org/) 28+
- [Mosquitto](https://mosquitto.org/) - MQTT broker, must be installed and in PATH (only needed when `mqtt_enabled` is `true`)

Erlang dependencies (`gproc`, `emqtt`) are managed by rebar3 automatically.

## Configuration

Configuration lives in `config/sys.config`:

```erlang
[{layout_controller, [
    {z21_ip, "192.168.0.111"},
    {mqtt_enabled, true},
    {mqtt_port, 1883}
]}].
```

- `z21_ip` - Z21 command station IP address
- `mqtt_enabled` - Start MQTT broker and bridge (default: `true`). Set to `false` for REPL-only development without Mosquitto.
- `mqtt_port` - MQTT broker port (default: `1883`)

## Usage

From the Erlang shell:

```erlang
z21_connection:track_power_on().
train_sup:add_train(3).
train:set_speed(3, 50).
train:set_direction(3, reverse).
train:stop(3).
train:get_state(3).
train_sup:which_trains().
train_sup:remove_train(3).
```

## Tests

```bash
rebar3 eunit
```

Tests use a mock UDP socket and do not require Z21 hardware.
