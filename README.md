<img width="1280" height="405" alt="StripBus 1" src="https://github.com/user-attachments/assets/447a9eea-473a-464b-977f-8fdc74a6f7dd" />
# STRIPTEASE User Manual (BETA)

Welcome to the comprehensive guide for the StripTease system in REAPER. StripTease turns any REAPER track into a customizable console strip: knobs, switches and Gain Reduction meters that live directly in the mixer (MCP), drive your real plugins, and travel with your presets and track templates.

This document covers the package content, the setup, the exhaustive list of every menu option, every mouse and keyboard gesture, the Direct Link workflow, and the preset / recipe system.

Feel free to support this project! if you like and find StripTease useful, you can buy me a coffee here:

https://ko-fi.com/ericire58504

Have fun !
Eric



**License & Copyright** 

StripTease is freeware. You may use it for your personal workflow. Selling, commercially repackaging or redistributing it for profit — this version or any derivative — is prohibited.





## 1. What's in the package

| File | Role |
| --- | --- |
| `StripTease Panel 050 / 100 / 150 / 200 / 300 / 400 / 600 px` | The seven JSFX panels. Identical engine, only the fixed height changes. |
| `striptease_panel.jsfx-inc` | The shared engine imported by all seven panels. Not loaded directly. |
| `StripTease.jsfx` (*StripTease GR*) | Audio JSFX that **measures** Gain Reduction for compressors that don't report it to REAPER. |
| `StripTease System.lua` | Background script. Required for Gain Reduction, Direct Link, renaming, custom colors and preset sharing. |
| `StripTease Check.lua` | Diagnostic script: tells you which plugins report their Gain Reduction natively. |
| `FXChains/*.RfxChain` | Seven ready-made FX chains (panel + plugin, already mapped). |

### Installation

**Method 1: Using ReaPack (Recommended)**
The easiest way to install and keep StripTease up to date is via ReaPack.
1. In REAPER, go to **Extensions > ReaPack > Import a repository**.
2. Paste the following URL: `https://raw.githubusercontent.com/ericdevcire/StripTease/main/index.xml`
3. Go to **Extensions > ReaPack > Browse packages**, search for `StripTease`, right-click on it and select **Install**.
4. Click **Apply** in the bottom right corner.
5. In the mixer, enable **Show embedded UI in MCP** on the panel's FX slot so the StripTease interface is visible in your mixer strip.

**Method 2: Manual Installation**
*   Copy the panels, `striptease_panel.jsfx-inc` and `StripTease.jsfx` into `<REAPER resource path>/Effects/StripTease/` (the provided FX chains expect exactly this folder name).
*   Put the two `.lua` scripts anywhere REAPER can reach them — `<REAPER resource path>/Scripts/`, or simply next to the JSFX in `Effects/StripTease/` — and add them via *Actions > Show action list > New action > Load ReaScript*.
*   Copy the `.RfxChain` files into `<REAPER resource path>/FXChains/` if you want the ready-made chains.
*   In the mixer, enable **Show embedded UI in MCP** on the panel's FX slot.

### StripTease System.lua

Run it once; it stays in the background and handles everything the JSFX cannot do by itself:

*   Finds every compressor or gate on your tracks that reports its gain reduction — to REAPER through `GainReduction_dB`, or through a parameter named after it — and feeds the GR meters.
*   Maintains the **Direct Links** between panel elements and real plugin parameters (both directions).
*   Rebuilds links from **recipes** when a preset, track template or FX chain is loaded.
*   Serves the **Rename** dialog, the **Palette** color picker, and the value pop-up shown when you hover or tweak a linked control.
*   Keeps the preset banks of the seven panel sizes identical (see section 8).

With SWS installed you can attach it to the *Global Startup Action* so it launches with REAPER.

> Several features are simply inactive while the script is not running: renaming, custom palette colors, GR metering, learning, direct links and value pop-ups. If a menu entry seems to do nothing, check the script first.

### StripTease Check.lua

If a compressor's Gain Reduction doesn't show up on a meter, run this script while the project is playing. It lists all plugins on the track and tells you whether each one reports its Gain Reduction natively. If it doesn't, use the *StripTease GR* JSFX described in section 6.

### Panels

Pick the panel height that suits your mixer in the FX browser. Whatever size you choose you can add up to **50 elements**; the panel scrolls when the content is taller than the module. If a layout ends up cramped you have three ways out: split it over **tabs** (section 3.7), widen the grid to more columns, or use **Copy layout & links** to paste the whole thing into a taller panel — layout, links and recipe come along.

