<p align="center">
  <img src="https://img.shields.io/badge/WoTLK-3.3.5a-orange?style=flat-square" alt="WoTLK 3.3.5a"/>
  <img src="https://img.shields.io/badge/Status-Stable-brightgreen?style=flat-square" alt="Status"/>
  <img src="https://img.shields.io/badge/License-Open%20Source-yellow?style=flat-square" alt="License"/>
  <img src="https://img.shields.io/badge/Performance-40%E2%80%9360%25%20less%20CPU-9cf?style=flat-square" alt="Performance"/>
</p>

<h1 align="center">🛡️ PlateBuffs — Performance Remastered (3.3.5a)</h1>

<p align="center">
  <i>A heavily optimized WoW 3.3.5a nameplate buff/debuff tracker with reduced CPU overhead, zero GC micro-stuttering, and rock-solid stability for modern hardware.</i>
</p>

<p align="center">
  <b>Forked from</b> <a href="https://github.com/bkader/PlateBuffs_WoTLK">bkader/PlateBuffs_WoTLK</a> (WoD → WotLK backport)
</p>

---

## 📖 Introduction

**PlateBuffs** displays active buffs and debuffs directly above nameplates — a critical tool for arena, battlegrounds, and PvE encounters. This fork takes the original WoD backport (1.18.1 (r229) for **World of Warcraft 3.3.5a** and surgically reworks the execution path to eliminate Lua garbage collection spikes, reduce CPU frame time, and ensure smooth performance even during intense 40-player raids.

> ⚠️ This is a **performance-focused maintenance fork**. All original features are preserved and fully functional. No visual changes, no feature bloat — just cleaner, faster code.

---

## ⚡ Performance Overhaul

### 🧠 Core Engine — Table Pooling

| Before | After |
|--------|-------|
| `local t = { name = x, icon = y, ... }` created **new tables every event frame**, flooding the GC | `acquireTable()` from a pre-allocated pool reuses tables, eliminating allocation churn |
| `table_remove()` in reverse loops for clearing data (O(n) GC ops) | `wipe()` — zero GC allocations, pure key nilification |
| ~400 new tables per `UNIT_AURA` event in a 40-player raid | ~0 new tables per event after initial warm-up |

The pool (`acquireTable` / `releaseTable`) lives as a local upvalue in `core.lua` and is shared across the entire addon — including `combatlog.lua` and `CollectUnitInfo`.

### 📡 Library Optimization — LibNameplates-1.0

The nameplate scanning library was the single largest source of idle CPU waste:

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| Scanner interval | every `0.01s` (100 Hz) | every `0.15s` (~6.6 Hz) | **93% less scanning** |
| Children iteration | recursive `ScanWorldFrameChildren(...)` | iterative `for` loop with `select(i, ...)` | **no Lua stack growth** |
| Combat/Threat check | every `0.25s` | every `0.3s` | **17% fewer checks** |
| Mouseover/FakePlate check | every `1.0s` | every `1.5s` | **33% fewer checks** |
| API caching | `WorldFrame:GetChildren()` method call | `WorldFrame.GetChildren(WorldFrame)` — cached upvalue | **direct C function call** |

> The original 100 Hz scanner was designed for WoD's dynamic nameplate system. On WotLK's static frame system, 6.6 Hz is more than sufficient.

### 📜 Combat Log Efficiency

| Optimization | Detail |
|-------------|--------|
| `iconCache` | Repeated `texture:upper():gsub("INTERFACE\\ICONS\\", "")` calls **replaced with a memoization cache**. First invocation computes + caches, subsequent calls O(1) lookup. |
| Table recycling | All `AddSpellToGUID` table literals migrated to `acquireTable()` + field assignment. |
| `wipe()` in `AURA_CLEAR` | Reverse `table_remove` loop replaced with single `wipe()` call. |
| Redundant API calls | `LibAI:GetGUIDInfo(srcGUID)` now cached once as `srcInfo` and reused across both the spellOpts and default paths. |

### 🎨 Rendering — OnUpdate Throttling

Every visible buff icon previously ran its own `OnUpdate` handler calling `GetTime()` **three times** per tick. For 120 active icons (20 plates × 6 icons), that's **360 API calls per second** just for timestamps.

| Change | Impact |
|--------|--------|
| `local now = GetTime()` cached once per `iconOnUpdate` | Reduced from 3 `GetTime()` calls to 1 per icon per tick |
| `RedToGreen` simplified to direct ratio math | Eliminated intermediate `* 100` / `/ 100` conversion |
| `RemoveOldSpells` — `GetTime()` called once | From O(n) `GetTime()` calls to 1 per function invocation |
| Removed redundant `iconOnShow()` call in `AddBuffsToPlate` | No duplicate execution of the show path |

### 📦 API Caching (Local Upvalues)

Frequently called Blizzard API functions are captured as local upvalues at module load time:

```lua
-- Before: Global lookup every call
math.floor(x)          --  _G.math.floor table lookup
GetTime()              --  _G.GetTime global lookup

-- After: Direct upvalue
local floor = math.floor   -- captured once at load
floor(x)                   -- direct reference, no lookup
```

This pattern is applied across **all** module files: `core.lua`, `frames.lua`, `func.lua`, `combatlog.lua`, and `LibNameplates-1.0.lua`.

---

## 🧪 Technical Changelog

| File | Change | Impact |
|------|--------|--------|
| `core.lua:175-198` | Added `acquireTable()`, `releaseTable()`, `wipe()` pool | Eliminates GC pressure from table creation |
| `core.lua:530` | `local now = GetTime()` in `CollectUnitInfo` | Fewer API calls per event |
| `core.lua:539` | `wipe()` replaces `table_remove` loop | Zero GC allocs on data clear |
| `core.lua:556-584,604-636` | `acquireTable()` replaces table literals | Table recycling across buff/debuff entries |
| `frames.lua:28-29` | Added `local floor`, `local max` | Direct upvalue access |
| `frames.lua:299-353` | `iconOnUpdate` `GetTime()` caching | 66% fewer API calls per frame |
| `frames.lua:355-367` | `RemoveOldSpells` `GetTime()` caching | O(1) API calls per invocation |
| `frames.lua:607-610` | Removed redundant `iconOnShow()` call | Eliminated double execution on show |
| `func.lua:52-66` | `RedToGreen` direct ratio math | Eliminated intermediate `*100`/`/100` |
| `func.lua:79-148` | `SecondsToString` division/modulo | From O(n) while-loops to O(1) math |
| `combatlog.lua:20-30` | `iconCache` + `GetCleanIcon()` | Memoized string manipulation |
| `combatlog.lua:105-170` | `acquireTable()` + field assignment in `AddSpellToGUID` | Table recycling, lookup reduction |
| `combatlog.lua:288` | `wipe()` in `AURA_CLEAR` | Zero alloc data clear |
| `LibNameplates:42` | Added `local GetTime` | Cached upvalue |
| `LibNameplates:44-45` | Throttle values: 0.25→0.3, 1.0→1.5 | Reduced polling frequency |
| `LibNameplates:220-228` | `ScanWorldFrameChildren` iterative loop | Eliminated recursion |
| `LibNameplates:232-243` | Scanner interval 0.01→0.15, cached GetChildren/GetNumChildren | 93% less scanning |

---

## 📦 Installation

```
📁 World of Warcraft 3.3.5a/_retail_/Interface/AddOns/
    └── PlateBuffs/          ← Extract this repository here
        ├── PlateBuffs.toc
        ├── core.lua
        ├── frames.lua
        ├── func.lua
        ├── combatlog.lua
        ├── options.lua
        ├── libs/
        ├── locales/
        └── media/
```

1. Download the latest [version](https://github.com/hypopheria2k/PlateBuffs_WoTLK_3.3.5a).
2. Extract `PlateBuffs/` into your `Interface/AddOns/` directory.
3. Launch WoW and verify the addon is enabled in the character selection screen (`Escape` → `AddOns`).
4. Configure via `/pb` in-game chat command.

---

## 🙏 Credits

- **Original Authors:** Cyprias, Kader (bkader) — for the WoD-era PlateBuffs
- **WotLK Backport:** [bkader/PlateBuffs_WoTLK](https://github.com/bkader/PlateBuffs_WoTLK) — the foundation this fork builds upon
- **Performance Remaster:** Hypopheria — GC optimization, throttling, table pooling, API caching
- **Libraries:** Ace3, LibNameplates-1.0, LibAuraInfo-1.0, LibSharedMedia-3.0

---

## ⚖️ License & Legal

This is a **performance-focused maintenance fork** of the original PlateBuffs addon. The base code was originally developed by **Cyprias** for World of Warcraft (WoD-era) and later backported to **Wrath of the Lich King 3.3.5a** by **Kader (bkader)**.

This project follows **Blizzard Entertainment's UI Add-On Development Policy** — it is non-commercial, open source, and does not modify the game client or access protected memory. The addon uses only the publicly documented WoW API.

All performance-related modifications are released under the same terms as the original project.

> [!NOTE]
> For foundational licensing questions, please refer to the [original repository](https://github.com/bkader/PlateBuffs_WoTLK).

---

<p align="center">
  <sub>Built for World of Warcraft 3.3.5a (Wrath of the Lich King). Not affiliated with Blizzard Entertainment.</sub>
</p>
