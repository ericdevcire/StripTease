# Changelog

All notable changes to StripTease, newest version first. Version numbers match the entries ReaPack shows.

## 1.2.3 — 2026-09-24

**Community presets:**
- New `Community/` folder for presets shared by users, distributed as a separate ReaPack package: **StripTease Community Presets**.
- `StripTease Install FX chains` also copies the community chains, into `FXChains/StripTease Community/`.
- Presets are submitted by pull request (or by issue, for those without GitHub experience): see `CONTRIBUTING.md`. Each submission is checked automatically, and the catalog and the ReaPack package update themselves after the merge.
- Licence: new *Contributions* section.

**Antialiased knob pointer:**
- The white pointer line on knobs is now drawn with true antialiasing: straight and even on both edges, at every angle, with clean round ends.
- Fixed a pointer that was slightly off true: it now stands exactly vertical at the centre of a bipolar knob, and exactly on the diagonal at 0 and 127.
- The pointer moves smoothly, with no one-pixel jumps as the knob turns.

**Antialiased VU meter needle:**
- The VU needle is now antialiased (the stepped edges are gone), with its drop shadow drawn the same way.
- Slimmer needle: half as wide at its base, tapering to a fine tip.

**Performance:** measured at about 20 µs per frame per panel (3 knobs and 1 VU), under 0.1% of a CPU core. Drawing only, with no effect on audio processing.

## 1.2.2 — 2026-09-13

**Batch resize on multi-selection:**
- In edit mode, holding Shift while clicking and dragging on any selected element resizes all selected elements simultaneously.
- Element proportions and size offsets are preserved relative to their individual baseline sizes.

**Reverse mode for Knobs and Radio buttons:**
- Added a `Reverse` toggle in the right-click context menu for knobs and radio buttons (in addition to `Init at max`).
- Knobs: Turning clockwise (or dragging upward) advances the knob clockwise visually while inverting the transmitted value ($0 \leftrightarrow 127$), ideal for inverted VST parameters (thresholds, cuts, attenuation).
- Radio: Button visual order remains [1][2][3], but position mapping is reversed so that the first button selects the maximum value and the last selects the minimum.

**Per-tab background color:**
- Each tab/page can now have its own distinct background color.
- Settable directly from the tab header context menu or via the main background color palette when tabs are enabled.
- Fully serialized (version 19) and preserved across layout clipboard copy/paste operations with backward compatibility.

**REAPER track fader decoupling for OUT meter:**
- Fixed abnormal needle oscillations and violent spikes when moving REAPER's track volume fader while a meter is set to OUT mode.
- Automatically detects whether REAPER's track meter is already configured pre-fader (`I_VUMODE & 512`), preventing erroneous double-division.
- Implements decay-ballistics tracking on volume changes to prevent denominator lag spikes during fast downward fader movements, with transient jitter suppression while the fader is in motion.

**"Select all" option in right-click context menu:**
- Added a `Select all` entry in both the element right-click menu and the panel background right-click menu.
- Instantly selects all active elements on the current tab and enters edit mode with visual selection rings.

**Antialiased knob ring rendering with quad bands:**
- Knob ring drawing completely rewritten from concentric arc loops into continuous quad bands (`sb_ring_band`) rotated with a 2D rotation recurrence matrix (saving two trigonometric calls per segment).
- Outer ring edge traced twice with `gfx_arc` (with a 0.6 px offset to prevent LICE bounding box clipping on cardinal points), giving a smooth antialiased outer perimeter.
- Ring thickness slimmed down by 20% (`6.4 * sb_uisc` vs 8 px) while preserving the cell boundary, hit test, and halo dimensions.
- Outer and inner edges anchored to integer pixel rim boundaries (`floor(r + sb_uisc)`), eliminating subpixel thickness oscillations between 4 and 5 pixels across knob sizes and curing the optical illusion where rings appeared thinner on the right.
- Angular segmentation now dynamically scales with radius based on a 0.3 px maximum chord sag, rather than a fixed 94 segments.
- Sweep rendering thresholded so resting or minimal arcs (< 0.02 rad) are bypassed.

**Knob face, pointer, and highlight refinements:**
- Face and outer dark rim now feature antialiased circular contours (`gfx_circle(..., 0, 1)`).
- Added a subtle specular top-rim highlight curve that adapts its opacity based on dark vs light panel themes.
- Pointer needle redesigned with a solid polygon body (`gfx_triangle`), smoothed border lines, and circular end-caps, replacing stepped parallel lines.

