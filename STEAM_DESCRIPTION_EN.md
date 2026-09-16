[h1]🗺️ Minidoracat MiniMap Zones[/h1]
[h3]By Minidoracat[/h3]

[hr][/hr]

[h2]✨ What is this[/h2]
A [b]server custom-zone addon[/b] for the [b]Minidoracat MiniMap for B42[/b] main MOD:
it draws semi-transparent filled areas + outlines + name labels on both the mini-map
and the world map.
[list]
[*] [b]Server-defined zones[/b]: a server-side `zones.json` (writable by external tools, e.g. event-area or reset-zone marker tools) — validated by the server and broadcast to all players in real time; singleplayer reads the local `zones.json` directly
[*] [b]Back to `zones.json` (0.3.0)[/b]: game 42.20.0 had dropped `.json` from the Lua file-write extension whitelist (which is why 0.2.0 temporarily used `zones.txt`); [b]42.20.1 added `.json` back[/b], so the canonical file is `zones.json` again. A 0.2.0 `zones.txt` is migrated into `zones.json` automatically on first launch (one-time; any existing `zones.json` is backed up to `zones.premigrate.bak.json` first). External tools should write `zones.json` from now on. [b]This version requires game Build 42.20.1 or later[/b]
[/list]
[i]Built-in resource points (POI — 14 vanilla-map categories: military/medical/supermarket…) are built into the main MOD as of 0.8.0 — installing the main MOD is enough; this addon is no longer needed for them.[/i]

[h2]⚠️ Version requirement[/h2]
[b]Requires the main MOD [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763913359]Minidoracat MiniMap for B42[/url] version 42.19.0-0.8.0 or later[/b] (it provides the zone-layer rendering API and the settings-page action-row API).
If the main MOD is missing or too old, this pack silently degrades — no zones are drawn, and the main MOD's other features are unaffected.
The 0.4.0 category filter / halo edge / zoom LOD [b]need main MOD 42.20.1-0.14.0+ for full effect[/b]; on older main MOD versions zones still display normally, just without the new effects.

[h2]🧰 Features[/h2]
[list]
[*] [b]Display-only markers[/b]: zones are purely visual map overlays — they do not add PVP, safe-zone, or any other gameplay mechanics
[*] [b]Server-authoritative sync[/b]: edit `zones.json` and it updates automatically within the poll interval (sandbox-adjustable); admins can also force an instant refresh with [b]/reloadzones[/b]; players joining mid-game see the current zones right away
[*] [b]Dual map display[/b]: correct projection and clipping on both the mini-map and the world map
[*] [b]Toggles[/b]: the main MOD's "Show custom zone layer" master switch (unified settings window, on by default) — turn it off and the whole layer stops drawing
[*] [b]Rectangle zones[/b]: a single zone can be made of multiple rectangles to cover irregular shapes
[*] [b]Category filter (0.4.0)[/b]: zones can carry a `category` field — players get per-category checkboxes (with select all/none) in the main MOD's "Custom zones" settings section, auto-refreshing while the window is open; the template ships with "Demo: town / Demo: field" categories to show it off
[*] [b]Dark halo edge `haloAlpha` (0.4.0)[/b]: a cheap alternative to outlines — a slightly expanded dark underlay beneath the fill keeps edges crisp at a lower draw cost
[*] [b]Far-zoom names + zoom LOD (0.4.0)[/b]: zone names show at any zoom by default so zones are easy to find (toggleable); building-scale zones get automatic 3-tier LOD — a single union block at mid zoom, hidden when far, full detail up close
[*] [b]Auto template & generate button[/b]: on first launch a `zones.json` template with four demo zones is generated automatically (localized to the server language); the unified settings window also offers a "Generate zones template" button with a language picker (Traditional/Simplified Chinese, English, Japanese) — a confirm dialog guards against misclicks, the existing file is first backed up to a timestamped `.bak.json`, and on servers it requires the "manage mods" permission
[*] [b]enabled field[/b]: set `"enabled": false` on a zone to keep its coordinates but hide it temporarily — no need to delete it
[*] [b]Fault-tolerant data[/b]: malformed or over-limit entries are skipped and logged without breaking the rest of the zones
[*] [b]Singleplayer & multiplayer[/b]: SP reads the local `zones.json` directly; MP is validated and broadcast by the server
[/list]

[h2]🔗 MOD series[/h2]
[list]
[*] [b]Main MOD (required, 0.8.0+)[/b]: [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763913359]Minidoracat MiniMap for B42[/url] — the image-based map core
[*] [b]This page[/b]: Zones — server custom-zone display
[*] [b]Optional[/b]: [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763914102]MOD Maps[/url] — map pack addon for map MODs
[*] [b]Optional[/b]: [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3765182411]MOD Compatibility[/url] — third-party compatibility pack (animal icons for dogs, horses, etc.)
[/list]

[h2]📋 MOD info[/h2]
[list]
[*] [b]Mod ID:[/b] MinidoracatMiniMapZonesFor42
[*] [b]Required MOD:[/b] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763913359]Minidoracat MiniMap for B42[/url] (the main MOD, version 42.19.0-0.8.0 or later; this pack does nothing without it or with an older version)
[*] [b]Supported version:[/b] Build 42.20.1+ (42.20.0 cannot write `.json`, so it is not supported)
[*] Works in singleplayer / multiplayer
[/list]

[h2]💬 Feedback & community[/h2]
[url=https://discord.gg/Gur2V67]👉 Join the Discord server[/url]

[h2]☕ Support the author[/h2]
The mod is free and always will be. If you enjoy it, consider buying me a coffee - tips go straight into servers and mod development. Source code is public on GitHub.
[url=https://ko-fi.com/minidoracat][img]https://raw.githubusercontent.com/Minidoracat/workshop-resources/refs/heads/main/badges/badge_kofi.png[/img][/url] [url=https://github.com/Minidoracat/MinidoracatMiniMapZonesFor42][img]https://raw.githubusercontent.com/Minidoracat/workshop-resources/refs/heads/main/badges/badge_github.png[/img][/url]

[b]#map #minimap #worldmap #Minidoracat[/b]

Workshop ID: 3768276209
Mod ID: MinidoracatMiniMapZonesFor42
