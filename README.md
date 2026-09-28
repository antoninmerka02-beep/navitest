# NaviTest R9 – version 1.1

Rider assistance
- Every alert now logs the triggering coordinate (or speeding) for diagnosing unexpected beeps.
- Nearby duplicate cameras (within 150 m) merged in free drive too, not just on a route.
- More Overpass mirrors, with a per-server cooldown after a failure so a struggling server is skipped
  for a while instead of being retried immediately.
- Free-drive speed limit refreshes faster when it changes (a stale check no longer waits for movement).
- Speeding voice alert now names the limit ("Watch your speed, limit 50").
- New "Warning distance" setting for cameras/sections/schools: Close / Normal / Far.
- Cameras, section control, red light cameras and school zones now show as pins on the phone map too
  (not just the bike map).

Voice guidance
- Retuned junction timing: first announcement 300–500 m ahead depending on speed, "now" with a safe
  ~2-second lead (about 20–30 m in town, further at higher speed). Roundabouts unchanged.

Map data © OpenStreetMap contributors, OpenFreeMap, © OpenMapTiles.
