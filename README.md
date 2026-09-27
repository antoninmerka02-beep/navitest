# NaviTest R9 – version 1.0

Connection and UI
- Dashboard left column: route start sent once per route when the dash shows navigation;
  reopening the map sends only the current state (like Garmin) – the column no longer disappears.
- Bike Favourites list: only Home, Work and real favourites (no search history).
- Times as "1 h 30 min"; day/night change is sent to the dash immediately; place card buttons on two rows.

Rider assistance
- Data in ~3 km cells, cached for 7 days, 4 Overpass servers with rotation and retries.
- Works during navigation and in free drive (current road limit + street name on the dash).
- Duplicate cameras merged (150 m), cameras facing the other way skipped (when direction is known),
  section control detected from relations and from tagged camera pairs; camera tags logged.
- Speeding: once when exceeding, again after slowing down or a limit change; speed source actual or
  speedometer (+ correction %); every alert logs bike speed, GPS speed, limit and tolerance.
- Alert sound (incl. Silence) + "Announce by voice" per alert type: tone, then the spoken message.
- Small icons for cameras, section control, red light cameras and school zones on the bike map.

Voice
- Apple's two-part roundabout instructions merged into one (entry position, exit direction/number).
- New scheme: Minimal = ahead + at the junction; Normal = twice ahead + at the junction;
  Detailed = Normal + "now" (incl. "Take the exit now" at roundabouts).

Routes and comfort
- Routes button on the map; route preview with up to 3 alternatives and a Start button.
- Edit saved routes in place, edit a stop by search or by moving a pin on the map, delete stops.
- Favourites with a custom name and icon.
- Navigation settings: alternatives, automatic recalculation + off-route distance, auto zoom by speed,
  kilometres / miles.

Map data © OpenStreetMap contributors, OpenFreeMap, © OpenMapTiles.
