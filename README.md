# STRIPBUS User Manual

Welcome to the comprehensive guide for the StripBus system in REAPER. StripBus turns any REAPER track into a customizable console strip: knobs, switches and Gain Reduction meters that live directly in the mixer (MCP), drive your real plugins, and travel with your presets and track templates.

This document covers the package content, the setup, the exhaustive list of every menu option, every mouse and keyboard gesture, the Direct Link workflow, and the preset / recipe system.



## 1. What's in the package

| File | Role |
| --- | --- |
| `StripBus Panel 050 / 100 / 150 / 200 / 300 / 400 / 600 px` | The seven JSFX panels. Identical engine, only the fixed height changes. |
| `stripbus_panel.jsfx-inc` | The shared engine imported by all seven panels. Not loaded directly. |
| `StripBus.jsfx` (*StripBus GR*) | Audio JSFX that **measures** Gain Reduction for compressors that don't report it to REAPER. |
| `StripBus System.lua` | Background script. Required for Gain Reduction, Direct Link, renaming, custom colors and preset sharing. |
| `StripBus Check.lua` | Diagnostic script: tells you which plugins report their Gain Reduction natively. |
| `FXChains/*.RfxChain` | Seven ready-made FX chains (panel + plugin, already mapped). |

### Installation

*   Copy the panels, `stripbus_panel.jsfx-inc` and `StripBus.jsfx` into `<REAPER resource path>/Effects/StripBus/` (the provided FX chains expect exactly this folder name).
*   Copy the two `.lua` scripts into `<REAPER resource path>/Scripts/` and add them via *Actions > Show action list > New action > Load ReaScript*.
*   Copy the `.RfxChain` files into `<REAPER resource path>/FXChains/` if you want the ready-made chains.
*   In the mixer, enable **Show embedded UI in MCP** on the panel's FX slot so the StripBus interface is visible in your mixer strip.

### StripBus System.lua

Run it once; it stays in the background and handles everything the JSFX cannot do by itself:

*   Finds every compressor or gate on your tracks that reports `GainReduction_dB` to REAPER and feeds the GR meters.
*   Maintains the **Direct Links** between panel elements and real plugin parameters (both directions).
*   Rebuilds links from **recipes** when a preset, track template or FX chain is loaded.
*   Serves the **Rename** dialog, the **Palette** color picker, and the value pop-up shown when you hover or tweak a linked control.
*   Keeps the preset banks of the seven panel sizes identical (see section 8).

With SWS installed you can attach it to the *Global Startup Action* so it launches with REAPER.

> Several features are simply inactive while the script is not running: renaming, custom palette colors, GR metering, learning and value pop-ups. If a menu entry seems to do nothing, check the script first.

### StripBus Check.lua

If a compressor's Gain Reduction doesn't show up on a meter, run this script while the project is playing. It lists all plugins on the track and tells you whether each one reports its Gain Reduction natively. If it doesn't, use the *StripBus GR* JSFX described in section 6.

### Panels

Pick the panel height that suits your mixer in the FX browser. Whatever size you choose you can add up to **50 elements**; the panel scrolls when the content is taller than the module. If a layout ends up cramped, use **Copy layout & links** and paste it into a taller panel — layout, links and recipe come along.

**Presets are shared by all seven panel sizes.** REAPER stores user presets per plugin, and each panel height is a separate plugin to REAPER — so, left alone, a preset saved on the 300 px module would only ever show up on the 300 px module. `StripBus System.lua` keeps the seven preset banks identical, so any preset you save from any size is immediately available from every other size. Nothing to export or import; the only requirement is that the script is running when you save the preset. Renaming or deleting a preset applies to all sizes too. See section 8.



## 2. The elements

| Element | What it does |
| --- | --- |
| **Knob** | Rotary control, 0–127. Sends a MIDI CC and/or drives a linked plugin parameter. |
| **Toggle** | On/off switch (0 / 127), with an optional separate label for the ON state. |
| **Radio** | Multi-position selector, 2 to 6 steps, horizontal or vertical. |
| **GR meter** | Needle VU showing gain reduction, with a calibration screw. |
| **GR bar** | Bar-graph gain reduction meter, horizontal or vertical. |
| **Separator** | Horizontal line to group controls. |
| **Title** | Standalone text label. |

New knobs, toggles and radios are automatically assigned the first free CC number and named after it (`CC 12`); changing the CC of a still-auto-named element renames it accordingly. As soon as you rename it manually, the name stops following the CC.

Separators, titles and meters are inert during playback: clicks pass through them, so they never get in the way of a nearby knob. They only become grabbable in **Edit mode**.



## 3. Menu reference

Right-click anywhere in a panel. Clicking on an element opens that element's menu; clicking on the background opens the panel menu. Menus adapt to the element type — the lists below are exhaustive.

