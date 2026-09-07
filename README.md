# STRIPTEASE User Manual

**Version 1.2.1** — see the [changelog](Changelog.md) for what changed.

Welcome to the comprehensive guide for the StripTease system in REAPER. StripTease turns any REAPER track into a customizable console strip: knobs, switches and Gain Reduction meters that live directly in the mixer (MCP), drive your real plugins, and travel with your presets and track templates.   
StripTease is vibe-coded.

This document covers the package content, the setup, the exhaustive list of every menu option, every mouse and keyboard gesture, the Direct Link workflow, and the preset / recipe system.


**SUPPORT ME**  
Feel free to help this project! if you like and find StripTease useful, you can **buy me a coffee here** :  
[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/D3W024KM4J)


**COCKOS REAPER FORUM POST** :  
https://forum.cockos.com/showthread.php?t=310626&highlight=striptease&fbclid=IwY2xjawTryxBwZG9mAWV4dG4DYWVtAjEwAHNydGMGYXBwX2lkEDIyMjAzOTE3ODgyMDA4OTIAAR6op_o8YQiXT-lFyRgNNMgFd8T6A1iqtEKn-45UPtacWuSZo4Xy6UhX2-zwDA_aem_YJVd9nq1PuZD8PUeIRiZ_A

  
  
*A good mix should always end naked.*
  
Have fun !

Eric



<img width="1280" height="405" alt="StripBus 1" src="https://github.com/user-attachments/assets/447a9eea-473a-464b-977f-8fdc74a6f7dd" />
  
  
  
**LICENSE & COPYRIGHT** 

StripTease is freeware. You may use it for your personal workflow. Selling, commercially repackaging or redistributing it for profit — this version or any derivative — is prohibited.

## Credits

**Gain-reduction estimation — StripLink inspiration (RobKor / Wormhole Labs) on earlier versions.**  
In earlier versions of StripTease (up to v1.2.0), the concept of estimating gain reduction by comparing levels on either side of a silent plugin was borrowed from the **StripLink Aggregator** by **RobKor** (Wormhole Labs). Check out his STRIPLINK project here: https://forum.cockos.com/showthread.php?t=309941&highlight=striplink  

Starting with **v1.2.1**, the Gain Reduction measurement engine has been completely redesigned and rebuilt from the ground up with a custom audio-rate JSFX DSP core (sub-chunk RMS energy ratio, 2D level/gain histogram linear regression for rest gain, 700 Hz dual-band split spectral validation, PDC latency alignment, and dry/wet mix inversion), fully replacing the earlier implementation. 
  
  
## 1. What's in the package

| File | Role |
| --- | --- |
| `StripTease Panel 050 / 100 / 150 / 200 / 300 / 400 / 600 px` | Seven JSFX panel modules. Identical features; only the vertical height differs. |
| `striptease_panel.jsfx-inc` | Shared engine imported by all panels. Do not load directly. |
| `StripTease.jsfx` (*StripTease GR*) | Passive GR monitor. Mirrors `gmem` reduction values to REAPER's track meter (`ext_gr_meter`). |
| `StripTease System.lua` | Background service. Required for Gain Reduction, Direct Link, renaming, custom palettes, and preset sharing. |
| `StripTease Check.lua` | Diagnostic tool: inspects plugin GR routing (native, parameter, measured) and manual overrides. |
| `StripTease Panel Builder.lua` | Automatically builds a mapped panel from a plugin's parameters. Requires **ReaImGui**. |
| `StripTease Install FX chains.lua` | Copies bundled FX chains to your REAPER `FXChains/` folder. |
| `FXChains/*.RfxChain` | Twelve pre-mapped chains (panel + plugin), including container-routed examples. |

### Installation

**Method 1: ReaPack (Recommended)**
1. In REAPER: **Extensions > ReaPack > Import a repository**.
2. URL: `https://raw.githubusercontent.com/ericdevcire/StripTease/main/index.xml`
3. **Extensions > ReaPack > Browse packages**, install **StripTease**, and click **Apply**.
4. Right-click the panel FX slot in the mixer and check **Show embedded UI in MCP**.

