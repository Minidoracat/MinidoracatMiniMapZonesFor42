<!-- 指南網址：https://steamcommunity.com/sharedfiles/filedetails/?id=3817849388 -->
<!-- Steam guide source (English): the full reference for this mod; the Workshop description only summarizes. Format and sync: pz-family-docs/release.md「完整說明：Steam 指南」 -->
<!-- 標題：📖 MiniMap Zones Mod Guide: zones.json, Sync & Player Settings -->
<!-- 摘要：Illustrated guide for server admins to the Minidoracat MiniMap Zones mod: quick start, writing zones.json, sync and /reloadzones, the Generate zones template button, and player settings. -->
=== 🚀 Quick start
[b]繁體中文版：[/b][url=https://steamcommunity.com/sharedfiles/filedetails/?id=3817849328]小地圖 - 伺服器自訂區域 MOD 完整說明[/url]

The mod on Steam Workshop:
https://steamcommunity.com/sharedfiles/filedetails/?id=3768276209

Zones lets a server mark custom areas on the minimap and the world map (a translucent fill, outline and name) — event areas, reset zones and so on.
[list]
[*] [b]Map markers only[/b]: no PVP, safe-zone or other gameplay mechanics.
[*] [b]For server admins[/b]: regular players only need "Player settings".
[/list]
{{img:01-server-zones-demo-en.jpg}}
[olist]
[*] [b]Install[/b]: the main mod [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763913359]MiniMap[/url] and this mod (the game version follows the main mod: currently Build 42.21.0 or later), then start the server once (in singleplayer, just load a game).
[*] [b]Find the template[/b]: generated at [b]Zomboid/Lua/MinidoracatMiniMapZones/zones.json[/b], with four demo zones written in the server's language.
[*] [b]Edit[/b]: change the demo zones or add your own, then save.
[*] [b]Apply[/b]: wait for the automatic refresh (60 seconds by default), or have an admin type [b]/reloadzones[/b] in chat to apply it immediately — no restart needed.
[/olist]
=== 🧰 Sync and reloading
[list]
[*] [b]Automatic re-read[/b]: the server re-reads zones.json on a timer and only broadcasts when the content changed.
[*] [b]Players who join later[/b]: receive the current zones.
[*] [b]Interval[/b]: sandbox option "Minidoracat MiniMap Zones → Zone data poll interval (seconds)", 10–3600 seconds, 60 by default. Lower values update faster but add server file reads.
[/list]
[h3]/reloadzones[/h3]
[list]
[*] [b]Re-read now[/b]: re-reads and broadcasts right away, then reports how many zones were loaded or why it failed.
[*] [b]Permission[/b]: on a server it needs the "manage mods" permission; in singleplayer it simply re-reads the local file.
[/list]
[h3]Deleting zones.json[/h3]
[list]
[*] [b]While the server runs[/b]: clears all zones (an empty file is recreated).
[*] [b]While the server is off[/b]: the next start generates the demo template again.
[/list]
=== 🧰 Generate zones template button
[list]
[*] [b]Where[/b]: the "Custom zones" section of the main mod's unified settings window.
[*] [b]How[/b]: pick a language from the dropdown (Follow current language / Traditional Chinese / Simplified Chinese / English / Japanese), then press "Generate zones template".
[*] [b]No misclicks[/b]: a confirmation dialog appears first.
[*] [b]Permission[/b]: the template applies immediately; on a server it requires the "manage mods" permission.
[/list]
[h3]Does it overwrite my file?[/h3]
[list]
[*] [b]zones.json missing or empty[/b]: the template is written directly.
[*] [b]zones.json has content[/b]: it is first backed up to a timestamped file (e.g. zones.20260101-120000.bak.json; each generation keeps its own backup), then overwritten.
[*] [b]Backup fails[/b]: zones.json is left untouched.
[/list]
[h3]What's in the template[/h3]
[list]
[*] Four demo zones, one of them a multi-rectangle L-shape.
[*] Two categories, "Demo: Town" and "Demo: Field".
[/list]
=== ⚙️ Writing zones.json
The file is JSON, read as UTF-8, so zone names can be in any language.
[h3]Minimal example[/h3]
[code]
{
  "zones": [
    {
      "name": "Event area",
      "rects": [[11882, 6928, 11918, 6961], [11918, 6961, 11950, 7000]],
      "fill": "#3B82F6",
      "fillAlpha": 0.3,
      "border": "#3B82F6",
      "borderAlpha": 0.9,
      "haloAlpha": 0.55,
      "category": "Events",
      "enabled": true
    }
  ]
}
[/code]
[h3]Fields[/h3]
[table]
[tr][th]Field[/th][th]Required[/th][th]Description[/th][/tr]
[tr][td]name[/td][td]Required[/td][td]The zone name shown on the map[/td][/tr]
[tr][td]rects[/td][td]Required[/td][td][i][[x1,y1,x2,y2], ...][/i] in world square coordinates, top-left to bottom-right, with x2 greater than x1 and y2 greater than y1[/td][/tr]
[tr][td]fill[/td][td]Optional[/td][td]Fill color, as "#RRGGBB" or [r, g, b]; defaults to red[/td][/tr]
[tr][td]border[/td][td]Optional[/td][td]Outline color, same format as fill; defaults to the fill color[/td][/tr]
[tr][td]fillAlpha[/td][td]Optional[/td][td]Fill opacity from 0 to 1, default 0.25; "alpha" is also accepted[/td][/tr]
[tr][td]borderAlpha[/td][td]Optional[/td][td]Outline opacity from 0 to 1, default 0.9[/td][/tr]
[tr][td]haloAlpha[/td][td]Optional[/td][td]0–1; draws a slightly larger dark underlay beneath the fill[/td][/tr]
[tr][td]category[/td][td]Optional[/td][td]The zone's category; players can pick which categories to show[/td][/tr]
[tr][td]enabled[/td][td]Optional[/td][td]Set to false to keep a zone's coordinates but hide it for now; omitted means true[/td][/tr]
[/table]
[list]
[*] [b]Irregular areas[/b]: combine several rectangles in one zone for L-shapes and other shapes.
[*] [b]haloAlpha[/b]: looks like an outline and costs less to draw than the border. Use it together with the border, or set borderAlpha to 0 and use it alone.
[*] [b]Categories left out of the checkbox list[/b]: a category containing a comma, or named exactly "-" or "nil" (the zone still shows).
[/list]
[h3]Other rules[/h3]
[list]
[*] [b]Building-sized zones[/b] (longest side of the whole zone 100 tiles or less): simplify automatically with zoom — a single block at mid zoom, hidden when zoomed far out, full detail up close. No field needed.
[*] [b]Limits[/b]: up to 500 zones, up to 64 rectangles per zone, and a file size of about 1 MB.
[*] [b]Mistakes[/b]: malformed or over-limit zones are skipped and logged in the server log; the other zones still show.
[*] [b]External tools[/b]: event-area tools, reset-zone marker tools, etc. can write zones.json directly.
[*] [b]Full format reference[/b]: [url=https://github.com/Minidoracat/MinidoracatMiniMapZonesFor42]GitHub README[/url]
[/list]
=== ⚙️ Player settings
All in the main mod's unified settings window:
[list]
[*] [b]Show custom zone layer[/b] (on by default): master switch; turn it off and no zones are drawn.
[*] [b]Category checkboxes in the "Custom zones" section[/b]: built from the categories the server actually uses, with select all / none; they refresh automatically if new zone data arrives while the window is open.
[*] [b]Zone names at any zoom[/b] (on by default): zone names stay visible when zoomed out so zones are easy to find; turn it off and small zones show their names only when zoomed in.
[/list]
=== ❓ FAQ
[h3]I can't see any zones?[/h3]
[list]
[*] Make sure the main mod is installed and up to date: if it is missing or too old, this mod shows no zones, and the main mod's other features are unaffected.
[*] Then check that "Show custom zone layer" is on and the category isn't unchecked.
[/list]
[h3]I edited the file and nothing changed?[/h3]
[list]
[*] Wait one poll interval or use /reloadzones.
[*] If the JSON is broken, the last successfully loaded zones stay on the map; the error goes to the server log and /reloadzones shows it directly.
[/list]
[h3]Do zones affect gameplay?[/h3]
[list]
[*] No, they are map markers only.
[/list]
[h3]Is Build 42.20.x supported?[/h3]
[list]
[*] No. The main mod currently requires Build 42.21.0 or later, and this mod follows it.
[*] Please update the game to 42.21.0 or later.
[/list]
[h3]What about my old zones.txt?[/h3]
[list]
[*] It is moved into zones.json automatically on first launch; if zones.json already had content, it is backed up to zones.premigrate.bak.json first.
[*] External tools should write zones.json from now on.
[/list]
[h3]Where are the vanilla resource points (military, medical, supermarket…)?[/h3]
[list]
[*] Those are built into the main mod; this mod isn't needed for them.
[/list]
[h3]Does it work in singleplayer?[/h3]
[list]
[*] Yes, singleplayer reads the local zones.json directly.
[/list]
=== 💬 Feedback
[list]
[*] [b]Please include[/b]:
[list]
[*] your game version
[*] what happened
[*] the relevant part of zones.json or the error from the server log
[/list]
[*] [b][url=https://github.com/Minidoracat/MinidoracatMiniMapZonesFor42/issues]GitHub Issues[/url][/b]
[*] [b][url=https://discord.gg/Gur2V67]Discord[/url][/b]
[/list]