### 3.1 Background menu

**Adding elements** (the new element lands where you right-clicked, if the cell is free)

*   **Add knob**
*   **Add toggle**
*   **Add radio**
*   **Add GR meter**
*   **Add GR bar... > Horizontal / Vertical**
*   **Add separator**
*   **Add title**

**Display & layout**

*   **Edit mode** — Enables moving and resizing elements by dragging. A yellow `EDIT` label and the alignment grid are shown while active.
*   **Show names** — Globally shows/hides the labels under the controls.
*   **Show knob rings** — Globally shows/hides the colored value ring around knobs.
*   **Scroll group: ...** — *Independent*, *Group A*, *B*, *C*, *D*. Panels in the same group scroll together, which is invaluable when you have many tracks: scroll one strip and the whole group follows.
*   **Color...** — Background color of the panel: **Palette...** (custom color picker) plus White, Light gray, Gray, Dark gray, Dark, Green, Red, Blue, Yellow, Orange, Pink.
*   **Grid: N columns...** — 1 to 4 columns. Changing it re-flows the existing layout.

**Clipboard**

*   **Copy layout & links** — Copies the whole panel (elements, names, colors, grid, links and the preset recipe) to a global clipboard shared by every StripBus panel.
*   **Paste layout & links** — Pastes it into the current panel. Greyed out when the clipboard is empty.

**Preset links** (see section 7)

*   **Preset links: N on \<plugin\>** — Status line: how many links the current recipe holds and for which plugin. Reads *none yet* or *forgotten* when there is no recipe.
*   **Capture links now** — Forces the panel to read the track and build the recipe immediately. Greyed out when there is nothing to capture.
*   **Forget preset links** — Clears the recipe so the links won't travel with the preset.

**Reset**

*   **Reset All Positions** — Sends every knob, toggle and radio back to its default value (0, 64 for bipolar, 127 for *Init at max*), and resets the trim of every meter to 0.
*   **Resend all CCs** — Re-broadcasts every current value, to resync a plugin that lost state.
*   **Clear all** — Deletes every element on the panel. **Cannot be undone.**

### 3.2 Knob / toggle / radio menu

*   **Rename  (current name)...** — Opens a text dialog (needs `StripBus System.lua` running).
*   **Rename (ON)  (current name)...** — *Toggles only.* Label displayed while the toggle is engaged.
*   **CC number  (CC n)...** — MIDI CC 0 to 127, presented in eight submenus of sixteen.
*   **MIDI channel  (ch n)...** — *All channels* or channel 1 to 16.
*   **Color...** — **Palette...** (custom color) plus the eleven presets listed above.
*   **Size...** — Tiny, Small, Medium, Large, Very large, Huge.
*   **Positions  (n)...** — *Radios only.* 2 to 6 steps.
*   **Vertical** — *Radios only.* Switches the row of buttons to a column.
*   **Momentary** — *Toggles only.* The switch stays ON only while the mouse button is held.
*   **Bipolar** — *Knobs only.* Default/reset value becomes 64 and the ring fills from the center — for pan, EQ gain, etc.
*   **Init at max** — *Knobs only.* Default/reset value becomes 127.
*   **Learn plugin parameter...** — Starts the Direct Link listening mode (section 5).
*   **Re-learn plugin parameter...** / **Clear plugin link** — Shown instead, once the element is linked.
*   **Edit mode**, **Duplicate**, **Delete** — Duplicate copies size, color, flags, name and, for a toggle, its ON name; the copy gets its own free CC.

### 3.3 GR meter menu

*   **Rename  (name)...**
*   **Source  (Compressor n)...** — Which plugin on the track the meter reads: **Compressor 1 to 4** or **Gate 1 to 2**. When the script knows the track, sources with no matching plugin are flagged `-- none`. Gates are identified by keywords in the plugin name (*gate*, *expander*, *Pro-G*); a gate detected as a compressor is simply read as the corresponding Compressor number.
*   **Linear   0 4 8 12 16 20** / **Exponential   0 2 4 6 10 20** — Scale of the dial.
*   **Color...** — Palette + eleven presets.
*   **Size  (n px)...** — Tiny 90 px, Small 105 px, Medium 120 px, Large 150 px, Very large 180 px, Huge 210 px.
*   **Show value** — Numeric dB readout under the needle.
*   **Peak hold** — Holds the maximum reading for a moment.
*   **Edit mode**, **Duplicate**, **Delete** — Duplicating a meter keeps its source and its trim.

### 3.4 GR bar menu

