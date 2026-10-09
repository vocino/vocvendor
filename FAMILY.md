# The Voc family

Tiny World of Warcraft addons that each do one job, install
independently, and feel like one product when they meet. This file
is the contract that makes that true. The canonical copy lives in
the `voc-addons` skill (`family/FAMILY.md`, beside `VERSIONING.md`);
every Voc repository carries a byte-identical copy, and the skill's
`checks/family-docs.sh` fails CI when a copy drifts. Change it in the
skill, then copy it to every repo.

## Members

| Addon | Job | Slash | Repo |
| --- | --- | --- | --- |
| VocWarbank | Audit the warband bank, bank, and bags; draw the line; clean house | `/vw`, `/vocwarbank` | https://github.com/vocino/vocwarbank |
| VocGear | Equip bag upgrades out of combat (Pawn weights, or item level without Pawn) | `/vg`, `/vocgear` | https://github.com/vocino/vocgear |
| VocXP | Session XP/hr and active XP bonuses in one tiny readout | `/vxp`, `/vocxp` | https://github.com/vocino/vocxp |
| VocVendor | Vendor automation: junk is a configurable definition; auto-sell and auto-repair | `/vv`, `/vocvendor` | https://github.com/vocino/vocvendor |

## Principles

1. **One job.** An addon does one thing a player can say in a
   sentence. New ideas become new addons, not new tabs.
2. **Nothing is lost silently.** Destroying, selling, mailing, or
   trading away value always goes through a confirmation. Reversible
   actions (equipping gear) may run automatically, but they are
   announced and have an audit mode that only reports.
3. **Out of combat, out of the way.** Nothing acts during combat
   lockdown. No minimap buttons, no login spam, no popups the player
   did not ask for.
4. **Guests, not dependencies.** Other addons are always optional.
   Every external call is presence-gated and `pcall`-guarded; a broken
   neighbor never breaks us. Suites that skin the UI are adopted when
   present and never required.
5. **Settings apply live.** Changing an option in the panel or on the
   slash line takes effect immediately, with no reload.
6. **Stock first.** Default chrome is Blizzard's own, so the addon
   looks native beside the game's windows and beside its siblings.
   Data colors (item quality, verdicts) are ours and stay the same in
   every look.
7. **Headless tests, always green.** Behavior lives behind `ns.*`
   functions that stubbed WoW APIs can drive. No release ships red.
8. **Current build, official source.** The API is what Blizzard's own
   documentation says it is for the build in `## Interface:`, not what
   a wiki remembers from an older patch. See Sources of truth.
9. **Every version of the game.** Each addon ships a Retail toc and a
   Forever toc; the same code runs on both. Version-locked features
   degrade silently behind presence gates instead of erroring, and a
   missing API is never a missing addon.

## Sources of truth

The client API changes every patch, and most of the web describes an
older one. Code targets the build named by `## Interface:` in the
`.toc`, and every API fact is checked against that build, in this
order:

1. **Blizzard's own API documentation for the build.** In the
   client, `/api` opens it (the `Blizzard_APIDocumentation` addon).
   Outside the client, the same files are mirrored per branch at
   https://github.com/Gethe/wow-ui-source under
   `Interface/AddOns/Blizzard_APIDocumentationGenerated/`: `live` is
   the current retail build, `forever` is the Forever client, `ptr`
   and `beta` are what is coming. An API is verified on both `live`
   and `forever` before it ships unguarded (principle 9).
   Function names, namespaces, argument and return lists, and events
   come from here and nowhere else.
2. **Blizzard's UI source for the build**, same mirror: how Blizzard
   itself calls the API, the templates and mixins we build on
   (Settings, object pools, tooltips), and the `Blizzard_Deprecated*`
   folders for what is leaving and what replaces it.
3. **The Lua 5.1 reference manual**, https://www.lua.org/manual/5.1/.
   The client runs Lua 5.1 in a sandbox: no `io`, `os`, `require`, or
   `loadfile`, plus Blizzard additions such as `strtrim`, `wipe`, and
   `tContains`. Nothing from Lua 5.2 or later (`goto`, `table.unpack`,
   integer division) exists in the client.
4. **https://warcraft.wiki.gg**, for prose and examples only, and only
   after checking the page's patch note against the build. It is
   community-maintained and usually current, but a signature there is
   a lead to confirm in source 1, never the source.
