# STRIPBUS User Manual

Welcome to the comprehensive guide for the StripBus module in REAPER. This document covers the core concepts, an exhaustive list of all menu options, and the workflow for direct parameter linking and creating smart presets.



## 1. Overview & Setup

The StripBus ecosystem separates the visual feedback (Gain Reduction meters, knobs, and bars) from the actual plugin processing. 

### StripBus System.lua
To use the Gain Reduction meters, simply run the `StripBus System.lua` script once. It runs in the background and automatically finds any compressor or gate on your tracks that reports its GainReduction_dB to REAPER. It then sends this data to the JSFX panels. If you have SWS installed, you can create a « Global Startup Action » to automate this script launch at Reaper Startup.

### StripBus Check.lua
If a compressor’s Gain Reduction doesn't show up on your vu-meter, run this check script while the project is playing. It will list all plugins and tell you if they natively report their gain reduction to REAPER.

### Panels
You can choose the initial vertical size of the panel in the jsfx list. 
In reaper you will want to activate : « Show Embedded UI in MCP » in the mixer FX slot, so that you can view the StripBus UI in your mixer.
If after populating your module the controls don’t fit well, you can copy it’s content (right-click menu), and paste in another panel with a more suitable size.
Whatever panel size you choose, you can add up to 50 elements, you’ll always have possibility to scroll down to reach all of them in the module.

**Presets are shared by all seven panel sizes.** REAPER stores user presets per plugin, and each panel height is a separate plugin to REAPER — so, left alone, a preset saved on the 300 px module would only ever show up on the 300 px module. `StripBus System.lua` keeps the seven preset banks identical, so any preset you save from any size is immediately available from every other size. Nothing to export or import; the only requirement is that the script is running when you save the preset. Renaming or deleting a preset applies to all sizes too. See section 4.



## 2. The Right-Click Menu

Right-clicking on any element in the StripBus panel opens a contextual menu. Depending on the element you click (a knob, a VU meter, a bar, or the background), you will see specific options from this list:

### Adding Elements (Background Menu)
*   **Add knob**: Adds a standard rotary knob.
*   **Add toggle**: Adds a standard on/off switch.
*   **Add radio**: Adds a multi-position selector switch.
*   **Add GR meter**: Adds a Gain Reduction needle meter.
*   **Add GR bar... > Horizontal / Vertical**: Adds a Gain Reduction bar meter.
*   **Add separator**: Adds a visual line break to organize the module.
*   **Add title**: Adds a standalone text label.

### Element Properties & Editing
*   **Rename...**: Changes the text label displayed below the element.
*   **Rename (ON)...**: (For toggles) Changes the text displayed when the toggle is engaged.
*   **Duplicate**: Creates an exact copy of the selected element.
*   **Delete**: Removes the selected element.

### Aesthetics & Appearance
*   **Color...**: Change the color palette of the element. Options include White, Dark, Green, Red, Blue, Yellow, Orange, Pink, Light gray, Dark gray, and Gray.
*   **Size...**: Changes the visual scale of generic elements (like knobs). 
    Options: Tiny, Small, Medium, Large, Very large, Huge.
    *(Tip: You can also hold `Shift` and drag up/down on an element to resize it fluidly).*
*   **Size (VU Meter)...**: Specific fixed pixel widths for the needle meter (e.g., 90px up to 210px) to ensure it fits nicely in your track layout.
*   **Size (Bar)...**: Specific pixel lengths for the bar meter.
*   **Positions...**: Defines how many steps a switch or radio button has (e.g., 2 to 6 positions).
*   **Scale...**: Changes the meter reading curve. 
    Options: Linear (0, 4, 8, 12, 16, 20) or Exponential (0, 2, 4, 6, 10, 20).
*   **Vertical / Horizontal**: Changes the orientation of radio switches and GR bars.
*   **Show value**: Toggles the numeric display overlay for meters and knobs.
*   **Peak hold**: (For GR meters/bars) Keeps the highest peak visible for a moment.
*   **Momentary**: (For toggles) Changes the switch behavior so it only stays ON while you hold the click.
*   **Bipolar**: (For knobs) Centers the default value at 64 instead of 0 (useful for panning or EQ gain).
*   **Init at max**: (For knobs) Sets the default reset value to 127 instead of 0.

### Routing & Source
*   **Source...**: Tells the meter which plugin on the track it should read.
    Options: Compressor 1 to 4, or Gate 1 to 2. 
    *Note: The system identifies gates based on keywords in the plugin name. If a gate is listed as a compressor, just select the corresponding Compressor number.*
*   **CC number...**: (For MIDI controlled elements) Assigns a specific MIDI CC (0-127) to a knob.
*   **MIDI channel...**: Assigns the element to a specific MIDI channel (1-16) or All Channels.

### Direct Parameter Linking
*   **Learn plugin parameter...**: Activates the "Direct Link" listening mode to bind this element to a real plugin parameter (see Section 3).
*   **Re-learn plugin parameter...**: Overwrites an existing link.
*   **Clear plugin link**: Removes the direct link.