**Presets are shared by all seven panel sizes.** REAPER stores user presets per plugin, and each panel height is a separate plugin to REAPER — so, left alone, a preset saved on the 300 px module would only ever show up on the 300 px module. `StripTease System.lua` keeps the seven preset banks identical, so any preset you save from any size is immediately available from every other size. Nothing to export or import; the only requirement is that the script is running when you save the preset. Renaming or deleting a preset applies to all sizes too. See section 8.



## 2. The elements

| Element | What it does |
| --- | --- |
| **Knob** | Rotary control, 0–127. Sends a MIDI CC and/or drives a linked plugin parameter. |
| **Toggle** | On/off switch (0 / 127), with an optional separate label for the ON state. |
| **Radio** | Multi-position selector, 2 to 6 steps, horizontal or vertical. |
| **GR meter** | Needle VU showing **gain reduction or a level** (one at a time), with a calibration screw. |
| **GR bar** | Bar-graph gain reduction meter, horizontal or vertical. |
| **Separator** | Horizontal line to group controls. |
| **Title** | Standalone text label. |

New knobs, toggles and radios are automatically assigned the first free CC number and named after it (`CC 12`); changing the CC of a still-auto-named element renames it accordingly. As soon as you rename it manually, the name stops following the CC.

> **Put the panel above the plugins it drives by CC.** MIDI emitted by a JSFX only travels *down* the FX chain, so a plugin sitting **before** the panel never receives its CC. The symptom is a half-working control: the knob still follows the plugin (the feedback path goes through the script, not through MIDI), but moving the knob no longer does anything. Move the panel to the top of the chain, or move the plugin below it. **Direct Link is not affected** — it drives the plugin through the REAPER API, so it works from any position.

Separators, titles and meters are inert during playback: clicks pass through them, so they never get in the way of a nearby knob. They only become grabbable in **Edit mode**.



## 3. Menu reference

Right-click anywhere in a panel. Clicking on an element opens that element's menu; clicking on the background opens the panel menu; clicking a tab opens the tab menu. Menus adapt to the element type — the lists below are exhaustive.

Every element menu, whatever the type, ends with the same block — **Edit mode**, then **Copy element** (or **Copy selection (N)**), **Paste (N)**, **Select**, then **Duplicate**, **Delete** — preceded by **Tab: ...** when tabs are on. The copy entries are described in section 3.8.

### 3.1 Background menu

**Adding elements** (the new element lands where you right-clicked, if the cell is free — and on the page currently open, when tabs are on)

*   **Add knob**
*   **Add toggle**
*   **Add radio**
*   **Add GR meter** — lands centred on the panel, whatever else it contains.
*   **Add GR bar... > Horizontal / Vertical**
*   **Add separator**
*   **Add title**

**Display & layout**

*   **Edit mode** — Enables moving and resizing elements by dragging: drag to move, **Shift + drag up to grow, down to shrink**. A yellow `EDIT` label and the alignment grid are shown while active. Also where multiple selection lives (section 3.8).
*   **Show names** — Globally shows/hides the labels under the controls.
*   **Show knob rings** — Globally shows/hides the colored value ring around knobs.
*   **Scroll group: ...** — *Independent*, *Group A*, *B*, *C*, *D*. Panels in the same group scroll together, which is invaluable when you have many tracks: scroll one strip and the whole group follows. When tabs are on, the group also turns its pages together (section 3.7).
*   **Color...** — Background color of the panel: **Palette...** (custom color picker) plus White, Light gray, Gray, Dark gray, Dark, Green, Red, Blue, Yellow, Orange, Pink.
*   **Grid: N columns...** — 1 to 4 columns. Changing it re-flows the existing layout.
*   **Fit grid to elements** — Re-sizes the grid cell to the largest element on the panel, so nothing overlaps any more. The grid does *not* follow element sizes on its own (see below); this is the one entry that makes it catch up. Positions are unchanged — they are stored as fractions of a cell, so the layout keeps its shape and only its spacing changes.
*   **Tabs...** — *Off*, *2 pages*, *3 pages*, *4 pages*. Splits the panel into pages, selected by a row of buttons across the top. See section 3.7.

**Clipboard**

*   **Copy layout & links** — Copies the whole panel (elements, names, colors, grid columns and cell size, tabs and their names, links and the preset recipe) to a global clipboard shared by every StripTease panel.
*   **Paste layout & links** — Pastes it into the current panel. Greyed out when the clipboard is empty.
*   **Copy selection (N)** — Copies the selected elements to the element clipboard, separate from the layout one. Greyed out when nothing is selected. See section 3.8.
*   **Paste elements (N)** — Pastes them, top-left corner of the batch landing on the cell you right-clicked. Greyed out when the element clipboard is empty.
*   **Clear selection** — Deselects everything.

**Preset links** (see section 7)

