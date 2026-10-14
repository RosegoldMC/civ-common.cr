# rosegold-civ-common

Opt-in helpers for Civ servers. This shard has no Rosegold dependency and no access to blocks, entities, packets, or the client. Server libraries include `Rosegold::CivCommon::Helpers` only when their rules permit its observations and actions.

```yaml
dependencies:
  rosegold-civ-common:
    github: RosegoldMC/civ-common.cr
    version: ~> 0.1.1
```

```crystal
require "rosegold-civ-common"
```

## Known elevators

`bot.elevator(target_y, timeout_ticks: 1200, cancellation: nil)` uses jump to ascend and five ticks of sneak to descend, with twenty ticks between attempts. The caller must already be standing at a known elevator and supply its destination. Click-configured elevators need a separate adapter.

Arrival means the player's own Y coordinate is within `0.01` of the destination. Ten unchanged attempts are tolerated. Falling more than one block below the lower endpoint stops the ride. Failures raise `Rosegold::CivCommon::MovementError`; its `reason` distinguishes stalls, falls, timeout, cancellation, and disconnect. The helper releases its queued jump and any sneak input it started, including after exceptions.

## XP items

`bot.raise_level_with(item_name, target_level, timeout_ticks: 1200, cancellation: nil)` selects a carried item, looks upward, and taps use every two ticks. It returns `Rosegold::CivCommon::ExperienceResult` with `completed?`, `reason`, and the observed `final_level`. It assumes no XP yield and stops on depletion, a changed hand or selected slot, disconnect, timeout, or cancellation.

The helper restores the original pitch and selected slot when connected, unless another operation changed them. It does not undo inventory swaps made while selecting the item. It never crafts, withdraws, or repairs items.

## Adapter contract

Include the module in a server facade implementing:

- Connection and waiting: `connected?`, `wait_tick`.
- Elevator controls: `y`, `start_jump`, `stop_jump`, `sneaking?`, `sneak`, `unsneak`.
- XP controls: `pitch`, `pitch=`, `hotbar_selection`, `hotbar_selection=`, `experience_level`, `use_hand`, `stop_using_hand`.
- Inventory: `inventory.pick(name)`, `inventory.count(name)`, and `inventory.main_hand` with `name` and `empty?`.

`wait_tick` must return within one second, including on disconnect or absent ticks. All input and inventory methods must also be bounded. Helpers cap wait calls at `timeout_ticks` and check a monotonic deadline of `timeout_ticks / 20` seconds between calls. A blocked adapter call can overshoot that deadline by its own timeout.

Give each helper exclusive control of movement, look, inventory selection, and item use. Do not start another helper or hold use concurrently. `use_hand` must queue one tap; `stop_using_hand` must cancel pending helper use. Callbacks that invoke a waiting helper must spawn their work rather than block the tick emitter.

For cooperative cancellation, pass a `Rosegold::CivCommon::Cancellation` and call `cancel` from another fiber. Cancellation is checked before inputs and between waits. Unexpected adapter exceptions propagate after cleanup.

Server libraries choose which helpers to expose. A server that prohibits reading the player's location cannot expose this elevator implementation.

## Development

Run `crystal spec` and `crystal tool format --check`. Specs simulate progress, interruptions, and cleanup without a Minecraft server. They do not establish live plugin compatibility.
