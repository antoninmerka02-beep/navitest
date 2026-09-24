# NaviTest R9 – version 0.7

Navigation fixes
- Maneuvers placed at the END of each Apple Maps step (instructions were one step early; roundabout
  exits and "current road" were affected too).
- Turn list + active turn index sent to the dashboard during navigation, like Garmin StreetCross
  (after route start, on connect, every 40 turns; global indices, leg distance, street name).

New
- English (default) and Czech UI – Settings → Language.
- Voice guidance (built-in iPhone text-to-speech), timing based on speed, street names,
  roundabout exits, "then …" for close turns, recalculation and arrival. Settings → Voice guidance.
- Log: saving off by default (Diagnostics → Save log), "Open log" with export, navigation steps on a separate page.

Map data © OpenStreetMap contributors, OpenFreeMap, © OpenMapTiles.