*   **Preset links: N on \<plugin\>** — Status line: how many links the current recipe holds and for which plugin. Reads *none yet* or *forgotten* when there is no recipe.
*   **Capture links now** — Forces the panel to read the track and build the recipe immediately. Greyed out when there is nothing to capture.
*   **Forget preset links** — Clears the recipe so the links won't travel with the preset.

**Reset**

*   **Reset All Positions** — Sends every knob, toggle and radio back to its default value (0, 64 for bipolar, 127 for *Init at max*), and resets the trim of every meter to 0.
*   **Resend all CCs** — Re-broadcasts every current value, to resync a plugin that lost state.
*   **Clear all** — Deletes every element on the panel. **Cannot be undone.**

### 3.2 Knob / toggle / radio menu

*   **Rename  (current name)...** — Opens a text dialog (needs `StripTease System.lua` running).
*   **Rename (ON)  (current name)...** — *Toggles only.* Label displayed while the toggle is engaged.
*   **CC number  (CC n)...** — MIDI CC 0 to 127, presented in eight submenus of sixteen.
*   **MIDI channel  (ch n)...** — *All channels* or channel 1 to 16.
*   **Color...** — **Palette...** (custom color) plus the eleven presets listed above.
*   **Size...** — Tiny, Small, Medium, Large, Very large, Huge. In Edit mode, **Shift + drag up/down** sizes by hand, between and beyond these presets (section 4).
*   **Positions  (n)...** — *Radios only.* 2 to 6 steps.
*   **Vertical** — *Radios only.* Switches the row of buttons to a column, counted **from the bottom up**: the first position sits at the bottom and the values climb, the way a rotary selector or a fader reads.
*   **Momentary** — *Toggles only.* The switch stays ON only while the mouse button is held.
*   **Bipolar** — *Knobs only.* Default/reset value becomes 64 and the ring fills from the center — for pan, EQ gain, etc.
*   **Init at max** — *Knobs only.* Default/reset value becomes 127.
*   **Learn plugin parameter...** — Starts the Direct Link listening mode (section 5).
*   **Re-learn plugin parameter...** / **Clear plugin link** — Shown instead, once the element is linked.
*   **Tab: (name)...** — *Tabs on only.* Moves the element to another page.
*   **Edit mode**, **Duplicate**, **Delete** — Duplicate copies size, color, flags, page, name and, for a toggle, its ON name; the copy gets its own free CC.

### 3.3 GR meter menu

*   **Rename  (name)...**
*   **Measure  (Gain reduction)...** — What the needle shows, one at a time:
    *   **Gain reduction** — dB of compression (default).
    *   **Input level** — level measured by the panel itself, at its own position in the FX chain. Put the panel at the top of the chain and it reads the strip's input.
    *   **Output level** — level leaving the FX chain, before the fader.

    Neither level mode needs anything installed on the track. The caption under the needle reads `COMPRESSION`, `INPUT` or `OUTPUT` accordingly, and the small **`GR` / `IN` / `OUT`** word at the bottom right of the meter, next to the trim screw, is clickable — it cycles through the three without opening the menu.
*   **Reference  (0 dBFS)...** — *Level modes only.* Which level the `0` of the dial stands for: **0 dBFS** (full scale, default), **−9**, **−12**, **−14**, **−18** or **−20 dBFS**. Pick −18 and a signal peaking at −18 dBFS parks the needle on 0, with the red zone starting there — the usual way to work with headroom on a channel strip. The numeric readout follows the same reference.
*   **Source  (Compressor n)...** — Which plugin on the track the meter reads: **Compressor 1**, **Compressor 2** or **Gate 1**, counted in FX-chain order. Only shown in *Gain reduction* mode — the level modes have a single measurement point and ignore it. When the script knows the track, sources with no matching plugin are flagged `-- none`. Gates are identified by keywords in the plugin name (*gate*, *expander*, *Pro-G*); a gate detected as a compressor is simply read as the corresponding Compressor number.
*   **Linear** / **Exponential** — Scale of the dial. In gain reduction mode: `0 4 8 12 16 20` or `0 2 4 6 10 20`. In level mode the dial reads dBFS over a 40 dB window: `-40 -32 -24 -16 -8 0` or `-40 -20 -10 -5 -2 0`. In both cases the needle rests on the left and swings right as the reading grows.
*   **Color...** — Palette + eleven presets.
*   **Size  (n px)...** — Tiny 90 px, Small 105 px, Medium 120 px, Large 150 px, Very large 180 px, Huge 210 px. In Edit mode, **Shift + drag up/down** sizes by hand (section 4).
*   **Show value** — Numeric dB readout under the needle: reduction in gain reduction mode, level in dBFS (negative) in level mode.
*   **Peak hold** — Holds the extreme reading for a moment — maximum reduction, or loudest peak.
*   **Tab: (name)...** — *Tabs on only.*
*   **Edit mode**, **Duplicate**, **Delete** — Duplicating a meter keeps its mode, its source and its trim.