**Method 2: Manual Installation**
1. Copy the panels, `striptease_panel.jsfx-inc`, and `StripTease.jsfx` into `<REAPER resource path>/Effects/StripTease/` (the provided FX chains expect exactly this folder name).
2. Put the `.lua` scripts anywhere REAPER can reach them — `<REAPER resource path>/Scripts/`, or simply next to the JSFX in `Effects/StripTease/` — and register them via *Actions > Show action list > New action > Load ReaScript*.
3. Copy the `.RfxChain` files into `<REAPER resource path>/FXChains/` if you want the ready-made chains.
4. In the mixer, enable **Show embedded UI in MCP** on the panel's FX slot.

### StripTease System.lua

Run it once; it stays in the background and handles everything the JSFX cannot do by itself:

*   Finds every compressor or gate on your tracks that reports its gain reduction — to REAPER through `GainReduction_dB`, or through a parameter named after it, or through one it learned to read — and feeds the GR meters. For a compressor that reports nothing, it tells the panel to measure the reduction itself when the chain allows it.
*   Maintains the **Direct Links** between panel elements and real plugin parameters (both directions).
*   Rebuilds links from **recipes** when a preset, track template or FX chain is loaded.
*   Serves the **Rename** dialog, the **Palette** color picker, and the value pop-up shown when you hover or tweak a linked control.
*   Keeps the preset banks of the seven panel sizes identical.

With SWS installed you can attach it to the *Global Startup Action* so it launches with REAPER.

> Several features are simply inactive while the script is not running: renaming, custom palette colors, GR metering, learning, direct links and value pop-ups. If a menu entry seems to do nothing, check the script first.

### StripTease Check.lua

Run it during playback to diagnose why a meter is inactive. It lists all plugins on the track and tells you how each one's Gain Reduction is read — reported natively, read through a parameter, or measured by the panel — and, for a plugin that reports nothing, why the panel cannot stand in for it. When the panel does measure, it also says whether that happens at the audio rate through a container or through the slower track-meter fallback.

### StripTease Panel Builder.lua

Builds a panel for you instead of laying it out by hand. Select a track, run the script, pick a plugin from the chain: it lists every parameter the plugin declares, you tick the ones you want, and it drops a finished panel on the track — elements typed after what each parameter really is, placed, named, coloured, and already linked to the plugin. Not a single *Learn plugin parameter* to run.

A radio button is laid down only where the source control genuinely enumerates its positions; a knob with detents stays a knob. The links are written straight into the panel's serialized state, so `StripTease System.lua` picks them up like any other Direct Link.

> It needs the **ReaImGui** extension for its window (*Extensions > ReaPack > Browse packages*, search for `ReaImGui`). Without it the script says so and stops, rather than failing silently.

### Panels

Pick the panel height that suits your mixer in the FX browser. Whatever size you choose you can add up to **100 elements**; the panel scrolls when the content is taller than the module. If a layout ends up cramped you have three ways out: split it over **tabs**, widen the grid to more columns, or use **Copy layout & links** to paste the whole thing into a taller panel — layout, links and recipe come along.

**Presets are shared by all seven panel sizes.** REAPER stores user presets per plugin, and each panel height is a separate plugin to REAPER — so, left alone, a preset saved on the 300 px module would only ever show up on the 300 px module. `StripTease System.lua` keeps the seven preset banks identical, so any preset you save from any size is immediately available from every other size. Nothing to export or import; the only requirement is that the script is running when you save the preset. Renaming or deleting a preset applies to all sizes too. See section 8.



---

## 2. The Elements