**Pixel-perfect layout and integer subpixel snapping across all elements:**
- Floating-point positioning throughout the drawing engine snapped to whole pixels (`floor(... + 0.5)`), eliminating subpixel blur, fuzzy edges, and rounding seams between adjacent elements.
- Toggle switches: integer coordinates, explicit border widths, and crisp upper highlight/shadow lines.
- Radio buttons: integer cell dimensions, clean borders, and centered group letters.
- Separators: pixel-aligned horizontal rules with centered text cutouts.
- Element labels, parameter readouts, tooltips, and tab headers: pixel-snapped centered text placement.
- Selection and hover halos: pixel-aligned bounding boxes and circles across all element types.

**VU Meter rendering optimizations:**
- Background shading upgraded to native hardware `gfx_gradrect`, eliminating the 8-slice vertical drawing loop.
- Scale ticks and graduation numbers calculated using incremental rotation matrices, removing over 20 trigonometric `sin`/`cos` calls per meter per frame.
- Scale red zone drawn with antialiased `gfx_arc` instead of a 16-segment line loop.
- Needle calibration screw slot bordered with antialiased lines.
- Small VU meters and horizontal/vertical bar meters fully pixel-aligned.

**Modern rounded scrollbar:**
- Scrollbar thumb redesigned as a modern rounded pill shape using `gfx_roundrect` with inner body fill and smoothed corners.
- Snapped to integer pixels with a guaranteed minimum thumb height.


## 1.2.1 — 2026-09-07

**Gate detection and classification on parameter readouts.**
The parameter-readout route now supports gates and expanders:
- **Behavioural confirmation classifies side:** The measurement that confirms a readout during playback now checks whether reduction occurs on quiet passages (gates) or loud passages (compressors), routing to `Gate 1` / `Gate 2` meters without relying on plugin naming alone.
- **Negative infinity parsing:** Readouts displaying `-inf dB` or `-∞ dB` at full close now deflect the meter to full reduction instead of reading as 0 dB.
- **Wide travel support for explicit dB graduations:** Readouts graduated down to −90 dB (or up to 120 dB span) are judged linear when explicit dB units are present, while unitless 0..100 percentage scales continue to be rejected.
- **Extended weak candidate vocabulary:** Added `attenuation`, `expansion`, and `gate meter` to weak parameter detection.
- **Persistent dynamics side in cache:** Learned gates survive REAPER restarts, with full backward compatibility for existing two-field entries.
- **Bounded observation:** Pending confirmation candidates now carry an active deadline so a candidate never remains stuck in observation.
- **`StripTease Check.lua` alignment:** Reports dynamics side (`[comp]` or `[gate]`), weak parameter status, and counts plugins exposing two separable readouts.

**Rebuilt Gain Reduction DSP measurement engine.**
The audio-rate Gain Reduction measurement system has been rebuilt from the ground up with a high-precision DSP core natively in JSFX:
- **Sub-chunk RMS Energy Ratio (64 samples):** Audio-rate measurements are calculated as $g = \sqrt{\frac{\sum y^2}{\sum x^2}}$ over 64-sample sub-chunks. This calculation is phase-independent, exact across arbitrary complex waveforms, and resilient to saturation and harmonic distortion.
- **`GrRestGain` regression estimator:** Replaces the previous 30-second asymmetric peak tracker with a 2D level/gain histogram and linear regression over the lowest populated input levels. On bus compressors that are in continuous reduction, it extrapolates the rest gain below threshold, completely solving the "sagging needle" limitation. When insufficient data is available, it falls back to a P95 quantile on the gain distribution, and forgets half its history upon parameter movements.
- **700 Hz Band-Split Consistency Validation (`GrBandSplit`):** A dual-band single-pole split filter checks for spectral gain consistency across the compressor. If the low and high bands disagree by more than 4 dB (with a 3 dB hysteresis recovery), the measurement is flagged as untrustworthy (preventing false gain reduction indications on EQs or multiband processors).
- **Dry/Wet Parallel Mix Inversion:** Exact mathematical inversion of the dry/wet blend ($g_{wet} = \frac{g - (1 - m)}{m}$) recovered directly from the plugin's mix parameter.
- **PDC Latency Alignment:** The compressor's output is framed sample-accurately against delayed input samples through an expanded 8192-sample ring buffer.

**`StripTease.jsfx` simplified to a passive GR monitor (RobKor code purged).**
`StripTease.jsfx` has been rewritten into a lightweight shared-memory monitor:
- It listens directly to the values published by `StripTease System.lua` in `gmem`.
- It can mirror the reduction to REAPER's native track meter (`ext_gr_meter`).


**ExtState interoperability.**
Added bidirectional synchronization between `StripTeaseGR` and `StripTeaseGRParam` ExtState namespaces for parameter learning cache.