### 3.4 GR bar menu

*   **Rename  (name)...**
*   **Source  (Compressor n)...** — Same list as the GR meter.
*   **Linear / Exponential** — Same two scales.
*   **Color...** — Palette + eleven presets.
*   **Size  (n px)...** — Tiny 36 px, Small 48 px, Medium 60 px, Large 72 px, Very large 96 px, Huge 120 px. In Edit mode, **Shift + drag up/down** sizes by hand (section 4).
*   **Vertical** — Flips the bar between horizontal and vertical.
*   **Peak hold**
*   **Tab: (name)...** — *Tabs on only.*
*   **Edit mode**, **Duplicate**, **Delete**

### 3.5 Title and separator menus

*   **Rename title  (text)...** — *Titles only.*
*   **Color...** — Palette + eleven presets.
*   **Tab: (name)...** — *Tabs on only.*
*   **Edit mode**, **Duplicate**, **Delete**

### 3.6 Palette (custom colors)

Every **Color...** submenu starts with **Palette...**, which opens the operating system color picker and assigns the exact RGB you choose — to a single element or to the panel background. StripTease adapts the contrast of labels and rings to the luminance of your color automatically. Take as long as you like in the picker: the panel waits until you close it.

This entry needs `StripTease System.lua` running, and the picker itself comes from the **SWS extension**. Without SWS, StripTease says so once and the entry does nothing — the eleven preset colors stay available. If the service is not running at all, the element flashes `NO ANSWER` after five seconds.

### 3.7 Tabs

A panel can spread its elements over 2 to 4 pages, so a long strip becomes a few short ones instead of one you have to scroll.

Turn them on from **Tabs...** in the background menu. A row of buttons appears across the top of the panel — click one to switch pages. Send an existing element to another page with **Tab: ...** in its own menu; anything you add lands on whichever page is open at the time.

**Tab menu** — right-click a tab:

*   **Rename tab  (name)...** — Free text, up to 12 characters. Needs `StripTease System.lua`, like every other rename.
*   **Reset tab name** — Back to the plain number. Greyed out when the tab has no name of its own.
*   **Tabs...** — The same submenu as in the background menu, so you can change the number of pages without leaving the row.

What to expect:

*   **Pages divide the display, not the wiring.** A control parked on a page you are not looking at keeps its value, keeps sending its CC, keeps its automation and keeps its Direct Link. Hiding it changes nothing but what you see — which is exactly what makes tabs safe for controls you have set once and don't want to touch again.
*   **Pages may overlap in the grid.** That is the whole point: page 2 can reuse the cells page 1 occupies. The consequence is that turning tabs off, or reducing the number of pages, brings everything back together and re-flows whatever now shares a cell. Positions move; nothing is lost, and no element ever becomes unreachable.
*   **Moving an element to a busy cell.** If the cell it sits on is already taken on the destination page, it lands on the first free cell there instead of stacking.
*   **Each page keeps its own scroll position.** Leave page 1 halfway down, go to page 2 and come back: you land where you left it. This is session state — reopen the project and each page starts at the top.
*   **Scroll groups turn the pages together.** Panels set to the same group (A, B, C, D) already scroll as one; they switch pages as one too. Click a tab on any of them and the whole group follows, at that page's remembered scroll position. A panel with fewer pages stops at its own last one without dragging the rest back, and a panel set to *Independent* is left alone. Note that **Group A is the default**, so several panels will move together until you set one to *Independent*.
*   **The row costs height.** About 34 px, taken off the scrolling area — worth weighing on the 050 and 100 px panels.

### 3.8 Selecting and copying elements

**Copy layout & links** replaces a whole panel. This one moves a handful of elements instead, and it goes wherever you want: another page, another panel, another track.

**Selecting** — In **Edit mode**, **Shift + click** an element to select it; a fixed blue ring marks it, the same outline the learn animation uses. Shift-click again to deselect. **Shift + drag** still resizes, as before: the gesture only counts as a selection if you release without moving (a few pixels of slack). **Select** in an element's menu does the same thing without the modifier, and switches Edit mode on so you can see the ring. The selection is not saved with the project, and leaving Edit mode clears it.

**Dropping the selection** — A plain click, no Shift, on the background or on an element that is *not* selected clears the whole selection: you are now working on that one element. Clicking an element that *is* part of the selection keeps it — that click is the start of a group move. **Clear selection** in the background menu does it from the menu.

**Moving a selection** — Drag any element of the selection and the whole batch follows the same offset, so the arrangement you built is preserved rather than rebuilt element by element. The step is all or nothing: if a single element of the batch would leave the grid or land on a cell held by an outsider, the whole step is refused. Cells held by the batch itself are not obstacles — they are vacated by the same move. Only the elements on the page currently open move; anything selected on another page stays where it is, since there is no comparable cell to move it to.

