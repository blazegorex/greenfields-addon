# Greenfields art prompts (for ChatGPT image generation)

How to use:
1. Generate the three style anchors first, in one ChatGPT chat.
2. Stay in that same chat for the rest, starting each request with "Same style as the previous images." That keeps the set consistent.
3. Download each image as a PNG. Name it exactly as the heading says (e.g. `hero_raids.png`) and put it in `tools/art/downloads/`.
4. Tell Claude, or run `python tools/import_art.py`. It crops and resizes everything into WoW textures and switches the art on in the addon.

Missing images are fine: anything you skip keeps the current look.

## 1. Style anchors (do these first)

### `hero_home.png`
Landscape (1536x1024). Keep the important detail in the middle band; the outer edges get cropped.

```
Hand-painted digital fantasy illustration in the style of classic early-2000s high-fantasy MMO concept art: chunky stylized proportions, saturated warm-and-cool lighting, visible painterly brushwork, rich hand-painted textures, slightly exaggerated shapes. Wide panoramic establishing shot, important details along the middle band, darker quieter areas at the far left and right. No text, no letters, no logos, no UI. a scruffy, humble fantasy village street at dusk on the edge of a coastal estuary: crooked timber cottages with patched roofs, warm lantern-lit windows, a wonky fence, an overflowing wooden rubbish bin with a white ibis bird perched on it, a tall blank green wooden signpost by the road, purple-orange sky over calm water
```