| Element | Description |
| --- | --- |
| **Knob** | Rotary control (0–127). Drives plugins via Direct Link, outputs MIDI CC, or both. |
| **Toggle** | Two-state switch (0 / 127) with optional ON label and momentary mode. |
| **Radio** | Stepped selector (2 to 6 positions), horizontal or vertical. |
| **GR meter** | Needle VU meter displaying Gain Reduction, Input Level, or Output Level, with calibration trim. |
| **Stereo VU** | Dual-column level meter with per-channel clip indicators. |
| **GR bar** | Horizontal or vertical gain reduction bar graph. |
| **Separator** | Horizontal dividing line. |
| **Title** | Text label. |

- **Interchangeability:** Convert any knob, toggle, or radio into another via *Change to...*; links, names, colors, and CCs are preserved.
- **MIDI Routing vs. Direct Link:** MIDI CCs emitted by the panel only travel **downstream** (place the panel *above* target plugins for CC control). **Direct Link** uses REAPER's API and works bidirectionally from **any position** in the chain.
- **Click-through:** Titles, separators, and meters ignore clicks during playback to avoid misclicks; edit them in **Edit mode**.

---

## 3. Menu Reference

Right-click any element, background, or tab to open its context menu.

### 3.1 Background Menu

- **Add [element]:** Inserts a knob, toggle, radio, GR meter, Stereo VU, GR bar, separator, or title at the clicked cell.
- **Edit mode:** Toggles dragging and resizing.
- **Show names / Show knob rings:** Toggles control labels and colored value rings.
- **Scroll group:** Assigns *Independent* or *Groups A–D* (panels in the same group scroll and switch tabs together).
- **Color...:** Panel background color (*Palette...* via OS picker, or 11 presets).
- **Grid: N columns (1–4):** Changes column layout.
- **Fit grid to elements:** Expands cell size to accommodate the largest element without overlapping.
- **Tabs:** Configures 2 to 4 pages.
- **Clipboard:** *Copy / Paste layout & links* (entire panel), *Copy / Paste selection* (selected elements), *Clear selection*.
- **Preset links:** Displays active recipe status; *Capture links now* forces recipe creation; *Forget preset links* clears it.
- **Reset All Positions:** Resets controls to defaults (0, 64 bipolar, or 127 max) and meter trims to 0.
- **Resend all CCs:** Re-outputs current values to sync downstream hardware/plugins (greyed out during Global MIDI bypass).
- **Global MIDI bypass:** Mutes all outgoing MIDI CCs from the panel (prevents CC leakage while keeping Direct Link active).
- **Clear all:** Deletes all elements on the panel (irreversible).

### 3.2 Knob, Toggle & Radio Menus

- **Rename / Rename (ON):** Edits control labels.
- **CC number (0–127) / MIDI channel (1–16, All):** Configures outgoing MIDI.
- **MIDI bypass this control:** Mutes MIDI CC output for this element only.
- **Color... / Size...:** Custom RGB palette, presets, or continuous resizing.
- **Change to... (Knob / Toggle / Radio):** Converts control type in place, keeping Direct Link and parameters.
- **Positions (2–6) / Vertical:** *(Radio only)* Step count and orientation (counted from bottom up).
- **Selects scroll group:** *(Radio only)* Uses the radio to switch the panel's active scroll group (A–D).
- **Momentary:** *(Toggle only)* Engaged only while mouse button is held.
- **Bipolar:** *(Knob only)* Centers default at 64; ring fills from center.
- **Init at max:** *(Knob only)* Centers default at 127.
- **Learn / Re-learn / Clear plugin link:** Manages Direct Link to plugin parameters.
- **Tab: [name]:** Moves element to another page.
- **Duplicate / Delete:** Clones or removes the element.

### 3.3 Meters (Needle VU & Stereo VU)

- **Measure:** Selects **Gain reduction**, **Input level** (at panel position), or **Output level** (pre-fader chain end). Click the `GR` / `IN` / `OUT` label on the dial to cycle modes directly. *(Stereo VU supports IN and OUT only).*
- **Reference (0 to −20 dBFS):** *(Level modes only)* Shifts 0 VU calibration to align with your headroom target.
- **Source (Compressor 1–2, Gate 1–2):** Selects which dynamics processor to monitor.
- **Linear / Exponential:** Selects scale law (exponential increases resolution near resting points).
- **Show value / Peak hold:** Displays numeric readout and holds transient peaks.
- **Stereo VU Specifics:** Dual stereo columns; clicking re-arms lit clip indicators; sizing scales height.