**Copying** — **Copy element** in an element menu takes that one element. When the element you right-click belongs to a selection of two or more, the entry reads **Copy selection (N)** and takes the whole batch. From the background menu, **Copy selection (N)** does the same. Each element travels with its name (and ON name), color, size, flags, CC channel, current value and Direct Link.

**Pasting** — **Paste** from an element menu drops the batch on the first free cells. **Paste elements** from the background menu puts the top-left corner of the batch on the cell you right-clicked and rebuilds the shape around it; any cell already taken sends that element to the first free one instead of stacking. The batch always lands on the page currently open, whichever page it was copied from, and the copies become the new selection.

What comes along, and what doesn't:

*   **CCs are kept when they are free.** A copy pasted into a panel that already uses that CC gets the first free one instead — otherwise the two controls would move together. An automatic `CC nn` name follows the new number; a name you typed is left alone.
*   **Direct Links only survive where they mean something.** They are rebuilt if the destination panel already targets the same plugin, or if it targets none yet — in which case it adopts the plugin of the batch. Paste into a panel wired to a different plugin and the elements arrive unlinked rather than pointing at the wrong parameters. Links rebuild through the recipe, so `StripTease System.lua` has to be running (section 7).
*   **The clipboard is global and it persists.** It is shared by every StripTease panel in the REAPER session, holds one batch at a time, and survives closing the panel you copied from.
*   **A full panel takes what it can.** Pasting into a panel with fewer free slots than the batch fills the slots available and drops the rest.



## 4. Mouse & keyboard

### Normal mode (playing)

| Gesture | Result |
| --- | --- |
| Drag up/down on a knob | Change the value |
| **Ctrl** + drag on a knob | Fine adjustment (≈ 3× slower) |
| Double-click a knob | Reset to its default (0, or 64 bipolar, or 127 *Init at max*) |
| Wheel over a knob, when the panel cannot scroll | ±1 step, or ±1 detent on a knob linked to a stepped parameter |
| **Ctrl** + wheel over a knob | Same, even when the panel scrolls |
| **Ctrl + Shift** + wheel over a knob | ±5 steps, or ±5 detents |
| Click a toggle | Flip it — or hold it, if *Momentary* is on |
| Click / drag on a radio | Select the position under the mouse |
| Drag the VU calibration screw | Trim the meter, −6 to +6 dB in 0.5 dB steps (the reading shows `TRIM +x.x`) |
| Double-click the VU screw | Reset the trim to 0 |
| Click the VU `GR` / `IN` / `OUT` label | Cycle the measurement — gain reduction, input level, output level |
| Wheel over the panel | Scroll the panel |
| **Shift** + wheel | Scroll faster |
| Drag the background, or the right-edge scrollbar | Scroll the panel |
| Hover or tweak a linked control | Pop-up with the real value read from the target plugin |
| Click a tab | Switch page |
| Right-click a tab | Rename it, or change the number of pages |
| Right-click | Contextual menu |

A click slightly off a control still grabs the nearest one, so small knobs stay easy to catch in a dense strip.

### Edit mode

| Gesture | Result |
| --- | --- |
| Drag an element | Move it. Position snaps to a 1/8-cell grid, so elements can be tucked between columns and rows. With tabs on, an element only moves within its own page — use **Tab: ...** to send it elsewhere. Drag an element that belongs to a selection and the whole selection follows (section 3.8). |
| Click an element, or the background | Clears the selection, unless you clicked an element that is part of it (section 3.8). |
| **Shift** + drag **up** | **Makes the element bigger.** |
| **Shift** + drag **down** | **Makes it smaller.** |
| **Shift** + click | Select / deselect the element for a batch copy — a blue ring marks it (section 3.8). The gesture is only read as a selection if you release without moving; move first and it is a resize. |
| Right-click | Same menus as usual |

**Resizing by hand.** Hold **Shift** and drag vertically: up grows, down shrinks. It is continuous, so it goes anywhere between and beyond the *Size...* presets, over a range of 5 to 64 — a few pixels of travel per step, the exact figure depending on the display scaling. The size means whatever the type calls size: knob diameter, toggle width, radio cell, VU or bar length. **Separators are the exception** — they have nothing to size, so Shift + drag just moves them like a plain drag. Nothing marks the element while you resize; watch the element itself, and use the *Size...* menu if you want a known value back.

**Resizing never moves anything else.** The grid cell has its own size, and it does not follow the elements: growing a knob past its cell simply makes it overlap its neighbours, and everything around it stays exactly where you put it. Move the element afterwards if the overlap bothers you, or run **Fit grid to elements** (background menu) to open the grid back up around the largest element — that one does re-space the whole panel, which is why it is a deliberate choice rather than something that happens under your hand.

