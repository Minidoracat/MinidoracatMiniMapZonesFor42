[h1]🗺️ Minidoracat MiniMap Zones[/h1]
[h3]By Minidoracat[/h3]

[hr][/hr]

[h2]✨ What is this[/h2]
A [b]server custom-zone addon[/b] for the [b]Minidoracat MiniMap for B42[/b] main MOD:
it draws semi-transparent filled areas + outlines + name labels on both the mini-map
and the world map.
[list]
[*] [b]Server-defined zones[/b]: a server-side `zones.txt` (writable by external tools, e.g. event-area or reset-zone marker tools) — validated by the server and broadcast to all players in real time; singleplayer reads the local `zones.txt` directly
[*] [b]42.20 file rename (0.2.0)[/b]: game 42.20 added a file-extension whitelist for Lua file writes, so the file is now `zones.txt` (the content is still JSON). An existing legacy `zones.json` is migrated into `zones.txt` automatically on first launch (one-time); external tools should write `zones.txt` from now on
[/list]
[i]Built-in resource points (POI — 14 vanilla-map categories: military/medical/supermarket…) are built into the main MOD as of 0.8.0 — installing the main MOD is enough; this addon is no longer needed for them.[/i]

[h2]⚠️ Version requirement[/h2]
[b]Requires the main MOD [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763913359]Minidoracat MiniMap for B42[/url] version 42.19.0-0.8.0 or later[/b] (it provides the zone-layer rendering API and the settings-page action-row API).
If the main MOD is missing or too old, this pack silently degrades — no zones are drawn, and the main MOD's other features are unaffected.

[h2]🧰 Features[/h2]
[list]
[*] [b]Display-only markers[/b]: zones are purely visual map overlays — they do not add PVP, safe-zone, or any other gameplay mechanics
[*] [b]Server-authoritative sync[/b]: edit `zones.txt` and it updates automatically within the poll interval (sandbox-adjustable); admins can also force an instant refresh with [b]/reloadzones[/b]; players joining mid-game see the current zones right away
[*] [b]Dual map display[/b]: correct projection and clipping on both the mini-map and the world map
[*] [b]Toggles[/b]: the Zone layer master switch (main MOD) / a "Show server zones" per-provider switch (added to the unified settings window by the main MOD from this pack's registration, on by default) — turn it off and the whole layer stops drawing
[*] [b]Rectangle zones[/b]: a single zone can be made of multiple rectangles to cover irregular shapes
[*] [b]Auto template & generate button[/b]: on first launch a `zones.txt` template with four demo zones is generated automatically (localized to the server language); the unified settings window also offers a "Generate zones template" button with a language picker (Traditional/Simplified Chinese, English, Japanese) — a confirm dialog guards against misclicks, the existing file is first backed up to a timestamped `.bak.txt`, and on servers it requires the "manage mods" permission
[*] [b]enabled field[/b]: set `"enabled": false` on a zone to keep its coordinates but hide it temporarily — no need to delete it
[*] [b]Fault-tolerant data[/b]: malformed or over-limit entries are skipped and logged without breaking the rest of the zones
[*] [b]Singleplayer & multiplayer[/b]: SP reads the local `zones.txt` directly; MP is validated and broadcast by the server
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
[*] [b]Supported version:[/b] Build 42.20.0+
[*] Works in singleplayer / multiplayer
[/list]

[h2]💬 Feedback & community[/h2]
[url=https://discord.gg/Gur2V67]👉 Join the Discord server[/url]

[h2]📺 Follow the author[/h2]
[url=https://www.twitch.tv/minidoracat]🎬 Twitch channel[/url]

[b]#map #minimap #worldmap #Minidoracat[/b]

Workshop ID: 3768276209
Mod ID: MinidoracatMiniMapZonesFor42
