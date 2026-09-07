# Changelog

All notable changes to StripTease, newest version first. Version numbers match the entries ReaPack shows.

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

## 1.1.1 — 2026-08-18

**A gain-reduction readout is converted to real decibels, instead of being trusted blind.** When a compressor exposes its reduction as an ordinary parameter, StripTease used to publish that parameter's value as if it were already in dB — the only test was that its range spanned more than 1.5. A readout graduated 0..100, which is a percentage of the plugin's own meter and not decibels, sailed through that test and drove the needle as a hundred dB. That is where the disagreement between the needle and the plugin's own meter came from, and why it took a different amount of trim on every plugin. StripTease now asks the plugin what it would display at each end of the readout's travel — a read-only question, the same one already used to vet a makeup control — and derives the conversion from the answer. A readout whose unit still cannot be established is refused outright rather than published in the wrong scale: the plugin then falls back to being measured by the panel, which compares two levels in dB and cannot get the scale wrong. Readouts already learned on earlier versions are re-examined the same way, so a plugin that was learned crooked is corrected without anything to reset.

**The dB is read from the label, not from the first number in it.** A readout displaying `4.0:1  -6.0 dB` published the ratio, and `1: -3.2 dB` published the channel number. The number attached to the dB unit is now the one taken, with a decimal comma, a Unicode minus and `-inf` all understood.

**`StripTease Check.lua` says what it reads and why.** Each plugin's line now names its route the same way — native, parameter, or measured — and, for a parameter, the mode, the scale factor applied, and the string the plugin itself displays. A readout that was refused says so and says what it read instead of decibels. When the makeup is estimated rather than read, the report now states that the resulting error is an offset that moves with the programme, that no trim can correct it, and which question to answer to remove it.

**The GR meter's calibration screw is a sensitivity, not an offset.** Adding dB on the screw used to be added to the reading, which pushed the whole scale up: with +3 dB, the slightest compression pinned the needle at 3 and it never came back down, and the bottom of the dial was lost. The screw now moves the top of the scale instead — +3 dB means full deflection is reached 3 dB earlier, −3 dB the opposite. Zero reduction stays the resting position whatever the trim, so the dial always reads from 0 to the top of its scale. Level meters (`IN` / `OUT`) keep the offset trim, which is what a dial calibrated in dBFS expects.

**A smoother needle.** The rise was instantaneous: the needle planted itself on every value it was handed, and since the source publishes in bursts — 30 Hz on the track-meter route, the audio block otherwise — it shivered in place. Both directions now go through the same one-pole filter, the rise still clearly quicker than the fall, the way a console VU behaves. Peak hold keeps its instant detection: showing the transient the needle smooths over is its job.

**The calibration screw goes wider: ±20 dB instead of ±6**, still in 0.5 dB steps, still zeroed by a double-click. On a GR meter the deflection now doubles every 10 dB of screw — +10 reads twice as far, +20 four times, −10 half. A sensitivity does little near the bottom of the dial, which is where a gain-reduction needle spends most of its life: at 3 dB of reduction the old ±10 bought a seventh of the dial, where ±20 buys nearly half. The law also lost its edge — the previous one moved the top of the scale closer and ran to infinity as the screw reached it, so it could not be opened up any further; this one climbs by the same step everywhere.

**Credit where it is due.** The panel's own gain-reduction estimate follows the method of the StripLink Aggregator by RobKor (Wormhole Labs). It is reimplemented here, but the approach comes from there and is now credited in the README and in the header of `StripTease.jsfx`. Thanks to RobKor.

## 1.1.0 — 2026-08-17