### 3.4 Auxiliary Menus

- **GR Bar:** Source selection, linear/exponential scale, vertical/horizontal orientation, peak hold.
- **Title / Separator:** Rename, color palette/presets, tab assignment.
- **Palette (Custom Colors):** Requires `System.lua` and **SWS Extension**. Automatically adapts label contrast based on background luminance.

### 3.5 Tabs & Element Selection

- **Tabs (2–4 pages):** Divides layout into pages. Controls remain active in the background. Disabling tabs re-flows all elements safely back to page 1. Scroll groups switch pages synchronously across grouped strips. Costs ~34 px in height.
- **Selection & Clipboard:** In Edit mode, **Shift + click** selects multiple elements (blue ring). Dragging any selected element moves the batch across the grid (all-or-nothing collision check). Copying retains colors, names, values, and Direct Links.

---

## 4. Mouse & Keyboard Gestures

### Normal Mode

| Gesture | Action |
| --- | --- |
| Drag knob | Adjust value |
| **Ctrl** + drag knob | Fine adjustment (≈ 3× slower) |
| Double-click knob | Reset to default (0, 64 bipolar, or 127 max) |
| Mouse wheel over knob | ±1 step / detent |
| **Ctrl** + wheel | ±1 step / detent (overrides panel scrolling) |
| **Ctrl + Shift** + wheel | ±5 steps / detents |
| Click toggle | Flip state (or hold if Momentary) |
| Click / drag radio | Select position |
| Drag VU screw | Trim meter: ±20 dB in 0.5 dB steps (sensitivity for GR, offset for Level) |
| Double-click VU screw | Reset trim to 0 |
| Click Stereo VU | Re-arm clip indicator |
| Click `GR` / `IN` / `OUT` on VU | Cycle measurement mode |
| Wheel over panel / Drag background | Scroll panel |
| **Shift** + wheel | Fast scroll |
| Hover over linked control | Display real plugin parameter value pop-up |
| Click / Right-click tab | Switch page / Edit tab settings |
| Right-click | Context menu |

### Edit Mode

| Gesture | Action |
| --- | --- |
| Drag element | Move element (snaps to 1/8-cell grid; moves entire selection if selected) |
| Click element / background | Clear selection |
| **Shift + drag up / down** | **Resize element continuously (range 5–64 px)** |
| **Shift + click** | Add / remove element from selection (blue ring) |
| Right-click | Context menu |

*Note:* Resizing elements does not change grid cell boundaries. Use **Fit grid to elements** in the background menu to re-space the grid around the largest control.

---

## 5. Parameter Linking (Direct Link)

Direct Link provides bidirectional, sample-accurate communication between panel controls and plugin parameters, bypassing MIDI CC constraints.

### How to Link

1. Verify `StripTease System.lua` is running.
2. Right-click a control and select **Learn plugin parameter...** (element flashes).
3. Move the desired parameter on the target plugin GUI.
4. The control stops flashing and confirms the link.

- **Bidirectional Sync:** Tweaking either the panel or the plugin GUI updates both immediately.
- **Stepped Parameters:** Linked knobs automatically adopt the plugin's native detents and step counts (for parameters up to ~500 steps).
- **Hardware MIDI Controllers:** Panel controls are standard REAPER FX parameters. To bind a physical controller:
  1. Enable **Input for control messages** in *Preferences > MIDI Devices*.
  2. Move the panel control.
  3. Run the REAPER action *FX: Set MIDI learn for last touched FX parameter* and move your hardware knob (enable *Soft takeover* if needed).

```
Hardware Controller → REAPER MIDI Learn → Panel Element → Direct Link → Target Plugin
```

---

## 6. Metering — Gain Reduction & Levels