5. **Blizzard's own data for IDs — the client first, the web API
   second.** The running client is the database: code treats IDs as
   keys and the client resolves them (`C_Spell.GetSpellInfo`,
   `C_Item.GetItemInfo`, the aura APIs). Check an ID in game with
   `/dump C_Spell.GetSpellInfo(<id>)` — nil means a wrong ID. Outside
   the client, Blizzard's Game Data API covers items fully
   (`/data/wow/item/{itemId}`, `static-{region}`) and spells partially
   (`/data/wow/search/spell`, `/data/wow/spell/{spellId}` on the
   versioned `static-{build}` namespace); a spell missing there proves
   nothing, the client check wins. Database sites are leads, never the
   source.

Not used, ever: Wowpedia (fandom.com), WoWWiki, forum threads, blog
tutorials, and memory of what a function used to take. Tell-tale
staleness: bare globals that now live in a `C_*` namespace
(`GetItemInfo` is `C_Item.GetItemInfo`, `GetContainerItemInfo` is
`C_Container.GetContainerItemInfo`, `GetAddOnMetadata` is
`C_AddOns.GetAddOnMetadata`), `UIDropDownMenu` templates where
native Settings controls exist, and return lists that have since
gained or lost positions.

How the rule holds without anyone watching:

- `.luacheckrc` lists every WoW global the addon reads, and lint
  fails on any other, so a stale name cannot ship by accident. A name
  is added only after it is confirmed in source 1 for the current
  build, and the commit says so. The skill's
  `checks/no-deprecated-globals.sh` rejects the names Blizzard has
  already moved into a `C_*` namespace, in code and in the allowlist.
- Every Blizzard name the family relies on has a row in the skill's
  `references/api-ledger.md` with the verdict of `tools/verify-api`
  on both branches: the shared, auditable record. A new name gets its
  row in the same change that adds it to `.luacheckrc`.
- Third-party addon APIs (Pawn, Syndicator, Auctionator, TSM, and so
  on) are verified against that addon's current source, kept as a
  local checkout under `.reference/` (gitignored), with the finding
  written down in `.reference/<addon>-analysis.md` or a code comment
  naming the version checked.
- Anything that cannot be verified is presence-gated, `pcall`-guarded,
  and covered by a stub test that pins the shape we assumed.
- When `## Interface:` is bumped, the generated docs for the new build
  are diffed against the old before any code changes.

Local checkout and a lookup:

```
git clone --depth 1 --branch live https://github.com/Gethe/wow-ui-source .reference/wow-ui-source
grep -rn 'Name = "GetContainerItemInfo"' .reference/wow-ui-source/Interface/AddOns/Blizzard_APIDocumentationGenerated/
```

## Craft

How the addons look, feel, and behave is defined once, in the
`voc-addons` skill, and consumed by every repo. The skill is the source
of truth for the visual language, interaction standards, and scope
discipline: Blizzard-native technique, a tiny semantic palette, every
interaction confirming, settings applied live, defaults as onboarding,
one file per job, scope discipline with a paper trail, zero
dependencies, unavailable as a designed state, and designing for the
next developer.

When this file and the skill disagree about craft, the skill wins.
Principles evolve in the skill; repos never fork them. The mechanically
checkable principles ship as scripts in the skill's `checks/`
directory and run in CI on every repo.

## Naming

- The addon name is `Voc` + one word in CamelCase: `VocWarbank`,
  `VocGear`. The folder, `.toc`, and `## Title` match exactly.
- Every global carries the addon name. SavedVariables are
  `<Name>DB`. Named frames are `<Name>Something`. Static popups are
  `<NAME>_SOMETHING`. Settings variables are `<Name>_key`. Never
  introduce an unprefixed global.
- Each file begins `local name, ns = ...` (or `local _, ns = ...`
  when the name is unused) and puts state on `ns`, never on `_G`.
- The slash command has a short form (`/v` + one letter or two) and
  the full name as a long form (`/vocgear`). Both are documented, and
  the help text says so: "(/vocgear works too)".

## Slash grammar

```
/<short>              the one main action (open the window, toggle on/off)
/<short> config       open Settings > AddOns > <Name>
/<short> help         list every subcommand
/<short> <sub> ...    further subcommands, lower-case, case-insensitive input
```

Anything unrecognized prints help; it never performs an action, so a
typo can never toggle, sell, or equip. `config` and `help` exist in
every addon, however few options it has. Help is an `ns.HELP` table,
one subcommand per line, the command padded so descriptions line up,
`config` second to last and `help` last:

```
/vg            toggle auto-equip on/off
/vg scan       check bags now
/vg config     open Settings > AddOns > VocGear
/vg help       this list (/vocgear works too)
```

## Chat voice

