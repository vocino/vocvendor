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
guild allows it), and one chat line reports the take at close. Gear kept for
disenchanting opens a click-to-disenchant list instead of a chat line:
click an item to disenchant it. The native Sell
Junk button keeps working and gains your definition: with old gear in
it, the click lists the items and asks before selling. The addon
compartment on the minimap opens the settings, or the disenchant list
while kept gear waits.

```
/vv            sell junk now
/vv on|off     auto-sell junk on vendor visits
/vv repair     repair now
/vv disenchant open the disenchant list
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
- Compare auction prices (default on: with Auctionator, TradeSkillMaster, or Oribos Exchange installed, gear worth more on the auction house is held back with its reason instead of sold)
- Keep disenchantable gear (default on: enchanters disenchant it from the list instead of selling it)
- Keep current-expansion gear (default on: gear from the current expansion never counts as old gear)

Every change applies at once.

## How it works

Grays go through Blizzard's own junk sale, the same call the Sell
Junk button makes. Old gear is weapons and armor at least the
configured gap below everything you wear in that slot, never
heirlooms, never anything in a saved equipment set, never anything
Pawn flags as an upgrade when Pawn is
installed, never BoE or Warbound unless you opt them in, and never an
uncollected transmog appearance, toy, or pet, and never gear from the current expansion while its keep is on. Each
candidate is re-checked by bag slot right before it sells, so a bag
that shifted between the dry run and the click never sells the wrong
item. When Auctionator, TradeSkillMaster, or Oribos Exchange is installed, old gear worth more on the auction house (sold directly, or disenchanted first, net of the 5% auction cut) is held back with its reason instead of sold. A sale that fails stops the run and lists what is left with the
reason, instead of retrying. When another junk-selling addon is loaded,
VocVendor warns once and pauses its own auto-sell; `/vv on` turns it
back on.
Repairs mirror the merchant frame's own buttons: guild bank
first when allowed, your gold otherwise, and only when you can pay.
Gear kept for disenchanting (uncommon, rare, or epic, for enchanters) opens a
click-to-disenchant window instead: one row per item, each click
disenchants that bag slot, and the list tracks the bags until empty. Moving items between bank and bags stays in VocWarbank (/vw Empty and Deposit); this addon only sells at the vendor.

## What's inside

- `main.lua`: the whole addon: the junk definition, auto-sell, auto-repair, the Sell Junk hook, the disenchant window, settings, slash
- `VocVendor.toc` / `VocVendor_Camelot.toc`: metadata for Retail and the Forever client
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
