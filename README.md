# Layout Controller

An Erlang/OTP application for controlling DCC model train layouts via a Roco Z21 command station.

The application communicates with the Z21 over UDP using its binary LAN protocol, and manages individual locomotives as supervised Erlang processes.

## Architecture

```
layout_controller_sup (one_for_one)
  ├── z21_events        event pub/sub bus
  ├── z21_connection    UDP connection to the Z21
  └── train_sup         dynamic supervisor
        └── train       one process per locomotive
```

**z21_protocol** encodes and decodes the Z21 binary protocol. It is stateless and used by z21_connection for all packet handling.

**z21_connection** manages the UDP socket, sends commands to the Z21, and forwards incoming broadcasts (track power, loco state, emergency stop) to z21_events. It sends periodic keep-alive packets to maintain the connection.

**z21_events** is a pub/sub server. Any process can subscribe and receive `{z21_event, Event}` messages. Subscribers are monitored and cleaned up automatically on exit.

**train** is a per-locomotive gen_server that holds the desired speed and direction, sends drive commands through z21_connection, and reacts to Z21 events. Each train is registered via gproc using its DCC address.

**train_sup** is a dynamic supervisor. Locomotives are added and removed at runtime.

The supervisor uses a `one_for_one` strategy. If z21_connection crashes, trains stay alive and re-send their state when the connection is re-established.

## Building and running

```bash
rebar3 compile
rebar3 shell
```

## Configuration

The Z21 IP address is set in `config/sys.config`:

```erlang
[{layout_controller, [{z21_ip, "192.168.0.111"}]}].
```

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
