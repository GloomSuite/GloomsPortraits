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
> rotation, show conditions, the control panel (stage 1) and the contents of the Portraits tab
> (stage 2).
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

## Stage plan (BACKLOG item 11 in the Hub)

- **Stage 1 — DONE 2026-09-19:** suite member, no visual change. Same frames, same panel.
- **Stage 2 — its own session:** replace the panel with a **Portraits tab** in the Suite window
  on `LibGloomSkin` (rail + editor like GB, sliding switches, the shared sliders/colour picker).
  Read `GloomsPortraits.lua` properly before designing. **The owner does not want a mockup
  first** (2026-09-19) — infer the design from the sibling tabs and build it. When the tab
  lands, the minimap button in `CreateMinimapButton` goes: the suite has ONE launcher.

## Conventions
- Namespace: frames are `GloomsPortraits_*`; slash is **`/gp`** (`/portraits` and the old `/sm`
  also work). Chat prefix `|cff936bffGloom's Portraits:|r`.
- Plain frames, plain SavedVariables, no Ace3, no embedded libraries — LibStub/LDB/LibDBIcon
  come from the Hub, which is a hard dependency.
- US spelling in user-visible text.

## Testing / release
Symlinked into the client at `…/Interface/AddOns/GloomsPortraits`. QA by the owner (non-dev):
ONE copy-paste step at a time, verify before claiming, BugSack error text first. `/reload` is
enough, including for new files (fonts excepted). Ships via BigWigs packager → GitHub Releases
(repo `GloomSuite/GloomsPortraits`), WoWup.