**Gain reduction measured through a container, at the audio rate.** A compressor that reports nothing can now be put in a REAPER container — *Move FX to container* — with the panel as the container's last item, or immediately after it in the chain. StripTease recognises the shape and maps the container's input pins so that its own input is copied onto channels 3 and 4: the panel then holds the compressor's output on 1/2 and its input on 3/4, in the same audio block. Attack and release settings show through, and the reading is immune to the fader, the panner and the metering preferences, which all sit after the container. The compressor's reported latency lines the two probes up, so a lookahead design no longer throws false spikes on transients. The flat-chain route introduced in 1.0.1 stays as the fallback when there is no container.

**Compressors recognised on their own.** By parameter shape first — a threshold, plus something that says what happens once it is crossed: a ratio, an explicit makeup, or an attack together with a release. That covers designs with no ratio control at all, a Fairchild-style variable-mu among them. Failing that, by name, against a list of about fifty device names matched on the name stripped of punctuation, so `LA-2A`, `LA 2A` and `CLA2A` are one entry. The list names models, never brands.

**Point at a plugin by hand when the rules miss it.** `StripTease Check.lua` now prints the full parameter list with values and ranges, and asks which parameter is the makeup, which is the other side, which is the parallel mix, which is the auto-gain switch. Nothing is stored until those numbers are confirmed. The result is filed per plugin type, so every instance in every project follows, and it survives StripTease updates. The running service picks the change up without being restarted.

**A parallel mix is undone.** A compressor blending only part of its work into the output reduces the chain by that same fraction. When the makeup is read, StripTease reads the mix control too and inverts the blend, so the needle shows the reduction the compressor computes — what its own meter shows. At 100% wet nothing changes; below about 10% the inversion is dropped rather than amplify measurement noise; at zero wet there is nothing to read.

**`StripTease Check.lua` report rewritten.** Much shorter, explanations cut back to the essentials, and the link-recipes section removed from the report. Each plugin now says how its reduction is read — natively, through a parameter, or measured by the panel — and, when measured, whether that happens at the audio rate through a container or through the slower track-meter fallback.

**New FX chain: `StripTease AO The Bus`.** TheBus (Analog Obsession) publishes no reduction by either automatic route, so the chain ships it in a container with the panel right after — the worked example of the setup above, ready to drag in and to copy onto any other silent compressor.

**`StripTease.jsfx` (*StripTease GR*) superseded.** The panel measures on its own; there is nothing left to insert, number or switch on by hand. The JSFX is still shipped so that older projects using it keep working.

**Manual.** The FX chain table now lists all twelve chains — `StripTease Bx Opto` and `StripTease UAD DBX 160` shipped from 1.0.0 but had never been listed — and section 6 is rewritten around the two measurement routes.

## 1.0.1 — 2026-08-17

The repository went from 1.0.0 straight to 1.1.0, so these changes reach most users as part of 1.1.0.

**The panel measures gain reduction itself, with nothing to insert.** With the panel sitting above the compressor in a flat chain, StripTease compares the panel's input to the track meter and publishes the difference. No JSFX to add, no compressor number to set. The track meter is only read about 30 times a second, which is the limit of what the needle can show of the compressor's timing.

**Learned readouts.** Plenty of plugins publish their reduction under a name no rule can vouch for — *Redux*, *Reduction*, *Compression*, *GR* — often as a normalized 0..1 parameter that spells its dB out only in the displayed text. Such a parameter is now adopted on behaviour instead of on its name: while the track plays, a reduction readout climbs when the signal gets loud and returns to rest when it goes quiet. What is learned is remembered per plugin type.

**Makeup read from the plugin instead of estimated**, when the panel sits immediately above a chain-ending compressor — the reading is right from the first frame, instead of waiting for the compressor to let go before the estimate settles.

**Mono-instantiated plugins measured on the left channel only.** REAPER only feeds them channel 1, and the right channel goes through untouched.

**Native reduction reporting always wins over the measured route**, so a reduction is never counted twice — once by the plugin and once inside the measurement.

**Measurement ballistics no longer flattened.** Both probes now share the track meter's law and a common decay floor at the service's own rate, so attack and release settings show through.

## 1.0.0 — 2026-08-13

First public release.