*   **Rename  (name)...**
*   **Source  (Compressor n)...** — Same list as the GR meter.
*   **Linear / Exponential** — Same two scales.
*   **Color...** — Palette + eleven presets.
*   **Size  (n px)...** — Tiny 36 px, Small 48 px, Medium 60 px, Large 72 px, Very large 96 px, Huge 120 px.
*   **Vertical** — Flips the bar between horizontal and vertical.
*   **Peak hold**
*   **Edit mode**, **Duplicate**, **Delete**

### 3.5 Title and separator menus

*   **Rename title  (text)...** — *Titles only.*
*   **Color...** — Palette + eleven presets.
*   **Edit mode**, **Duplicate**, **Delete**

### 3.6 Palette (custom colors)

Every **Color...** submenu starts with **Palette...**, which opens the operating system color picker and assigns the exact RGB you choose — to a single element or to the panel background. StripBus adapts the contrast of labels and rings to the luminance of your color automatically. This entry needs `StripBus System.lua` running.



## 4. Mouse & keyboard

### Normal mode (playing)

| Gesture | Result |
| --- | --- |
| Drag up/down on a knob | Change the value |
| **Ctrl** + drag on a knob | Fine adjustment (≈ 3× slower) |
| Double-click a knob | Reset to its default (0, or 64 bipolar, or 127 *Init at max*) |
| Wheel over a knob, when the panel cannot scroll | ±1 step |
| **Ctrl** + wheel over a knob | ±1 step, even when the panel scrolls |
| **Ctrl + Shift** + wheel over a knob | ±5 steps |
| Click a toggle | Flip it — or hold it, if *Momentary* is on |
| Click / drag on a radio | Select the position under the mouse |
| Drag the VU calibration screw | Trim the meter, −6 to +6 dB in 0.5 dB steps (the reading shows `TRIM +x.x`) |
| Double-click the VU screw | Reset the trim to 0 |
| Wheel over the panel | Scroll the panel |
| **Shift** + wheel | Scroll faster |
| Drag the background, or the right-edge scrollbar | Scroll the panel |
| Hover or tweak a linked control | Pop-up with the real value read from the target plugin |
| Right-click | Contextual menu |

A click slightly off a control still grabs the nearest one, so small knobs stay easy to catch in a dense strip.

### Edit mode

| Gesture | Result |
| --- | --- |
| Drag an element | Move it. Position snaps to a 1/8-cell grid, so elements can be tucked between columns and rows. |
| **Shift** + drag up/down | Resize the element continuously (finer than the *Size...* presets) |
| Right-click | Same menus as usual |

The alignment grid drawn in edit mode marks eighths, quarters and whole cells with increasing brightness. Layouts made with older versions are converted automatically to the finer grid the first time they load.



## 5. Parameter Linking (Direct Link)

StripBus offers a Direct Link system that completely bypasses REAPER's native MIDI CC or Parameter Modulation limits. The panel controls the plugin, and if you move the plugin's GUI the panel updates instantly (bidirectional sync).

Once a parameter is mapped, the source value is displayed in a small pop-up when you hover or tweak the control, so you read the actual data from the targeted plugin.

**The method to link correctly:**

1. Ensure the background script (`StripBus System.lua`) is running.
2. In the StripBus panel, right-click the knob, toggle or radio you want to link.
3. Select **Learn plugin parameter...**. The element starts flashing to indicate it is listening.
4. Open the FX window of the plugin you want to control (it must be on the same track).
5. Move the parameter you want to link (click and drag it slightly with your mouse).
6. The element stops flashing and displays a success message. The link is now active in both directions.

Learning times out after about 20 seconds, and any click in the panel cancels it. To remove a link, right-click the element and select **Clear plugin link**; to point it somewhere else, use **Re-learn plugin parameter...**.

Direct Link applies to knobs, toggles and radios. Meters are fed by the GR system instead (section 6). Plugins inside FX containers are supported.



## 6. Gain Reduction metering

GR meters and GR bars read a single value per source: **Compressor 1 to 4** or **Gate 1 to 2**, counted in FX-chain order on the same track as the panel.

**Two ways to get that value:**

1. **Natively** — Many plugins report `GainReduction_dB` to REAPER. `StripBus System.lua` picks these up automatically; nothing else to do. Run `StripBus Check.lua` while playing to see which of your plugins qualify.

2. **With the *StripBus GR* JSFX** — For compressors that report nothing, StripBus measures the reduction itself by comparing the signal before and after the plugin:
   *   Insert one instance of **StripBus GR** *above* the compressor, set **Measurement point** to `In - above the compressor`.
   *   Insert a second instance *below* the compressor, set **Measurement point** to `Out - below the compressor`.
   *   Set **Compressor (number on this track)** to the same number on both, and point your GR meter at that same *Compressor n*.
   *   **Makeup** — `Auto` tracks the plugin's makeup gain by itself (recommended); `Manual` lets you enter the exact **Manual makeup (dB)** you dialed in the compressor, from 0 to 24 dB.

