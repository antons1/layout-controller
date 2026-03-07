# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Erlang/OTP application that controls DCC model train layouts via a Roco Z21 command station. Communicates with the Z21 over UDP (port 21105) using its binary LAN protocol.

### Future development to keep in mind when doing architecture decisions

* DCC is the standard that is most important
* The application should be able to support other DCC command stations in the future
* It should be able to operate other DCC peripherals than trains in the future

### Development process

* Make small changes and commit often
* Ask before making architecture decisions

## Build & Run

```bash
rebar3 compile              # compile the project
rebar3 shell                # start an interactive shell with the app running
```

No test suite exists yet. The app requires a physical Z21 command station on the network.

## Configuration

Z21 IP address is configured in `config/sys.config` (default: `192.168.0.111`).

## Architecture

**Supervision tree** (`layout_controller_sup`, `rest_for_one` strategy):

```
layout_controller_sup
  ├── z21_events        - pub/sub event bus (gen_server)
  ├── z21_connection    - UDP connection to Z21 (gen_server)
  └── train_sup         - dynamic supervisor for train processes
        └── train       - one gen_server per locomotive (simple_one_for_one)
```

`rest_for_one` ensures that if `z21_events` or `z21_connection` crash, downstream dependents restart too.

**Key modules:**

- `z21_protocol` - Stateless encode/decode of the Z21 binary LAN protocol. All packet construction and parsing lives here.
- `z21_connection` - Manages the UDP socket, keep-alive (30s interval), and dispatches incoming Z21 broadcasts to `z21_events`.
- `z21_events` - Pub/sub: processes call `z21_events:subscribe()` to receive `{z21_event, Event}` messages. Monitors subscribers and cleans up on process death.
- `train` - Per-locomotive gen_server. Holds desired speed/direction, sends drive commands via `z21_connection`, and reacts to Z21 events (power off, emergency stop, loco info updates). Registered via gproc with name `{n, l, {train, Address}}`.
- `train_sup` - Dynamic supervisor. Use `train_sup:add_train(Address)` / `remove_train(Address)` to manage locomotives at runtime.

**Dependencies:** `gproc` (process registry for dynamic train name lookup).

## Interactive Usage (in rebar3 shell)

```erlang
z21_connection:track_power_on().
train_sup:add_train(3).
train:set_speed(3, 50).
train:set_direction(3, reverse).
train:stop(3).
train_sup:which_trains().
```