Chat lines go through `ns.say(msg)`, which prints the addon name as
a colored prefix followed by the message:

```lua
ns.PREFIX_COLOR = "ff66ccff"   -- the family color, same everywhere
function ns.say(msg)
  print("|c" .. ns.PREFIX_COLOR .. name .. "|r: " .. tostring(msg))
end
```

One line per event. Announce-once per session for advice that would
otherwise repeat on every scan. Lower-case first word after the
prefix ("equipped ...", "price source set to ..."). No trailing
period: a chat line is a log entry, not a sentence. Every line is a
fact or a next step, never a greeting.

## Sounds

Every toggle and every window confirms with a Blizzard sound (the
`voc-addons` skill, principle 3). The helper is the same in every
addon, SOUNDKIT names first and the numeric IDs behind them, so a
Blizzard rename never silences the polish and a missing sound API
never errors:

```lua
ns.SOUNDS = {
  on = { "IG_MAINMENU_OPTION_CHECKBOX_ON", 856 },
  off = { "IG_MAINMENU_OPTION_CHECKBOX_OFF", 857 },
  open = { "IG_MAINMENU_OPEN", 850 },
  close = { "IG_MAINMENU_CLOSE", 851 },
}
function ns.play(kind)
  local s = ns.SOUNDS[kind]
  if not s or type(PlaySound) ~= "function" then return end
  local id = type(SOUNDKIT) == "table" and SOUNDKIT[s[1]] or nil
  pcall(PlaySound, type(id) == "number" and id or s[2])
end
```

Toggles use `on`/`off`, windows and readouts `open`/`close`. An
addon with a sound of its own (repair, equip) adds a key to the same
table; nothing calls `PlaySound` directly.

## Palette

Colors are defined once per addon and referenced by name, never
written at a call site (the skill's principle 2 and its
`no-hardcoded-colors.sh` check). The family tokens:

```lua
ns.COLORS = {
  gold = { 1, 0.82, 0 },         -- titles, emphasis, the one accent per screen
  text = { 1, 1, 1 },            -- body
  muted = { 0.5, 0.5, 0.5 },     -- hints, secondary text
  red = { 0.9, 0.3, 0.25 },      -- restriction lines and warnings only (brick, not pure red)
  green = { 0.25, 0.9, 0.35 },   -- valid state only
}
```

A single-file addon keeps the table in `main.lua`; a multi-file addon
keeps it in `palette.lua`, loaded first. Data colors an addon owns
(item quality, verdicts) live in the same place.

## Addon compartment

Every addon registers with Blizzard's addon compartment (the minimap
addon menu) through its `.toc`, so a player who never learns the
slash command still finds it:

```
## AddonCompartmentFunc: <Name>_CompartmentClick
## AddonCompartmentFuncOnEnter: <Name>_CompartmentEnter
## AddonCompartmentFuncOnLeave: <Name>_CompartmentLeave
```

The click opens the addon's window when it has one (VocWarbank,
VocXP) and its settings panel otherwise (VocGear, VocVendor). Hover
follows the tooltip contract: gold title, one white line saying what
the addon does, one muted line teaching the slash command. The three
globals are the only ones the compartment needs and they carry the
addon prefix like every other global.

## Settings

- Account-wide SavedVariables holding a flat table of options.
- A `defaults` table is the single source of truth. On load, missing
  keys are filled, and any key holding the wrong type or an
  out-of-range value is reset to its default. Unknown keys are left
  alone for forward compatibility.
- The panel is a native Blizzard Settings category registered with
  `Settings.RegisterVerticalLayoutCategory("<Name>")`, built from
  `Settings.RegisterAddOnSetting` plus `CreateCheckbox`,
  `CreateSlider`, and `CreateDropdown`. No hand-drawn canvas panels.
  Every addon has one, even when its only options are show and lock:
  the panel is where a player who never reads help finds the addon.
- Registration is retried at `PLAYER_LOGIN` when the Settings API was
  not up at `ADDON_LOADED`, and every setting carries a value-changed
  callback so the change applies at once.
- Free-text options (names, keys) live on the slash line, and the
  panel says so.
- `/<short> config` opens the category; when the Settings API is
  missing it says where to find the panel instead of erroring.

## Repository layout

