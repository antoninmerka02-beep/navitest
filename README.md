# NaviTest R9 – version 1.3

Dashboard
- Route start is sent only after the dash really asks for the map / turn list (left column also when
  the route was started before the bike connected).
- Return via "Change View → Default View" (2+ map STOPs in a row) is detected and handled separately
  from a normal return. Diagnostics → "After Change View": full route start (default) / only "done" /
  nothing – to test which one brings the left column back. Every return is logged.

Navigation
- U-turn detection: when a new route starts behind the rider (Apple Maps doesn't know the direction of
  travel), the voice says "Make a U-turn when it is safe", the dash shows the U-turn arrow and other
  instructions are held back until the rider has turned around. Rerouting is calmer meanwhile
  (45 s instead of 15 s), "Recalculating" is spoken at most every 30 s.
- Location permission "Always": the iPhone may start the app on its own when the bike connects;
  with "While Using" it got no location then.

Rider assistance
- Data per cell in two queries: light (cameras, sections, schools) first, heavy (speed limits) after –
  cameras arrive even when the limits time out.
- Tapping a camera / section / red light / school pin on the phone map opens an info card (type,
  limit, address); section control is drawn in red on the map.

Map data © OpenStreetMap contributors, OpenFreeMap, © OpenMapTiles.
