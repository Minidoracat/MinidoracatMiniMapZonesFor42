<!-- Steam 討論區貼文稿源（英文）；簡介只放摘要，詳細內容以本串為準 -->
<!-- 討論串網址：https://steamcommunity.com/workshop/filedetails/discussion/3768276209/586187095760055791/ -->
<!-- 標題：📖 Zones Guide for Server Admins -->

[b]繁體中文版：[/b][url=https://steamcommunity.com/workshop/filedetails/discussion/3768276209/586187095760055665/]Zones 完整說明（伺服器管理員）[/url]

Zones lets a server mark custom areas on the minimap and the world map (a translucent fill, outline and name) — event areas, reset zones and so on. Zones are [b]map markers only[/b]; they add no PVP, safe-zone or other gameplay mechanics. This thread is for server admins; regular players only need the "Player settings" section.

[h2]🚀 Quick start[/h2]
[olist]
[*] Install the main mod [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763913359]MiniMap for B42[/url] and this mod (the game version follows the main mod: currently Build 42.21.0 or later), then start the server once (in singleplayer, just load a game)
[*] The generated template is at [b]Zomboid/Lua/MinidoracatMiniMapZones/zones.json[/b]. It contains four demo zones, written in the server's language
[*] Edit the demo zones or add your own, then save
[*] Wait for the automatic refresh (60 seconds by default), or have an admin type [b]/reloadzones[/b] in chat to apply it immediately — no restart needed
[/olist]

[h2]📝 Writing zones.json[/h2]
The file is JSON, read as UTF-8, so zone names can be in any language. Minimal example:
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
[list]
[*] [b]name[/b] (required): the zone name shown on the map
[*] [b]rects[/b] (required): [i][[x1,y1,x2,y2], ...][/i] in world square coordinates, top-left to bottom-right, with x2 greater than x1 and y2 greater than y1. Combine several rectangles in one zone for L-shapes and other irregular areas
[*] [b]fill[/b] / [b]border[/b]: fill and outline colors, as "#RRGGBB" or [r, g, b]. Fill defaults to red; border defaults to the fill color
[*] [b]fillAlpha[/b] / [b]borderAlpha[/b]: opacity from 0 to 1, defaulting to 0.25 and 0.9. "alpha" is also accepted for fillAlpha
[*] [b]haloAlpha[/b] (optional, 0–1): draws a slightly larger dark underlay beneath the fill. It looks like an outline and costs less to draw than the border. Use it together with the border, or set borderAlpha to 0 and use it alone
[*] [b]category[/b] (optional): the zone's category; players can pick which categories to show. A category containing a comma, or named exactly "-" or "nil", is left out of the checkbox list (the zone still shows)
[*] [b]enabled[/b] (optional): set to false to keep a zone's coordinates but hide it for now; omitted means true
[/list]
[b]Other rules[/b]
[list]
[*] Building-sized zones (longest side of the whole zone 100 tiles or less) simplify automatically with zoom: a single block at mid zoom, hidden when zoomed far out, full detail up close. No field needed
[*] Limits: up to 500 zones, up to 64 rectangles per zone, and a file size of about 1 MB
[*] Malformed or over-limit zones are skipped and logged in the server log; the other zones still show
[*] External tools (event-area tools, reset-zone marker tools, etc.) can write zones.json directly
[/list]
Full format reference: [url=https://github.com/Minidoracat/MinidoracatMiniMapZonesFor42]GitHub README[/url]

[h2]🔄 Sync and reloading[/h2]
[list]
[*] The server re-reads zones.json on a timer and only broadcasts when the content changed; players who join later receive the current zones
[*] Set the interval in the sandbox options under "Minidoracat MiniMap Zones → Zone data poll interval (seconds)": 10–3600 seconds, 60 by default. Lower values update faster but add server file reads
[*] [b]/reloadzones[/b]: re-reads and broadcasts right away, then reports how many zones were loaded or why it failed. On a server it needs the "manage mods" permission; in singleplayer it simply re-reads the local file
[*] Deleting zones.json while the server runs clears all zones (an empty file is recreated); deleting it while the server is off makes the next start generate the demo template again
[/list]

[h2]🧩 Generate zones template button[/h2]
Open the main mod's unified settings window, go to the "Custom zones" section, pick a language from the dropdown (Follow current language / 繁體中文 / 简体中文 / English / 日本語), then press "Generate zones template".
[list]
[*] A confirmation dialog appears first to prevent misclicks
[*] If zones.json is missing or empty, the template is written directly
[*] If zones.json has content, it is first backed up to a timestamped file (e.g. zones.20260101-120000.bak.json; each generation keeps its own backup), then overwritten. If the backup fails, zones.json is left untouched
[*] The template applies immediately; on a server it requires the "manage mods" permission
[*] The template has four demo zones (one is a multi-rectangle L-shape) and shows off two categories, "Demo: Town" and "Demo: Field"
[/list]

[h2]👀 Player settings[/h2]
All in the main mod's unified settings window:
[list]
[*] [b]Show custom zone layer[/b] (on by default): master switch; turn it off and no zones are drawn
[*] [b]Category checkboxes in the "Custom zones" section[/b]: built from the categories the server actually uses, with select all / none; they refresh automatically if new zone data arrives while the window is open
[*] [b]Zone names at any zoom[/b] (on by default): zone names stay visible when zoomed out so zones are easy to find; turn it off and small zones show their names only when zoomed in
[/list]

[h2]❓ FAQ[/h2]
[list]
[*] [b]I can't see any zones.[/b] Make sure the main mod is installed and up to date (if it is missing or too old, this mod shows no zones, and the main mod's other features are unaffected). Then check that "Show custom zone layer" is on and the category isn't unchecked
[*] [b]I edited the file and nothing changed.[/b] Wait one poll interval or use /reloadzones. If the JSON is broken, the last successfully loaded zones stay on the map; the error goes to the server log and /reloadzones shows it directly
[*] [b]Do zones affect gameplay?[/b] No, they are map markers only
[*] [b]Is Build 42.20.x supported?[/b] No. The main mod currently requires Build 42.21.0 or later, and this mod follows it; please update the game to 42.21.0 or later
[*] [b]What about my old zones.txt?[/b] It is moved into zones.json automatically on first launch (if zones.json already had content, it is backed up to zones.premigrate.bak.json first). External tools should write zones.json from now on
[*] [b]Where are the vanilla resource points (military, medical, supermarket…)?[/b] Those are built into the main mod; this mod isn't needed for them
[*] [b]Does it work in singleplayer?[/b] Yes, singleplayer reads the local zones.json directly
[/list]

[h2]💬 Reporting issues[/h2]
Please include your game version, what happened, and the relevant part of zones.json or the error from the server log.
[list]
[*] GitHub Issues: [url=https://github.com/Minidoracat/MinidoracatMiniMapZonesFor42/issues]https://github.com/Minidoracat/MinidoracatMiniMapZonesFor42/issues[/url]
[*] Discord: [url=https://discord.gg/Gur2V67]https://discord.gg/Gur2V67[/url]
[/list]