### Preset Links Management
*   **Preset links: ...**: Status display showing how many links are currently active in the recipe for saving as a preset.
*   **Capture links now**: Manually forces the panel to read the track and populate the preset recipe.
*   **Forget preset links**: Clears the preset recipe memory so links won't be copied.

### Layout & Workflow
*   **Edit mode**: Toggles edit mode to allow moving elements by dragging them.
*   **Show names**: Globally toggles the display of element names under controls.
*   **Show knob rings**: Globally toggles the colored indicator rings around knobs.
*   **Grid...**: Sets the number of columns for the panel grid.
*   **Scroll group...**: Assigns the current track's panel to a scroll group (Independent, Group A, B, C, D.). This is highly useful for navigating large track counts where multiple tracks scroll their panels together.
*   **Copy layout & links**: Copies the entire panel setup and all direct links to memory.
*   **Paste layout & links**: Pastes a copied setup onto the current panel.
*   **Reset All Positions**: Resets all knobs, toggles, and radios on the panel to their default values (0, 64, or 127).
*   **Reset (0/64/127)**: Resets only the specific clicked element to its default value.
*   **Resend all CCs**: Broadcasts all current CC values to the track (useful to force a plugin to sync if it lost state).
*   **Clear all**: Deletes every element on the panel (Warning: cannot be undone).



## 3. Parameter Linking (Direct Link)

StripBus offers a Direct Link system that completely bypasses REAPER's native MIDI CC or Parameter Modulation limits. This means the panel controls the plugin, and if you move the plugin's GUI, the panel updates instantly (bidirectional sync).

Once a parameter is mapped, the source value is displayed on a small popup when hover and tweak, so you can read the actual data from the targetted plugin.

**The Method to Link Correctly:**
1. Ensure the background script (StripBus System.lua) is running.
2. In the StripBus JSFX panel, Right-Click the knob or control you want to link.
3. Select "Learn plugin parameter...". The element will start flashing/highlighting to indicate it's listening.
4. Open the FX window of the plugin you want to control (it must be on the same track).
5. Move the parameter you want to link (click and drag it slightly with your mouse).
6. The StripBus element will stop flashing and display a success message. The link is now active in both directions!

To remove a link, simply right-click the element and select "Clear plugin link".



## 4. Creating Layout Presets & Plugin Mapping

A direct link uses a unique ID (GUID) tied to the specific instance of the plugin on your track. Normally, this means if you duplicate the track, the link would break. StripBus solves this via "Recipes".

**How Recipes (Presets) Work:**
When you link a parameter, StripBus not only remembers the exact instance, but it also writes a Relative Recipe into the JSFX preset state. This recipe includes:
*   The Name of the target plugin.
*   The Parameter Number.

**One recipe describes one plugin.** An element learned on a *different* plugin still works (its link is intact), but it does not join the recipe — so it will not travel with the preset. This matters when you derive one preset from another: load "SSL 4000 E", re-learn everything onto an SSL 4000 G, and each re-learn removes that element from the 4000 E recipe. The panel then adopts the 4000 G automatically (within two seconds of the recipe becoming empty), but **the preset you saved before that point carries no links at all** — check the background menu, it must read `Preset links: N on <your plugin>` and not `none yet`, then save the preset again.

**How to Create Reusable Mappings:**
1. Add a plugin (e.g., an EQ or Compressor) to your track.
2. Add the StripBus Panel JSFX.
3. Use the Learn method (above) to map all the knobs you need to the plugin's parameters.
4. Save the track as a Track Template (or save the FX Chain).
5. **The Magic**: When you load this Track Template on a new track, the `StripBus System.lua` script reads the recipe from the panel. It searches the new track for a plugin with the *exact same name*, and automatically rebuilds all the bidirectional links for the new instance.

This allows you to map your favorite plugins once, save them as presets, and use them anywhere without ever having to "Learn" them again!

### One Preset Bank for All Panel Sizes

The seven panel modules (050 / 100 / 150 / 200 / 300 / 400 / 600 px) only differ by their fixed height — same 50 sliders, same saved state, same engine. Their presets are therefore fully interchangeable, but REAPER files user presets by plugin, and it sees seven different plugins.

`StripBus System.lua` closes that gap: every two seconds it compares the seven preset files REAPER keeps in `<REAPER resource path>/presets/`, and propagates any change to the other six.

*   Save a preset from the 300 px panel → it appears in the preset list of all sizes.
*   Rename or delete a preset from any size → the change applies everywhere.
*   A size you have never used yet gets the whole bank the first time the script runs.
*   Reopen the FX window (or the preset menu) if a brand new preset is not listed yet — REAPER re-reads the file when it changes, but a menu already on screen won't refresh by itself.

Two things stay outside of this: the per-module default preset (*Save preset as default*, which REAPER stores elsewhere), and preset names — a name identifies a preset in the shared bank, so if two sizes happened to hold different presets under the exact same name, only one of them survives the first merge.
