# NaviTest R9

Testovací appka pro Yamaha přístrojovky s Garmin CCU (protokol NaviLite).
Ověřuje: spojení iPhone ↔ motorka, režim MAPA (obrázky) i TURN-BY-TURN (nativní šipky),
běh na pozadí se zamčeným telefonem.

## Build
Každý push do repozitáře spustí GitHub Actions (záložka Actions → „Build NaviTest IPA“).
Hotový soubor je dole ve výsledku buildu jako artefakt **NaviTest-ipa** (zip s NaviTest.ipa).

## Instalace
Sideloadly → přetáhnout NaviTest.ipa → Apple ID → Start.
Na iPhonu: Nastavení → Obecné → Správa VPN a zařízení → důvěřovat vývojáři.

## Test
1. StreetCross a Pillion úplně zavřít (ideálně StreetCross dočasně smazat), jinak si spojení s motorkou zaberou samy.
2. Zapnout zapalování, telefon spárovaný s motorkou, na přístrojovce vybrat navigaci.
3. Otevřít NaviTest – připojí se sám. Povolit polohu.
4. Přepnout na přístrojovce mezi mapou a turn-by-turn.
5. Zamknout telefon, dát do kapsy, pár minut počkat – obraz musí dál ukazovat běžící čas.
6. V appce Log → „Exportovat celý log“ a poslat.