The grid cell is set when the panel is created, saved with it, and carried along by **Copy layout & links**. Panels made before this behaviour existed keep the spacing they had: their grid is measured from their content the first time they load, then frozen.

The alignment grid drawn in edit mode marks eighths, quarters and whole cells with increasing brightness. Layouts made with older versions are converted automatically to the finer grid the first time they load.



## 5. Parameter Linking (Direct Link)

StripTease offers a Direct Link system that completely bypasses REAPER's native MIDI CC or Parameter Modulation limits. The panel controls the plugin, and if you move the plugin's GUI the panel updates instantly (bidirectional sync).

Once a parameter is mapped, the source value is displayed in a small pop-up when you hover or tweak the control, so you read the actual data from the targeted plugin.

**The method to link correctly:**

1. Ensure the background script (`StripTease System.lua`) is running.
2. In the StripTease panel, right-click the knob, toggle or radio you want to link.
3. Select **Learn plugin parameter...**. The element starts flashing to indicate it is listening.
4. Open the FX window of the plugin you want to control (it must be on the same track).
5. Move the parameter you want to link (click and drag it slightly with your mouse).
6. The element stops flashing and displays a success message. The link is now active in both directions.

Learning times out after about 20 seconds, and any click in the panel cancels it. To remove a link, right-click the element and select **Clear plugin link**; to point it somewhere else, use **Re-learn plugin parameter...**.

Direct Link applies to knobs, toggles and radios. Meters are fed by the GR system instead (section 6). Plugins inside FX containers are supported.

**Stepped parameters.** When the target parameter moves in steps rather than continuously — a filter slope, an oversampling factor, a mode switch — the linked knob adopts exactly those steps. It detents to the same positions the plugin has, the wheel advances a whole step per notch instead of a fraction too small to change anything, and the value under the pointer is the one the plugin actually kept. Nothing to set up: the panel picks the step count up from the target as soon as the link exists, and goes back to a continuous sweep if you clear it. Parameters with more than about 500 steps are treated as continuous, where a detent would be too fine to feel anyway.



## 6. Metering — gain reduction and levels

A needle meter can show three things, chosen with *Measure...* in its right-click menu: the **gain reduction** of a source, the **input level**, or the **output level**. GR bars always show gain reduction.

For gain reduction, the meter reads a single value per source: **Compressor 1**, **Compressor 2** or **Gate 1**, counted in FX-chain order on the same track as the panel.

### Gain reduction

**Three ways to get that value. All three are automatic — there is nothing to map:**

1. **Natively** — Many plugins report `GainReduction_dB` to REAPER. `StripTease System.lua` picks these up automatically; nothing else to do. Run `StripTease Check.lua` while playing to see which of your plugins qualify.

2. **Through a parameter named after the reduction** — `GainReduction_dB` is only served by the VST hosting side of REAPER: by REAPER's own VST2 extension, and by the VST3 `IGainReductionInfo` interface. **A JSFX never answers it.** A JSFX that sets `ext_gr_meter` does feed REAPER's own track meter — you can watch the reduction move next to the fader — but that path is internal to REAPER's JSFX module and has no script side at all. What REAPER shows there, it lends to no one.

   The one channel a JSFX does share with a script is a parameter. So StripTease also accepts, on a plugin that answers nothing, **a parameter whose name contains *gain reduction*, *GR readout* or *GR meter*, and whose range is graduated in dB** (more than one unit wide). Both conditions together: a control that happens to carry such a name is rarely graduated in dB, and a normalized 0..1 parameter cannot be a dB readout anyway.

   Nothing to set up — the plugin is picked up as *Compressor n* like any other, and `StripTease Check.lua` marks it `[via parameter: ...]`. The value is taken in absolute value, so it makes no difference whether the plugin counts its reduction downwards (−6) or upwards (6); readings beyond 60 dB are clamped. If you write your own JSFX, exposing one such parameter alongside `ext_gr_meter` is all it takes.

3. **With the *StripTease GR* JSFX** — For compressors that report nothing and expose nothing, StripTease measures the reduction itself by comparing the signal before and after the plugin:
   *   Insert one instance of **StripTease GR** *above* the compressor, set **Measurement point** to `In - above the compressor`.
   *   Insert a second instance *below* the compressor, set **Measurement point** to `Out - below the compressor`.
   *   Set **Compressor (number on this track)** to the same number on both, and point your GR meter at that same *Compressor n*. The slider still goes up to 4, but the meter only offers 1 and 2 — stay on those.
   *   Pick a number that is **not already used by a compressor reporting natively** on that track. `StripTease Check.lua` lists them as *Compressor 1*, *Compressor 2*… — if you land on one of those, the native reading wins and StripTease GR steps aside silently.
   *   **Makeup** — `Auto` tracks the plugin's makeup gain by itself (recommended); `Manual` lets you enter the exact **Manual makeup (dB)** you dialed in the compressor, from 0 to 24 dB.

