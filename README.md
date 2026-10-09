# VocVendor

Every vendor visit ends the same way: sell the grays, repair, move on.
VocVendor does both the moment the window opens. Junk is a definition
you control, not a fixed pile of grays: opt old gear in and it sells
with the junk, automatically and on the game's own Sell Junk button.
Everything else it leaves alone.

## Install

Download the latest zip from [GitHub
Releases](https://github.com/vocino/vocvendor/releases), copy the
folder into `Interface/AddOns`, and make sure it is named `VocVendor`
(the folder name must match the `.toc` file). The same package runs
on Retail and on the Forever client.

## Use

Open any vendor. Junk sells, gear repairs (guild funds first when the
guild allows it), and one chat line reports the take. The native Sell
Junk button keeps working and gains your definition: with old gear in
it, the click lists the items and asks before selling. The addon
compartment on the minimap opens the settings.

```
/vv            sell junk now
/vv on|off     auto-sell junk on vendor visits
/vv repair     repair now
/vv config     open Settings > AddOns > VocVendor
/vv help       this list (/vocvendor works too)
```

## Config

Settings > AddOns > VocVendor, or `/vv config`:

- Auto-sell junk (default on)
- Auto-repair (default on)
- Guild funds first (default on)
- Chat announcements (default on)
- Old gear counts as junk (default off)
- Old gear ilvl gap (10-100 in 5s, default 30)
- Also sell Bind on Equip (default off: BoE can sell on the auction house)
- Also sell Warbound (default off: alts can use it through the warbank)

Every change applies at once.

## How it works

Grays go through Blizzard's own junk sale, the same call the Sell
Junk button makes. Old gear is weapons and armor at least the
configured gap below everything you wear in that slot, never
heirlooms, never anything Pawn flags as an upgrade when Pawn is
installed, and never BoE or Warbound unless you opt them in. Each
candidate is re-checked by bag slot right before it sells, so a bag
that shifted between the dry run and the click never sells the wrong
item. Repairs mirror the merchant frame's own buttons: guild bank
first when allowed, your gold otherwise, and only when you can pay.

## What's inside

- `main.lua`: the whole addon: the junk definition, auto-sell, auto-repair, the Sell Junk hook, settings, slash
- `VocVendor.toc` / `VocVendor_Forever.toc`: metadata for Retail and the Forever client
- `tests/run.lua`: stub-harness regression tests, no WoW client needed

## Tests

```
lua tests/run.lua
luacheck .
```

## License

MIT

---

Part of the Voc family: tiny addons that do one job.
[wow.vocino.com](https://wow.vocino.com) ·
[VocWarbank](https://github.com/vocino/vocwarbank) ·
[VocGear](https://github.com/vocino/vocgear) ·
[VocXP](https://github.com/vocino/vocxp) ·
[VocVendor](https://github.com/vocino/vocvendor)
