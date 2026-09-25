# NaviTest R9 – version 0.8

Fixes
- Log off = nothing is kept. Music volume comes back after voice prompts.
- Route start + turn list re-sent whenever the dashboard opens its navigation screen (left-column arrows).
- Destination name instead of "pravé straně"; long street names shortened for the dashboard.
- Roundabout exit direction from the instruction text, otherwise from the route ~200 m past the entry.

Map and image
- Smooth movement: position predicted between GPS fixes (iPhone GPS ≈ 1 Hz), fresh position every frame.
- Up to 20 fps (warning above 6). Checkered finish flag on the bike map.
- Day / night: automatic by the sun, or manual; applies to the bike map, the phone and the dashboard.

Voice and audio
- Instruction frequency (minimal / normal / detailed), speech rate, voice language separate from the app,
  voice choice, output (default / Bluetooth / phone speaker) and playback mode (media / phone call).

Search
- Tap a shop/POI on the phone map or long-press anywhere → place card.
- Search without picking a suggestion (or a chain like "Kaufland") → all results nearby, sorted, with pins.
- "Nearby Gas Stations" from the bike menu (Apple Maps, fallback to OpenStreetMap data).

Map data
- Custom tile source (OpenMapTiles vector tiles), stored map size and delete.

Map data © OpenStreetMap contributors, OpenFreeMap, © OpenMapTiles.