**Reading and adjusting the meter:**

*   **Scale** — *Linear* (0 4 8 12 16 20) or *Exponential* (0 2 4 6 10 20), the latter giving more resolution in the first few dB.
*   **Trim** — Drag the screw at the bottom of the needle meter to offset the reading by up to ±6 dB, which is handy to match the calibration of a plugin's own meter. Double-click the screw to zero it.
*   **Show value** displays the numeric dB, **Peak hold** freezes the maximum for a moment.



## 7. Presets, recipes and plugin mapping

A direct link uses a unique ID (GUID) tied to the specific instance of the plugin on your track. Normally that would mean the link breaks whenever the track is duplicated or a template is loaded. StripBus solves this with **recipes**.

**How recipes work:** when you link a parameter, StripBus remembers the exact instance *and* writes a relative recipe into the JSFX state — the **name of the target plugin** and the **parameter number** for each element. On load, `StripBus System.lua` looks for a plugin with that exact name on the new track and rebuilds every link for the new instance.

**One recipe describes one plugin.** An element learned on a *different* plugin still works (its link is intact), but it does not join the recipe — so it will not travel with the preset. This matters when you derive one preset from another: load "SSL 4000 E", re-learn everything onto an SSL 4000 G, and each re-learn removes that element from the 4000 E recipe. The panel then adopts the 4000 G automatically (within two seconds of the recipe becoming empty), but **the preset you saved before that point carries no links at all** — check the background menu, it must read `Preset links: N on <your plugin>` and not `none yet`, then save the preset again.

**How to create reusable mappings:**

1. Add a plugin (e.g. an EQ or a compressor) to your track.
2. Add a StripBus Panel JSFX.
3. Use the Learn method (section 5) to map all the controls you need.
4. Check that the background menu reads `Preset links: N on <plugin>`.
5. Save it — as a JSFX preset, an FX chain, or a track template.

Loading it on any other track rebuilds all the bidirectional links automatically. Map your favorite plugins once, and never Learn them again.

### Included FX chains

Seven ready-made chains are provided in `FXChains/`, each pairing a mapped panel with its plugin:

| Chain | Plugin | Panel |
| --- | --- | --- |
| StripBus SSL4000E | bx_console SSL 4000 E (Plugin Alliance) | 600 px |
| StripBus SSL4000G | bx_console SSL 4000 G (Plugin Alliance) | 600 px |
| StripBus SSL9000J | bx_console SSL 9000 J (Plugin Alliance) | 600 px |
| StripBus BX Glue | bx_glue (Plugin Alliance) | 400 px |
| StripBus TownHouse Bus | bx_townhouse Buss Compressor (Plugin Alliance) | 300 px |
| StripBus Vertigo VSC-2 | Vertigo VSC-2 (Plugin Alliance) | 300 px |
| StripBus Pro-C3 | Pro-C 3 (FabFilter) | 300 px |

They expect the panels to be installed in `Effects/StripBus/` and the corresponding plugin to be present; the links rebuild themselves on load.



## 8. One preset bank for all panel sizes

The seven panel modules (050 / 100 / 150 / 200 / 300 / 400 / 600 px) only differ by their fixed height — same 50 sliders, same saved state, same engine. Their presets are therefore fully interchangeable, but REAPER files user presets by plugin, and it sees seven different plugins.

`StripBus System.lua` closes that gap: every two seconds it compares the seven preset files REAPER keeps in `<REAPER resource path>/presets/`, and propagates any change to the other six.

*   Save a preset from the 300 px panel → it appears in the preset list of all sizes.
*   Rename or delete a preset from any size → the change applies everywhere.
*   A size you have never used yet gets the whole bank the first time the script runs.
*   Reopen the FX window (or the preset menu) if a brand new preset is not listed yet — REAPER re-reads the file when it changes, but a menu already on screen won't refresh by itself.

Two things stay outside of this: the per-module default preset (*Save preset as default*, which REAPER stores elsewhere), and preset names — a name identifies a preset in the shared bank, so if two sizes happened to hold different presets under the exact same name, only one of them survives the first merge.



## 9. Limits & good to know

*   50 elements per panel, 1 to 4 grid columns, positions on a 1/8-cell grid.
*   Scroll groups: Independent plus A, B, C, D.
*   Only one clipboard, shared by all panels of the session (**Copy / Paste layout & links**).
*   **Clear all** and **Delete** are not undoable.
*   The panel follows REAPER's HiDPI scaling automatically.
*   Older layouts are migrated to the current grid on load; saved presets and templates from previous versions keep working.

---

**License** — StripBus is freeware. You may use and modify it for your personal workflow. Selling, commercially repackaging or redistributing it for profit — this version or any derivative — is prohibited.