Meters can display **Gain Reduction**, **Input Level**, or **Output Level**.

### Gain Reduction Routes

Gain reduction values are routed automatically in three ways:

1. **Natively:** Plugins reporting `GainReduction_dB` (VST3 `IGainReductionInfo` or REAPER VST2 extension) are read automatically.
2. **Through Parameter Readout & Learned Readouts:**
   - Detects parameters named *gain reduction*, *gr readout*, *gr meter*, *attenuation*, *expansion*, or weak keywords (*redux*, *compression*).
   - Validates graduation to prevent scale errors: unitless 0–100 percentage scales are rejected, while true decibel travel down to −90 dB (or 120 dB span) and `-inf dB` / `-∞ dB` readouts are scaled accurately.
   - **Learned Readouts:** Observes parameter movement during playback. Once verified, learned mappings persist in cache per plugin type across sessions.

#### Gate & Expander Classification and Limitations

During playback, StripTease observes readout behavior against track dynamics:
- **Compressor:** Reduction increases on loud signals (> −40 dB) and returns to rest when quiet.
- **Gate / Expander:** Attenuation increases on quiet signals (< −60 dB) and opens up when loud. Confirmed gates route automatically to `Gate 1` / `Gate 2`.

> [!WARNING]
> **Gate Detection Limitations ("Better, but not perfect"):**
> 1. **Dynamic Contrast Required:** Classification requires both loud passages (> −40 dB) and quiet passages (< −60 dB). On continuously dense, loud audio, total silence, or when the gate threshold is never crossed, the behavioral check cannot resolve and the candidate remains unconfirmed.
> 2. **Native & Measured Fallback:** Plugins reporting natively via VST API or measured via audio contain no dynamics-type flag. StripTease falls back to name matching (`gate`, `expander`, `pro-g`). Multi-effects or channel strips without these words in their name will default to a `Compressor` slot.
> 3. **Manual Override:** When auto-detection fails or misclassifies, run `StripTease Check.lua` to inspect parameters and explicitly set the plugin type (*Compressor or gate? y/n*).

3. **Measured by the Panel (Audio-Rate or Fallback):**
   When a plugin reports nothing and exposes no parameters, StripTease measures gain reduction by comparing audio across the plugin.

#### Is a container still necessary?

- **To get basic Gain Reduction:** **No.** In a normal flat chain, placing the panel **above** the compressor measures reduction via the **flat-chain fallback** using REAPER's track meter.
- **To use the v1.2.1 Audio-Rate DSP Engine:** **Yes.** The high-precision JSFX DSP engine requires simultaneous access to both the compressor's input (channels 3/4) and output (channels 1/2) in the same audio block. This 4-channel tap requires a container.

#### Measurement Routes Compared

| Feature | Container Setup (*The Good Way*) | Flat Chain Fallback |
| --- | --- | --- |
| **Precision** | **Audio-rate** (64-sample sub-chunk RMS ratio: $g = \sqrt{\sum y^2 / \sum x^2}$) | ~30 Hz track-meter polling |
| **Ballistics** | True attack and release response | Fast attacks/releases smoothed over |
| **Latency / PDC** | Sample-accurate 8192-sample ring buffer alignment | Uncompensated |
| **Validation** | 700 Hz dual-band split consistency check (`GrBandSplit`) | None |
| **Mixer Independence** | Immune to track fader, pan, and mute | Inactive if fader at −∞ or muted |
| **Wiring** | Right-click plugin → *Move FX to container*, panel immediately after | Panel simply placed above compressor |

- **MCP Embedding with Containers:** Place the panel **immediately after the container** (StripTease expands the track to 4 channels automatically). This keeps the panel at the top level so its UI embeds in REAPER's MCP.
- **Rest Gain Estimation (`GrRestGain`):** Reads makeup directly from plugin parameters, or extrapolates static gain on bus compressors via a 2D histogram linear regression.
- **Dry/Wet Mix Inversion:** Un-blends parallel compression ($g_{wet} = \frac{g - (1 - m)}{m}$) so the needle reflects internal reduction.
- **Mono Plugins:** Measured on left channel only.