### Levels

The two level modes watch the audio instead of the compression, and **neither needs anything added to the track**. They differ only by where the measurement is taken:

| Mode | Measured at | How |
| --- | --- | --- |
| **Input level** | The panel's own slot in the FX chain | The panel measures the audio flowing through it |
| **Output level** | End of the FX chain, before the fader | `StripTease System.lua` reads the track meter and undoes the fader |

A plugin only ever sees the audio at *its own* position, which is what makes *Input level* positional: put the panel at the top of the FX chain and it reads what enters the strip; move it below a plugin and it reads that plugin's output. *Output level* is the opposite — it always reads the end of the chain, wherever the panel sits.

**About the pre-fader reading.** REAPER's track meter is post-fader, so the script divides it by the track's volume before publishing: moving the fader no longer moves the needle, and what you read is the level leaving your FX chain. Three things to know:

*   A **muted track**, or a fader pulled to −∞, kills the meter REAPER feeds us — there is nothing left to compensate. The mode then reports no data (needle left, orange dot) rather than a misleading −inf.
*   Panning does not disturb it: REAPER's balance attenuates the opposite channel, and the meter takes the loudest of the two.
*   If you have turned on **Options > Pre-fader track metering**, REAPER is already giving a pre-fader value and the compensation works against you — turn that option off, or use **Input level** with the panel last in the chain, which measures the same point exactly and ignores every REAPER setting.

### Reading a level

The dial spans **23 dB, from −20 on the left up to +3 on the right**, relative to whatever *Reference* you picked (0 dBFS out of the box), so the needle swings right as the signal gets louder, exactly like the gain reduction scale grows to the right. The last fifth of the dial — from **0 to +3 dB** — is drawn in red, graduations and figures included, so an over is unmistakable. Readings are peak values with a 30 ms release; the numeric readout keeps showing the true level even when the needle is pinned at +3.

When nothing is publishing, the needle sits at the far left, the readout shows `-inf dB` and the small orange dot lights up in the corner. That dot means *no data at all* — the script not running, the track muted, or the FX chain not processing. Real silence gives you the same needle position and `-inf dB`, but **no dot**.

### Reading and adjusting the meter

*   **Scale** — Gain reduction: *Linear* (0 4 8 12 16 20) or *Exponential* (0 2 4 6 10 20), the latter giving more resolution in the first few dB. Levels: *Linear* (−20 −15 −10 −5 0 +3) or *Exponential* (−20 −10 −5 −2 0 +3), the latter giving more resolution near full scale. Both end on the red 0 → +3 zone.
*   **Reference** — In level mode the dial is calibrated in dBFS by default (0 = full scale). *Reference...* moves that 0 down to −9, −12, −14, −18 or −20 dBFS, so the meter reads your working headroom instead of the distance to clipping. It shifts the dial, the readout and the red zone together.
*   **Trim** — Drag the screw at the bottom of the needle meter to offset the reading by up to ±6 dB. On a GR meter this matches the calibration of a plugin's own meter; on a level meter it fine-tunes on top of the reference. Double-click the screw to zero it.
*   **The GR / IN / OUT switch** — The little `GR`, `IN` or `OUT` word printed at the bottom right of the meter, next to the screw, is clickable: one click cycles the measurement, so you can flip a strip's meter between compression and levels while listening, without going through the right-click menu. It is hidden on meters too small to print it legibly.
*   **Show value** displays the numeric dB — the reduction, or the level in dBFS (`-inf` below −90). **Peak hold** freezes the maximum reduction, or the loudest peak, for a moment.
*   Both modes share the same ballistics: instant rise toward the higher reading, smooth release.



## 7. Presets, recipes and plugin mapping

A direct link uses a unique ID (GUID) tied to the specific instance of the plugin on your track. Normally that would mean the link breaks whenever the track is duplicated or a template is loaded. StripTease solves this with **recipes**.

**How recipes work:** when you link a parameter, StripTease remembers the exact instance *and* writes a relative recipe into the JSFX state — the **name of the target plugin** and the **parameter number** for each element. On load, `StripTease System.lua` looks for a plugin with that exact name on the new track and rebuilds every link for the new instance.

> The name used is the plugin's **original** name, so renaming an FX instance in the chain (*Rename FX instance*) does not break the recipe. Recipes captured with an older StripTease still resolve on the name they were stored with; capture them again to store the original one.