### `title_loot_raid.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a cheeky white ibis bird with a long curved black beak diving into an overflowing treasure barrel, flinging gold coins and gems.
```

### `crest.png`
Square, transparent background (ask for a transparent PNG).

```
Hand-painted heraldic fantasy guild crest in the style of classic early-2000s high-fantasy MMO art, isolated object: a kite-shaped shield in deep road-sign green with a thick polished gold rim and riveted bronze trim, in the centre a proud stylized white ibis with a long curved black beak standing on a small stack of gold coins, two crossed wooden torches behind the shield, a blank cream ribbon banner across the bottom, weathered metal textures, strong silhouette, centred and symmetrical. No text, no letters.
```

## 2. Page banners

### `hero_feed.png`
Landscape (1536x1024). Keep the important detail in the middle band; the outer edges get cropped.

```
Hand-painted digital fantasy illustration in the style of classic early-2000s high-fantasy MMO concept art: chunky stylized proportions, saturated warm-and-cool lighting, visible painterly brushwork, rich hand-painted textures, slightly exaggerated shapes. Wide panoramic establishing shot, important details along the middle band, darker quieter areas at the far left and right. No text, no letters, no logos, no UI. the same scruffy fantasy village street late at night: a single glowing lamp post, curtains twitching in lit windows, a cat on a fence, long shadows, moonlight
```

### `hero_raids.png`
Landscape (1536x1024). Keep the important detail in the middle band; the outer edges get cropped.

```
Hand-painted digital fantasy illustration in the style of classic early-2000s high-fantasy MMO concept art: chunky stylized proportions, saturated warm-and-cool lighting, visible painterly brushwork, rich hand-painted textures, slightly exaggerated shapes. Wide panoramic establishing shot, important details along the middle band, darker quieter areas at the far left and right. No text, no letters, no logos, no UI. a raid camp at night before a colossal ancient root-covered gate in a mountain forest: tents, banners, a big campfire, adventurers' silhouettes, glowing runes on the gate
```

### `hero_softres.png`
Landscape (1536x1024). Keep the important detail in the middle band; the outer edges get cropped.

```
Hand-painted digital fantasy illustration in the style of classic early-2000s high-fantasy MMO concept art: chunky stylized proportions, saturated warm-and-cool lighting, visible painterly brushwork, rich hand-painted textures, slightly exaggerated shapes. Wide panoramic establishing shot, important details along the middle band, darker quieter areas at the far left and right. No text, no letters, no logos, no UI. a torch-lit treasure vault: chests overflowing with gold and gear, a pair of bone dice resting on a wooden table, parchment lists pinned to a beam
```

### `hero_loot.png`
Landscape (1536x1024). Keep the important detail in the middle band; the outer edges get cropped.

```
Hand-painted digital fantasy illustration in the style of classic early-2000s high-fantasy MMO concept art: chunky stylized proportions, saturated warm-and-cool lighting, visible painterly brushwork, rich hand-painted textures, slightly exaggerated shapes. Wide panoramic establishing shot, important details along the middle band, darker quieter areas at the far left and right. No text, no letters, no logos, no UI. a dragon's hoard spilling out of chests in a cavern: piles of gold coins, glowing purple weapons, gem-studded helms, warm torchlight
```

### `hero_attendance.png`
Landscape (1536x1024). Keep the important detail in the middle band; the outer edges get cropped.

```
Hand-painted digital fantasy illustration in the style of classic early-2000s high-fantasy MMO concept art: chunky stylized proportions, saturated warm-and-cool lighting, visible painterly brushwork, rich hand-painted textures, slightly exaggerated shapes. Wide panoramic establishing shot, important details along the middle band, darker quieter areas at the far left and right. No text, no letters, no logos, no UI. a cosy tavern interior with a wooden noticeboard covered in pinned parchment roll calls, candles, ale tankards, a quill and ink pot
```

### `hero_fame.png`
Landscape (1536x1024). Keep the important detail in the middle band; the outer edges get cropped.

```
Hand-painted digital fantasy illustration in the style of classic early-2000s high-fantasy MMO concept art: chunky stylized proportions, saturated warm-and-cool lighting, visible painterly brushwork, rich hand-painted textures, slightly exaggerated shapes. Wide panoramic establishing shot, important details along the middle band, darker quieter areas at the far left and right. No text, no letters, no logos, no UI. a grand hall of heroes: golden trophies on pedestals, hanging guild banners, marble statues, shafts of warm light
```

### `hero_roster.png`
Landscape (1536x1024). Keep the important detail in the middle band; the outer edges get cropped.

```
Hand-painted digital fantasy illustration in the style of classic early-2000s high-fantasy MMO concept art: chunky stylized proportions, saturated warm-and-cool lighting, visible painterly brushwork, rich hand-painted textures, slightly exaggerated shapes. Wide panoramic establishing shot, important details along the middle band, darker quieter areas at the far left and right. No text, no letters, no logos, no UI. a busy village square on market day: stalls, townsfolk silhouettes, bunting, cobblestones, a fountain
```

### `hero_tradies.png`
Landscape (1536x1024). Keep the important detail in the middle band; the outer edges get cropped.

```
Hand-painted digital fantasy illustration in the style of classic early-2000s high-fantasy MMO concept art: chunky stylized proportions, saturated warm-and-cool lighting, visible painterly brushwork, rich hand-painted textures, slightly exaggerated shapes. Wide panoramic establishing shot, important details along the middle band, darker quieter areas at the far left and right. No text, no letters, no logos, no UI. a busy craftsman's workshop: a blacksmith anvil throwing sparks, leatherworking racks, an alchemy table with bubbling potions, tools on the wall
```

### `hero_buffs.png`
Landscape (1536x1024). Keep the important detail in the middle band; the outer edges get cropped.

```
Hand-painted digital fantasy illustration in the style of classic early-2000s high-fantasy MMO concept art: chunky stylized proportions, saturated warm-and-cool lighting, visible painterly brushwork, rich hand-painted textures, slightly exaggerated shapes. Wide panoramic establishing shot, important details along the middle band, darker quieter areas at the far left and right. No text, no letters, no logos, no UI. an adventurers' campsite at dusk at the foot of misty mountains: a crackling campfire, a canvas tent, a folding camp chair, a fish bowl on a crate, a lute leaning on a log, a banner on a pole
```

### `hero_settings.png`
Landscape (1536x1024). Keep the important detail in the middle band; the outer edges get cropped.

```
Hand-painted digital fantasy illustration in the style of classic early-2000s high-fantasy MMO concept art: chunky stylized proportions, saturated warm-and-cool lighting, visible painterly brushwork, rich hand-painted textures, slightly exaggerated shapes. Wide panoramic establishing shot, important details along the middle band, darker quieter areas at the far left and right. No text, no letters, no logos, no UI. a tinkerer's cosy workbench: brass gears, maps, a lantern, scattered tools and parchment
```

## 3. Window header strip

### `header.png`
Landscape (1536x1024). Keep the important detail in the middle band; the outer edges get cropped.

```
Hand-painted digital fantasy illustration in the style of classic early-2000s high-fantasy MMO concept art: chunky stylized proportions, saturated warm-and-cool lighting, visible painterly brushwork, rich hand-painted textures, slightly exaggerated shapes. Wide panoramic establishing shot, important details along the middle band, darker quieter areas at the far left and right. No text, no letters, no logos, no UI. a scruffy, humble fantasy village street at dusk on the edge of a coastal estuary: crooked timber cottages with patched roofs, warm lantern-lit windows, a wonky fence, an overflowing wooden rubbish bin with a white ibis bird perched on it, a tall blank green wooden signpost by the road, purple-orange sky over calm water, very wide letterbox framing
```

## 4. Title icons (Hall of Fame)

### `title_deaths_raid.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a cartoonish armored adventurer standing obliviously in a roaring pool of green-and-orange fire, grinning.
```

### `title_deaths_total.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a glowing winged spirit healer beckoning a translucent ghost in a misty graveyard.
```

### `title_deaths_falling.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a dwarf tumbling off a cliff edge, arms flailing, helmet flying off.
```

### `title_deaths_drowning.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a helmet sinking in murky green water with bubbles rising and a small inflatable ring floating above.
```

### `title_first_death_wipe.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a lone skull under a single stage spotlight.
```

### `title_deaths_pvp.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a hooded ambusher leaping from a dark lantern-lit alley.
```

### `title_afk_minutes.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a weary adventurer sitting on a crate taking a pipe break, smoke curling, an hourglass beside him.
```

### `title_flakes.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: an empty chair at a feast table with a dusty unopened invitation scroll.
```

### `title_late.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a melting brass pocket watch on a sunset beach.
```

### `title_jumps.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a kangaroo mid-leap wearing a tiny iron helmet.
```

### `title_emotes.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a goblin dancing wildly with a lute that blasts shockwaves of music.
```

### `title_repair_gold.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a badly dented breastplate on an anvil with sparks and gold coins.
```

### `title_duel_losses.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a dizzy adventurer with a black eye and stars circling his head.
```

### `title_wipes.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a pile of fallen helmets and broken swords beneath a tattered banner.
```

### `title_drunk.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a foaming tankard of ale tipping over with dizzy swirling bubbles.
```

### `title_hearths.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a glowing hearthstone with a blue rune beside a cosy cottage fireplace.
```

### `title_wealth_low.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: an empty coin purse with moths fluttering out of it.
```

### `title_pvp_kills.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a menacing hooded rogue with crossed daggers and a smug grin, dramatic red rim light.
```

### `title_loot_epics.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: glowing purple gems and enchanted items raining down.
```

### `title_wealth.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a towering pile of gold coins with a jewelled crown on top, sparkling.
```

### `title_attendance.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a loyal armoured war horse beside a raised battle standard at sunrise.
```

### `title_consumables.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: rows of colourful bubbling potion bottles and flasks on a shelf.
```

### `title_rezzes.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: glowing golden hands of holy light raising a fallen hero.
```

### `title_fish.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a vivid blue crab caught in a rope net with a fishing rod.
```

### `title_camps.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a cosy campfire with a small tent and a folding camp chair under the stars.
```

### `title_quests.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a tall stack of quest scrolls tied with ribbon and a wax seal.
```

### `title_duel_wins.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: two crossed swords wreathed in a victory laurel with sparks.
```

### `title_flights.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a gryphon carrying a delivery satchel soaring over clouds.
```

### `title_rezzed.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a skeletal hand rising from a grave bathed in holy light.
```

### `title_honor_kills.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a war banner with a skull and crossed axes before roaring flames.
```

### `title_sr_wins.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a pair of glowing loaded dice both showing six, with a mischievous aura.
```

## 5. Sidebar icons

### `nav_home.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a lantern-lit cobbled village street at dusk.
```

### `nav_feed.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a watchful glowing eye behind a curtained window.
```

### `nav_raids.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a war banner planted before a dungeon gate.
```

### `nav_softres.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a pair of bone dice on a small treasure chest.
```

### `nav_loot.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: an overflowing loot sack with gold coins.
```

### `nav_attendance.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a parchment roll call scroll with a quill.
```

### `nav_buffs.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a crackling campfire with sparks.
```

### `nav_roster.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: three hooded villager silhouettes by a lamp post.
```

### `nav_fame.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a golden trophy goblet wreathed in laurel.
```

### `nav_tradies.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: a blacksmith hammer striking an anvil with sparks.
```

### `nav_settings.png`
Square (1024x1024).

```
Hand-painted square spell/ability icon for a classic fantasy MMO, in the style of early-2000s high-fantasy game icons: bold readable central subject filling most of the frame, chunky stylized shapes, saturated colours, strong dramatic rim lighting, painterly brushwork, dark moody vignette toward the edges, full-bleed square composition with no border and no frame. No text, no letters, no UI. Subject: interlocking brass cogs and gears.
```