**MIDI bypass options (Global and per-control).**
Added context menu options to prevent unwanted MIDI CC routing:
- **Global MIDI bypass (bypass all MIDI):** Right-click on an empty panel area to mute all outgoing MIDI CC messages from the panel's controls. The *Resend all CCs* menu item is greyed out while global bypass is active. Direct Link parameter automation remains fully functional.
- **MIDI bypass this control:** Right-click on an individual control (knob, toggle, radio) to mute its MIDI CC output independently.
- **State persistence:** Both settings are saved with the project (serialization tier 18), preserved across layout and element clipboard operations, and non-bypassed controls automatically resync their values upon unbypassing.

## 1.2.0 — 2026-08-30

**A panel holds 100 elements instead of 50.** The local memory map, the per-track stride of the shared memory and both clipboards were re-laid around the new count. Existing panels are unaffected: the serialized stream keeps a frozen tier per version, so a panel saved by an earlier build is read back with its 50 elements, its labels, its tabs, its frozen grid and its parameter links exactly where they were, and the space above simply comes up empty. Nothing has to be rebuilt, and no layout moves on the way in.

**Two panels on the same track keep their own links.** Link state was addressed by track: a second panel on a track wrote over the first one's cells and wiped its links. Each panel now gets its own slot, handed out by the service through a directory it publishes. The first panel of a track keeps the address it had when there could only be one, so a project made before this finds its links where it left them without republishing anything, and the link recipe saved in the project keeps its old key for that first panel.

**A control changes type without losing its link.** *Change to...* in a knob, toggle or radio's menu converts it into either of the other two, in place. The cell, the CC number, the MIDI channel, the colour, the size, the name, the page and — the point of the exercise — the **Direct Link** all stay exactly as they were: only the way the value is shown and grabbed changes. Laying out a strip no longer means picking the right type first and living with it, and a knob that turns out to want three fixed positions becomes a radio while still driving the same plugin parameter. The type-specific flags are the one thing that does not carry over: *Momentary*, *Bipolar*, *Init at max* and the scroll-group role start again at the defaults of the type you land on, since the same flag bit means something different on each. A radio dropped onto a linked stepped parameter picks up that parameter's own positions.

**A radio can take over the panel's scroll group.** *Selects scroll group* turns it into the group selector: its positions stand for A, B, C, D in order — two positions give A and B, four give A to D. While it is armed the radio has the last word; the panel's own *Scroll group* menu writes into it rather than around it, and the groups the radio cannot reach are greyed out there. Only one radio at a time holds the wheel — arming a second disarms the first — and disarming it hands the radio back its ordinary life as a control. Where several strips scroll together, this puts the choice on the panel itself instead of two levels down a menu.

**The Panel Builder ships with the package.** Select a track, run it, pick a plugin from the chain: it lists the parameters, you tick the ones you want, and it drops a finished panel on the track -- elements typed after what each parameter really is, placed, named, coloured and already linked to the plugin, without a single *Learn plugin parameter* to run. Every parameter the plugin declares is listed, none is hidden on the strength of its name; a radio button is laid down only where the source control really enumerates its positions, and a knob with detents stays a knob instead of turning into a row of buttons. It needs the **ReaImGui** extension for its window, and says so plainly if it is missing rather than failing in silence.

**The MIDI CC a control sends is a plain one-way output.** The panel used to declare its CC numbers to the service, which swept every parameter of every plugin on the track looking for a matching MIDI learn and sent the value of whatever it found back to the control. That sweep was by far the service's heaviest task, and it paired up links nobody had asked for. The CC now simply leaves on the chain, like any other controller, and it is REAPER's business to receive it if a learn is waiting downstream. A control driven by CC therefore no longer follows the plugin back and shows no value pop-up — Direct Link is the bidirectional route, and it works from any position in the chain. A link does not silence the CC: a control can drive one plugin through Direct Link and another through MIDI learn at the same time, as before.

**Driving a panel from a hardware controller, documented.** A panel element is an ordinary FX parameter, so REAPER's own MIDI learn binds it to a physical knob like any other: tick the controller under *Enable input for control messages*, move the element, run *FX: Set MIDI learn for last touched FX parameter*. That path is global -- no armed track, no MIDI input routing, no monitoring -- and it composes with Direct Link into the full chain, hardware controller to panel element to plugin parameter. Nothing changed in the code; the manual simply never said it was possible.

**Restart REAPER after updating.** The shared memory has been re-laid, and a panel or a service still running from the previous build addresses the new one's cells until it is reloaded. The layout clipboard carries a new token for the same reason, so a panel from either build sees the other's clipboard as empty rather than pasting from an address nothing writes to.