### Level Modes (Input & Output)

- **Input Level:** Measures audio entering the panel at its specific slot in the chain.
- **Output Level:** Pre-fader level at the end of the chain (derived from REAPER's track meter divided by fader volume).
- **Scale & Calibration:** 23 dB range (−20 to +3 dB relative to reference; red zone at 0 to +3 dB). Trim screw offsets level readings (±20 dB). An orange dot indicates missing data (muted track or script stopped); true silence shows −inf without the dot.

---

## 7. Presets, Recipes & Mapping

Direct Links normally break across tracks because REAPER assigns new GUIDs. StripTease overcomes this using **Recipes**:
- A recipe saves the **original plugin name** and **parameter index**.
- When a panel preset, track template, or FX chain loads on another track, `System.lua` scans the track and rebuilds all links automatically.
- **One Recipe per Panel:** A panel holds links for one primary plugin. Status is shown in the background menu (`Preset links: N on <plugin>`).

### Bundled FX Chains

Twelve pre-mapped FX chains are included in `FXChains/`:

| Chain | Target Plugin | Panel Height |
| --- | --- | --- |
| `StripTease SSL4000E` | bx_console SSL 4000 E (Plugin Alliance) | 600 px |
| `StripTease SSL4000G` | bx_console SSL 4000 G (Plugin Alliance) | 600 px |
| `StripTease SSL9000J` | bx_console SSL 9000 J (Plugin Alliance) | 600 px |
| `StripTease BX Glue` | bx_glue (Plugin Alliance) | 400 px |
| `StripTease TownHouse Bus` | bx_townhouse Buss Compressor (Plugin Alliance) | 300 px |
| `StripTease Bx Opto` | bx_opto (Plugin Alliance) | 300 px |
| `StripTease Vertigo VSC-2` | Vertigo VSC-2 (Plugin Alliance) | 300 px |
| `StripTease Pro-C3` | Pro-C 3 (FabFilter) | 300 px |
| `StripTease UAD 610A Pramp` | UADx 610-A Preamp & EQ (Universal Audio) | 200 px |
| `StripTease UAD 610B Pramp` | UADx 610-B Preamp & EQ (Universal Audio) | 200 px |
| `StripTease UAD DBX 160` | UADx dbx 160 Compressor (Universal Audio) | 200 px |
| `StripTease AO The Bus` | TheBus (Analog Obsession) *(Container setup)* | 200 px |

*Tip:* If you don't own these specific plugins, load the chain and use *Learn plugin parameter* to re-map the layout to your preferred processors.

---

## 8. Cross-Size Preset Synchronization

The seven panel heights share the exact same parameter structure. `StripTease System.lua` checks REAPER's preset files every two seconds and synchronizes user presets across all seven sizes. A preset saved on a 200 px panel is instantly available on 050–600 px panels.

---

## 9. Key Limitations & Technical Notes

- **MIDI CC vs. Direct Link:** MIDI CC travels downstream only; Direct Link is bidirectional, displays value pop-ups, and works anywhere in the chain.
- **MIDI Bypass:** Use *Global MIDI bypass* or per-control bypass to prevent unwanted CC output from interfering with downstream synths or MIDI learn.
- **Panel Capacity:** 100 elements, 1–4 grid columns, up to 4 tabbed pages.
- **Multiple Panels:** Multiple panels can coexist on the same track with independent links and recipes.
- **Destructive Actions:** *Clear all* and element deletion are irreversible.
- **HiDPI:** Panels scale automatically with REAPER's display settings.
- **Native Sliders Hidden:** The 100 underlying sliders remain fully automatable but are hidden from the UI.
- **Tabs Height:** The tab bar consumes ~34 px of vertical height.
- **Session Scroll:** Per-tab scroll offsets are maintained during the session; reopening a project resets scroll positions to the top.