```
<Name>/
  <Name>.toc            Retail metadata (template below)
  <Name>_Forever.toc    the same, for the Forever client (principle 9)
  *.lua                 the addon; one file or a few, never a framework
  tests/run.lua         headless tests, run with `lua tests/run.lua`
  README.md             user docs (template below)
  AGENTS.md             contributor map, namespace, tests, releases
  FAMILY.md             this file
  VERSIONING.md         tag-driven semver releases
  LICENSE               MIT
  .pkgmeta              package-as + ignore list for dev files
  .luacheckrc           lint config declaring the addon's globals
  .gitignore            `.reference/` local analysis checkouts
  .github/workflows/
    test.yml            tests, luacheck, and the skill checks on every push and PR
    release.yml         BigWigsMods packager on `v*` tags
    tag.yml             cuts a tag from anywhere that cannot push one
```

No embedded libraries (Ace3 and friends). The whole addon stays
readable in one sitting.

### `.toc` template

```
## Interface: <current retail build>
## Title: <Name>
## Notes: <one sentence, what it does> (/<short>)
## Author: vocino
## Version: @project-version@
## Category: <a Blizzard addon-list category>
## IconTexture: Interface\Icons\<an existing game icon>
## SavedVariables: <Name>DB
## OptionalDeps: ...
## AddonCompartmentFunc: <Name>_CompartmentClick
## AddonCompartmentFuncOnEnter: <Name>_CompartmentEnter
## AddonCompartmentFuncOnLeave: <Name>_CompartmentLeave
## X-Website: https://github.com/vocino/<name>
## X-License: MIT
## X-Curse-Project-ID: <id>
## X-Wago-ID: <id>
```

`<Name>_Forever.toc` is the same file with the Forever `## Interface`
and "(Forever client)" appended to the notes; both list the same Lua
files. `## Version` is never hand-edited; the packager fills it from
the tag. Nothing is a `RequiredDeps`: other addons are guests.

## Tests and lint

- Tests are plain Lua with stubbed WoW APIs, written for Lua 5.1 (the
  client's dialect) and passing on 5.4 as well. `lua tests/run.lua`
  from the repo root exits non-zero on failure.
- `luacheck .` passes with the repo's `.luacheckrc`, which lists the
  WoW globals the addon reads and the globals it owns
  (SavedVariables, `SLASH_*`).
- `test.yml` runs both on every push and pull request.

## Debugging

The coding agent is blind in game: only Lua errors surface on their
own. The family debugs with the community's tools, not its own.

- **!BugGrabber** captures every Lua error with stack and context.
  **BugSack** is the in-game viewer (`/bugsack`). Both are
  installed on the dev machine; recommend them to anyone filing
  a bug.
- Errors persist to
  `WTF/Account/<account>/SavedVariables/!BugGrabber.lua` on
  `/reload` or logout. The agent loop: the player reproduces the
  problem, runs `/reload`, and the agent reads that file directly
  — no paste step on a machine that also runs WoW.
- Parse with regex on `["message"]` fields, never brace-counting:
  the `["locals"]` dump nests braces and breaks structural
  parsers.
- Stale records survive a fix. Confirm the player reproduced the
  issue again before trusting a record.

## Releases

See `VERSIONING.md` (canonical in the skill, identical in every repo,
checked in CI): tag-driven semver,
`v*` tags trigger the packager, tags are never moved. Commit subjects
are the changelog, so write `feat:`, `fix:`, `docs:`, `chore:`,
`test:`, `refactor:` lines a player can read.

## Documentation

`README.md` sections, in order: the pitch (one paragraph), Install,
Use (with the slash block), Config, How it works, What's inside,
Tests, License, and the family footer. The footer names every member
in Members order, this addon included, so it is identical in every
repo:

```
---

Part of the Voc family: tiny addons that do one job.
[VocWarbank](https://github.com/vocino/vocwarbank) ·
[VocGear](https://github.com/vocino/vocgear) ·
[VocXP](https://github.com/vocino/vocxp) ·
[VocVendor](https://github.com/vocino/vocvendor)
```

`AGENTS.md` sections: Code Map, API references (the short form of
Sources of truth, since agents read `AGENTS.md` first), Family
(pointer to this file), Namespace, Tests, Releases, Live testing.

## Adding an addon

1. Scaffold it: `tools/new-addon <Name> <short> <dir>` in the
   `voc-addons` skill copies `templates/addon` (both tocs, the chat,
   sound, palette, settings, compartment, and slash skeleton, the test
   harness, lint, packager, workflows, these docs) and renames every
   placeholder. The result passes tests, lint, and every check before
   the one job is written.
2. Add a row to Members in the skill's `family/FAMILY.md`, then copy
   it to every sibling; CI holds the copies identical.
3. Add the sibling link to every README footer, every repo.
4. Register CurseForge and Wago projects, fill in the `.toc` ids and
   the workflow secrets.
