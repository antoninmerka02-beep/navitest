# NaviTest R9 – version 1.2

Voice guidance
- "Turn now" now arrives with a real safety margin: at least 40 m even at low speed (~2.5–3 s of
  travel), so it lands before the turn instead of during or after it.

Rider assistance
- Known route: camera/section warnings get 60% more lead than in free drive, since the position is
  certain from the pre-fetched data ahead of time (braking may be needed, not just steering).
- When OpenStreetMap doesn't distinguish a fixed camera from an unlinked average-speed-section point
  (common in Czechia), the spoken alert now says "Speed check" instead of guessing "Radar" — the tone
  and dashboard icon are unchanged, only the uncertain voice wording.

Not changed this version: the dashboard's left-column panel disappearing after switching to
Turn-by-Turn and back. This session's log shows no Turn-by-Turn content request at all, so nothing
pointed to a specific cause — see the chat for what to capture next time it happens.

Map data © OpenStreetMap contributors, OpenFreeMap, © OpenMapTiles.
