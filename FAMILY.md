# The Voc family

Tiny World of Warcraft addons that each do one job, install
independently, and feel like one product when they meet. This file
is the contract that makes that true. It is kept word-for-word
identical in every Voc repository: change it in one, copy it to all.

## Members

| Addon | Job | Slash | Repo |
| --- | --- | --- | --- |
| VocWarbank | Audit the warband bank, bank, and bags; draw the line; clean house | `/vw`, `/vocwarbank` | https://github.com/vocino/vocwarbank |
| VocGear | Equip bag upgrades out of combat (Pawn weights, or item level without Pawn) | `/vg`, `/vocgear` | https://github.com/vocino/vocgear |
| VocXP | Session XP/hr and active XP bonuses in one tiny readout | `/vxp` | https://github.com/vocino/vocxp |
| VocVendor | Vendor automation: junk is a configurable definition; auto-sell and auto-repair | `/vv`, `/vocvendor` | https://github.com/vocino/vocvendor |
| VocDebug | Debug bus for addon development: structured lines to the chat log | `/vdbg` | https://github.com/vocino/vocdebug |

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
   the current retail build, `ptr` and `beta` are what is coming.
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
  build, and the commit says so.
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
- The slash command has a short form (`/v` + one letter) and the
  full name as a long form (`/vocgear`). Both are documented.

## Slash grammar

```
/<short>              the one main action (open the window, toggle on/off)
/<short> config       open Settings > AddOns > <Name>
/<short> help         list every subcommand
/<short> <sub> ...    further subcommands, lower-case, case-insensitive input
```

Anything unrecognized prints help; it never performs an action, so a
typo can never toggle, sell, or equip. Help prints one subcommand
per line, the command padded so descriptions line up.

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
prefix ("equipped ...", "price source set to ..."). Every line is a
fact or a next step, never a greeting.

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
- Free-text options (names, keys) live on the slash line, and the
  panel says so.
- `/<short> config` opens the category; when the Settings API is
  missing it says where to find the panel instead of erroring.

## Repository layout

```
<Name>/
  <Name>.toc            metadata (template below)
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
    test.yml            tests + luacheck on every push and PR
    release.yml         BigWigsMods packager on `v*` tags
```

No embedded libraries (Ace3 and friends). The whole addon stays
readable in one sitting.

### `.toc` template

```
## Interface: <current retail build>
## Title: <Name>
## Notes: <one sentence, what it does>
## Author: vocino
## Version: @project-version@
## Category: Bags & Inventory
## IconTexture: Interface\Icons\<an existing game icon>
## SavedVariables: <Name>DB
## RequiredDeps / OptionalDeps: ...
## X-Website: https://github.com/vocino/<name>
## X-License: MIT
## X-Curse-Project-ID: <id>
## X-Wago-ID: <id>
```

`## Version` is never hand-edited; the packager fills it from the tag.

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
own. VocDebug is the family debug bus, built for the agent, not for
manual checking.

- Every addon carries the guest hook
  `local dbg = VOCDBG or function() end` (silent no-op unless
  VocDebug is loaded) and emits behavior events on it:
  `dbg("<addon>", "<event>", "k=v k=v")`. `VOCDBG` is listed in each
  repo's `.luacheckrc` read_globals, marked as our own addon.
- Lines go to the private `vocdbg` channel as
  `[VOCDBG] <session> <addon> <event> <payload>` and, with chat
  logging on, land in `WoWChatLog.txt`. Lua errors ride the same bus
  as `errors/lua_error` (VocDebug replaces BugGrabber/BugSack).
- Emit on change, not on poll: a `bonuses_changed` when the set
  changes, never a `bonus_poll` every tick. One line per meaningful
  thing that happened.
- The agent loop: the agent implements, hands the player numbered
  actions and a mark label; the player runs `/vdbg mark <label>`
  and does the actions; the agent reads `vocdebug since <label>`
  (`tools/vocdebug` in the VocDebug repo, python3 stdlib) and
  reports what fired, what didn't, and where the gaps are. On a
  machine that also runs WoW, the agent reads the log directly —
  no paste step.

## Releases

See `VERSIONING.md` (identical in every repo): tag-driven semver,
`v*` tags trigger the packager, tags are never moved. Commit subjects
are the changelog, so write `feat:`, `fix:`, `docs:`, `chore:`,
`test:`, `refactor:` lines a player can read.

## Documentation

`README.md` sections, in order: the pitch (one paragraph), Install,
Use (with the slash block), Config, How it works, What's inside,
Tests, License, and the family footer:

```
---

Part of the Voc family: tiny addons that do one job.
Siblings: [VocWarbank](https://github.com/vocino/vocwarbank) ·
[VocGear](https://github.com/vocino/vocgear)
```

`AGENTS.md` sections: Code Map, API references (the short form of
Sources of truth, since agents read `AGENTS.md` first), Family
(pointer to this file), Namespace, Tests, Releases, Live testing.

## Adding an addon

1. Copy the layout above from a sibling, rename everything.
2. Add a row to Members here, then copy this file to every sibling.
3. Add the sibling link to every README footer.
4. Register CurseForge and Wago projects, fill in the `.toc` ids and
   the workflow secrets.
