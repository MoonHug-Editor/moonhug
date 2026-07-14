# Architecture Notes

Key notes from Jonas Tyroller's (Islanders, Will You Snail, Thronefall)
["Best Code Architectures For Indie Games"](https://www.youtube.com/watch?v=8WqYQ1OwxJ4)
(Aug 2025, 16 min).

Good architecture is an investment in speed, not a shipping requirement. Everything below is advice, not law.

## Packages

- Package — a system, an isolation unit, replaceable public API.
- Packages dependencies usually point downwards.
- Spaghetti inside a package is fine WIP state, spaghetti between packages is not.
- Write every package as if it ships to the next project — even if it never does, the discipline keeps it clean.
- If two systems(health + attack) resist separation, don't force it — make them one package.

## Glue

- Glue — in-engine connections (events, exposed fields) or dedicated glue scripts you never intend to reuse — game managers, system connectors.
- Glue is app-specific and disposable — not written for reuse.
- Glue Package — a PARENT package that imports two or more child packages and wires them together.
- No monolithic glue — many small parents with narrow jobs beat one god-manager. Split glue by domain (enemy, building, day/night).
- Rule of thumb ratio — ~70% reusable packages, ~30% glue parents.

## Dependency rules

- Leaf package — imports nothing of the game, exports one system.
- Parent package — imports children, adds coordination, exports a bigger unit.
- A package's public API usually should be opaque to the user to prevent extra dependencies. Prefer not reaching sub-package internals.
- Dependency Cycles are a merge signal or a design error. Never "fix" one with a callback back up the tree!

## Data

- Each package defines and owns its data types.
- Immutable data (balancing, translations, content) lives OUTSIDE code, in a database the packages read (assets, spreadsheets, scriptable objects).
- If it is game-designed together, store it together — one place per concern, not values scattered across prefabs/scenes, when possible.
- Database-first workflow: design data structures, then the packages that consume them, then the glue.

## Time

- Time enters the tree at the ROOT: the top parent calls child updates in an explicit, chosen order.
- Children never self-schedule — no engine-callback or event-driven execution for gameplay logic (visual-only events are fine).
- Execution order is then readable top-down from the root package.

## Simulation / view

- Two package trees: `sim` (game state + logic, no rendering) and `view` (non-game logic visuals only).
- `view` imports `sim`, read-only — sim is its real-time database. `sim` never imports `view`.
- Every package belongs to exactly one tree; each tree has its own glue and its own data (view data = meshes, animations, VFX).
- Strict time ordering matters in `sim`; `view` just reads.

## moonhug mapping

- Leaf packages: `engine/gfx`, `engine/log`, `engine/serialization`* — no game knowledge.
- `engine` is a glue parent: imports gfx + asset pipeline + components and wires them (materials resolve assets INTO gfx draws).
- `app` and `editor` are top glue: own the frame loop (time enters at the root — `render_world_cameras` is a plain call, not a callback).
- Database: AssetDb pipeline (.mat/.asset/.scene/.meta, guid refs).
- Sim/view split is logical only so far. Physical splitting requires maintenance tax, still logical is worth keeping in mind.