**One recipe describes one plugin.** An element learned on a *different* plugin still works (its link is intact), but it does not join the recipe — so it will not travel with the preset. This matters when you derive one preset from another: load "SSL 4000 E", re-learn everything onto an SSL 4000 G, and each re-learn removes that element from the 4000 E recipe. The panel then adopts the 4000 G automatically (within two seconds of the recipe becoming empty), but **the preset you saved before that point carries no links at all** — check the background menu, it must read `Preset links: N on <your plugin>` and not `none yet`, then save the preset again.

**How to create reusable mappings:**

1. Add a plugin (e.g. an EQ or a compressor) to your track.
2. Add a StripTease Panel JSFX.
3. Use the Learn method (section 5) to map all the controls you need.
4. Check that the background menu reads `Preset links: N on <plugin>`.
5. Save it — as a JSFX preset, an FX chain, or a track template.

Loading it on any other track rebuilds all the bidirectional links automatically. Map your favorite plugins once, and never Learn them again.

### Included FX chains

Nine ready-made chains are provided in `FXChains/`, each pairing a mapped panel with a specific plugin. 

> [!NOTE]
> These chains are pre-linked with plugins I use regularly in my own workflow. Even if you don't own these exact plugins, you still get the huge benefit of a fully constructed, ready-to-use panel layout. You can simply load the chain, insert your own preferred plugin, and use the *Learn plugin parameter* function to re-link the existing knobs to your plugin of choice.

| Chain | Plugin | Panel |
| --- | --- | --- |
| StripTease SSL4000E | bx_console SSL 4000 E (Plugin Alliance) | 600 px |
| StripTease SSL4000G | bx_console SSL 4000 G (Plugin Alliance) | 600 px |
| StripTease SSL9000J | bx_console SSL 9000 J (Plugin Alliance) | 600 px |
| StripTease BX Glue | bx_glue (Plugin Alliance) | 400 px |
| StripTease TownHouse Bus | bx_townhouse Buss Compressor (Plugin Alliance) | 300 px |
| StripTease Vertigo VSC-2 | Vertigo VSC-2 (Plugin Alliance) | 300 px |
| StripTease Pro-C3 | Pro-C 3 (FabFilter) | 300 px |
| StripTease UAD 610A Pramp | UADx 610-A Preamp and EQ (Universal Audio) | 200 px |
| StripTease UAD 610B Pramp | UADx 610-B Preamp and EQ (Universal Audio) | 200 px |

They expect the panels to be installed in `Effects/StripTease/` and the corresponding plugin to be present; the links rebuild themselves on load.



## 8. One preset bank for all panel sizes

The seven panel modules (050 / 100 / 150 / 200 / 300 / 400 / 600 px) only differ by their fixed height — same 50 sliders, same saved state, same engine. Their presets are therefore fully interchangeable, but REAPER files user presets by plugin, and it sees seven different plugins.

`StripTease System.lua` closes that gap: every two seconds it compares the seven preset files REAPER keeps in `<REAPER resource path>/presets/`, and propagates any change to the other six.

*   Save a preset from the 300 px panel → it appears in the preset list of all sizes.
*   Rename or delete a preset from any size → the change applies everywhere.
*   A size you have never used yet gets the whole bank the first time the script runs.
*   Reopen the FX window (or the preset menu) if a brand new preset is not listed yet — REAPER re-reads the file when it changes, but a menu already on screen won't refresh by itself.

Two things stay outside of this: the per-module default preset (*Save preset as default*, which REAPER stores elsewhere), and preset names — a name identifies a preset in the shared bank, so if two sizes happened to hold different presets under the exact same name, only one of them survives the first merge.



## 9. Limits & good to know

*   **CC control only reaches plugins placed below the panel in the FX chain** — MIDI from a JSFX travels downstream only. A knob mapped to a plugin above the panel keeps displaying that plugin's value but stops driving it. Direct Link has no such constraint (see section 2).
*   50 elements per panel, 1 to 4 grid columns, up to 4 pages, positions on a 1/8-cell grid.
*   Scroll groups: Independent plus A, B, C, D.
*   Only one clipboard, shared by all panels of the session (**Copy / Paste layout & links**).
*   **Clear all** and **Delete** are not undoable.
*   The panel follows REAPER's HiDPI scaling automatically.
*   **The 50 native sliders are never drawn** — a panel shows its own interface and nothing else. They remain full parameters: automation, envelopes, parameter modulation, presets and Direct Link all work exactly as before; only REAPER's generic slider rows are gone.
*   The tab row costs about 34 px of height, taken off the scrolling area — worth weighing on the 050 and 100 px panels.
*   Per-page scroll positions are session state: they are not saved with the project, so each page starts at the top when you reopen it. The page you were *on* is saved.
*   Older layouts are migrated to the current grid on load; saved presets and templates from previous versions keep working. A panel saved before tabs existed opens with tabs off and everything on one page, as it was.

---




