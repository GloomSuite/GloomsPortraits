# Gloom's Portraits — project guide

> **▶ PART OF THE GLOOM SUITE.** Gloom's Portraits is the suite's fifth tool, alongside Gloom's
> Bars, Auras and Overlays, under the shared base addon **GloomsHub** (`~/GloomsHub`). All
> cross-cutting suite facts — the plan, current state, and shared runtime contracts (design
> tokens, the tabbed-shell API, the media resolver) — live THERE and are the single source of
> truth; this repo does not keep its own copy. **Before any *suite* work read
> `~/GloomsHub/docs/BACKLOG.md` first**, then SUITE-STATE.md, FINDINGS.md and CONTRACTS.md as
> needed. Normal Portraits-only work proceeds here as usual.
> **Gloom's Build Barn is NOT in the suite.**

> ## ★★ ONE PROJECT, FIVE REPOS — the owner works from `~/GloomsHub`
> **He opens GloomsHub and nothing else, ever.** This repo gets edited from a Hub session
> routinely — **that is correct, not a violation. Never tell him to close a project and open
> another one.** Before any change, decide which repo OWNS it and say so in one line, up front.
>
> **Belongs HERE (`~/GloomsPortraits`):** the model/portrait frames, their placement, sizing,
> rotation, show conditions, and the contents of the Portraits tab.
> **Belongs in `~/GloomsHub`:** the Suite window + tab API · the shared `LibGloomSkin` toolkit ·
> media registration/resolver · the one minimap launcher · the suite docs and backlog.
> Full rule + ownership table: `~/GloomsHub/CLAUDE.md`.

Bespoke WoW addon: free-floating **3D full-body models** or **2D circular portraits** for the
player and the target. Each is placeable (drag when unlocked, or nudge), sizeable, rotatable
(facing + pitch), zoomable, on a chosen strata, with a show condition (always / in combat /
target selected / combat or target). Target: **Midnight 12.1** (Interface `120100`), retail only.

## Where it came from — and the ONE privacy rule

This grew out of a single-file addon that lived only in the client's AddOns folder, with no
repo. It was brought into the suite on **2026-09-19** and renamed. **The old name is NOT
publishable** — the PRIVACY section of `~/GloomsHub/CLAUDE.md` says why, and the same rule
already retired the media addon's old name. **The old file name, folder name and the `.bak`
beside it must never appear in a commit.** The one permitted survivor is the old SavedVariables
GLOBAL, referenced exactly once, in `MigrateFromPredecessor` — the same precedent as
`MigrateFromStoneTweaks` in the Hub's `Core.lua`.

## SavedVariables + migration

- `GloomsPortraitsDB`, account-wide, `_version = 14` (inherited; a mismatch resets to defaults,
  as before).
- `MigrateFromPredecessor` runs once, at `PLAYER_LOGIN` (not `ADDON_LOADED` — the old addon's
  saved table only exists after IT loads, and it sorts after us alphabetically). It **copies**
  the old table when ours is empty and leaves the old one untouched as the rollback. Never move.
- While both addons are enabled they both draw — two models. That is expected for the one
  login the copy needs; disable the old addon after it.

## Shape (both stages landed 2026-09-19, owner-QA'd)

- **`GloomsPortraits.lua` — the ENGINE.** The frames, the saved settings, visibility, the whole
  instance story — what the game will and won't identify, the 2D stand-in, the nameplate cache, the
  per-mode layouts (the measurements are **FINDINGS §17 in the Hub**; the comments above
  `CanShowUnit` and the nameplate cache carry the reasoning) — and a small API on the
  `GloomsPortraits` namespace that the tab drives:
  `Config · ApplyLayout · Nudge · SetMode · SetStrata · SetCondition · SetCamera · Reset ·
  SetEditing · OnChange`. It draws no UI.
- **`GloomsPortraits_Tab.lua` — the PORTRAITS tab** (`GloomsHub:RegisterTab`, id `portraits`,
  order 40), built entirely on `LibGloomSkin` and laid out like GB/Overlays: rail (the Gp mark,
  a Player/Target list, Reset) + a scrolling editor (mode, size + position with nudge, the 3D
  camera section that hides in 2D, layer, visibility). **Everything applies live; there is no
  Save.** Gate `SKIN_NEEDS = 4` (tabHeader); bump it in the same commit as any newer call.
- **Each mode keeps its own layout.** `x y size strata` at the top level are the ACTIVE mode's;
  `cfg.layouts[mode]` holds the other's; switching stashes and restores. The in-combat 2D stand-in
  wears the 2D set (the owner, 2026-09-19: a stand-in at the model's size and place is wrong).
- **`/gp plates`** is a QA probe (what the nameplate cache holds, which plate is the target). Keep
  probes in the addon — a `/run` over 255 characters silently does nothing (Hub LESSONS).
- **The tab is the lock.** `SetEditing(which)` on the container's OnShow unlocks dragging and
  shows the green outline for the selected unit; OnHide locks everything. There is no other
  lock/unlock control, on purpose.
- **No profile block, no minimap button, no floating panel.** Portraits has two fixed units
  and one account-wide config, so there is nothing to switch between; the suite has ONE
  launcher (the Hub's); `/gp` opens the tab. The old `/gp lock|unlock|panel|reset`
  subcommands are gone with the panel.
- **The Gp mark** (`Media/ui/logo.png`, 512² RGBA) is the family G with the orange **b** from
  GB's mark flipped vertically — a flipped b IS a p. Composed by script, not drawn.

## Conventions
- Namespace: `GloomsPortraits` → `_G.GloomsPortraits`; frames are `GloomsPortraits_*`; slash is
  **`/gp`** (`/portraits` and the old `/sm` also work). Chat prefix `|cff936bffGloom's Portraits:|r`.
- Plain frames, plain SavedVariables, no Ace3, no embedded libraries — LibStub/LDB/LibDBIcon
  come from the Hub, which is a hard dependency.
- US spelling in user-visible text.

## Testing / release
Symlinked into the client at `…/Interface/AddOns/GloomsPortraits`. QA by the owner (non-dev):
ONE copy-paste step at a time, verify before claiming, BugSack error text first. `/reload` is
enough, including for new files (fonts excepted). Tags cut a GitHub Release via the BigWigs
packager (repo `GloomSuite/GloomsPortraits`) as a version marker; **the owner runs the symlink,
not a release**, and any public distribution would go through CurseForge, not WoWup
(2026-09-19).
