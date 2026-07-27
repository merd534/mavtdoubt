# Визуальный и структурный референс города

Источник: `картинки/Neon-Noir City Map _ Cross-Section.png` и
`картинки/Neon-Noir City Map _ Foggy Nightscape.png` (оба 5408x3072).
Всё ниже извлечено из этих изображений и является **обязательным** ориентиром
для `CityGenerator` (Фаза 2) и `GraphicsManager` (Фаза 3).

---

## 1. Атмосфера (что реально видно на референсах)

| Признак | Наблюдение | Как реализуем |
|---|---|---|
| Базовый тон | Синевато-чёрный, почти без светлых пятен. Средняя яркость кадра крайне низкая. | `default_clear_color = #0A0C12`, экспозиция низкая, тонемап ACES |
| Доминанта неона | Розово-малиновый (`#FF2A6D`) — **вертикальными** полосами по граням башен ядра | Вывески-эмиссивы ориентированы вертикально на фасадах >60 м |
| Второй цвет | Циан (`#05D9E8`) — **горизонтальными** полосами и на нижних уровнях, свечение окон жилья | Ленты на 1–4 этажах, окна residential |
| Улицы | Янтарный натрий (`#FFA23A`) — **только** магистрали и фонари, диагонали, режущие сетку | Артериальные дороги + `OmniLight3D` цепочками |
| Трущобы / гетто | Почти чёрные кварталы, редкие тёплые окна, ноль вывесок | density 0.25, emission_budget 0.1 |
| Мокрый асфальт | Вертикальные размазанные отражения вывесок на дороге | SSR + roughness 0.12 на дорогах, normal-map дождя |
| Туман | Слоями над рекой и по краям карты, скрывает горизонт | `VolumetricFog`, плотность растёт от центра к краю и у воды |
| Река | Тёмная, зеркальная, 4 подсвеченных моста янтарём | Плоскость с SSR, мосты как отдельные пролёты |
| Промзона | Дымовые трубы, шлейфы, холодный свет | Particle-дым, `#7DF9FF` прожекторы |

### Палитра (константы для `CityAtlas.PALETTE`)

```
base_asphalt    #0A0C12    fog_near        #0E1420
base_concrete   #12151E    fog_far         #151B29
neon_magenta    #FF2A6D    neon_rose       #FF5C8A
neon_cyan       #05D9E8    neon_ice        #7DF9FF
neon_purple     #A855F7    neon_green      #39FF88
sodium_amber    #FFA23A    sodium_deep     #FF6B1A
police_red      #E8253F    window_warm     #FFC46B
```

---

## 2. Районы (объединённый список из обоих референсов)

Референс №1 даёт: Northview Industrial, Skyline District, East End Slums,
Harbor District, Westfield Commercial, Downtown Core, Old Town, Riverside,
Greyhollow Ghetto, Southgate Residential.

Референс №2 даёт: Downtown Core, Financial District, Industrial Zone, Old Town,
Harbor District, Slums, Entertainment District, Residential Area, Waterfront,
Outskirts.

Итого 16 уникальных именованных районов + `Outskirts` (кольцо-фолбэк по всей
карте, гарантирующий, что `district_at()` никогда не вернёт пустоту) = **17
записей в `CityAtlas.DISTRICT_TABLE`**.

## 3. Композиция (по взаимному расположению подписей на референсах)

```
              NORTHVIEW INDUSTRIAL ── INDUSTRIAL ZONE ──┐
                     │                                  │
 WESTFIELD ── FINANCIAL ── SKYLINE ──┐            EAST END SLUMS
 COMMERCIAL       │           │      │                  │
      │      DOWNTOWN CORE ───┴── OLD TOWN ── HARBOR DISTRICT
 GREYHOLLOW       │                 (за рекой)     (дальний восток)
 GHETTO           │                      │
      │      SOUTHGATE RESIDENTIAL ── RIVERSIDE
 RESIDENTIAL      │
    AREA ── ENTERTAINMENT ── WATERFRONT ── SLUMS (ЮВ)
                        OUTSKIRTS (кольцо по периметру)
```

Река входит с северо-востока, идёт на юго-восток, отсекает Old Town / Harbor /
East End Slums от основного массива. Мостов — 4.

## 4. Статистика с панели MAP INFO (референс №2)

```
TOTAL AREA:          8.7 KM²
PLAYABLE LOCATIONS:  120+
SAFE HOUSES:         15
ROOFTOP ACCESS:      YES
UNDERGROUND NETWORK: YES
WEATHER:             DYNAMIC (RAIN / FOG)
```

**Наш масштаб больше:** 4600 × 3400 м = **15.64 км²** застраиваемой площади
(запрос «как в GTA»). Референсные 8.7 км² взяты как минимум, а не как цель.
Локаций — 168, убежищ — 15 (как на референсе), крыши и метро — да.

## 5. Типы локаций (легенда KEY LOCATIONS, референс №2)

Main Hub, Mission Location, Point of Interest, Shop/Store, Hotel,
Restaurant/Cafe, Bar/Club, Parking (×2 типа), Transit Station,
Park/Green Space, Bridge, Dock/Harbor, Church/Temple, School/University,
Government Building, Entertainment, Gated Community, Danger Zone.

Легенда референса №1 добавляет: Apartments, Warehouses, Police Stations,
Hospitals, Markets, Piers & Docks, Train Stations.

Все 24 типа заведены в `CityAtlas.LocationKind`.

## 6. Именованные POI (панель POINTS OF INTEREST, референс №2)

The Grand Hotel · Neon Dreams Club · Rain City Market · Black Dock Yards ·
Old Cemetery · Skyline Observatory · City Hall · St. Mary's Church ·
Victoria Park · Eastside Slums · Industrial Complex · Riverdale Bridge ·
South Harbor · West End Station · North Point Lighthouse ·
The Forgotten Tunnels

Все 16 — рукотворные landmark'и с фиксированными координатами в `CityAtlas.LANDMARKS`,
процедурная генерация обязана их уважать и застраивать вокруг, а не поверх.
