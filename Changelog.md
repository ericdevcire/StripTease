# Changelog

All notable changes to StripTease, newest version first. Version numbers match the entries ReaPack shows.

## 1.1.1 — 2026-08-18

**A gain-reduction readout is converted to real decibels, instead of being trusted blind.** When a compressor exposes its reduction as an ordinary parameter, StripTease used to publish that parameter's value as if it were already in dB — the only test was that its range spanned more than 1.5. A readout graduated 0..100, which is a percentage of the plugin's own meter and not decibels, sailed through that test and drove the needle as a hundred dB. That is where the disagreement between the needle and the plugin's own meter came from, and why it took a different amount of trim on every plugin. StripTease now asks the plugin what it would display at each end of the readout's travel — a read-only question, the same one already used to vet a makeup control — and derives the conversion from the answer. A readout whose unit still cannot be established is refused outright rather than published in the wrong scale: the plugin then falls back to being measured by the panel, which compares two levels in dB and cannot get the scale wrong. Readouts already learned on earlier versions are re-examined the same way, so a plugin that was learned crooked is corrected without anything to reset.

**The dB is read from the label, not from the first number in it.** A readout displaying `4.0:1  -6.0 dB` published the ratio, and `1: -3.2 dB` published the channel number. The number attached to the dB unit is now the one taken, with a decimal comma, a Unicode minus and `-inf` all understood.

**`StripTease Check.lua` says what it reads and why.** Each plugin's line now names its route the same way — native, parameter, or measured — and, for a parameter, the mode, the scale factor applied, and the string the plugin itself displays. A readout that was refused says so and says what it read instead of decibels. When the makeup is estimated rather than read, the report now states that the resulting error is an offset that moves with the programme, that no trim can correct it, and which question to answer to remove it.

**The GR meter's calibration screw is a sensitivity, not an offset.** Adding dB on the screw used to be added to the reading, which pushed the whole scale up: with +3 dB, the slightest compression pinned the needle at 3 and it never came back down, and the bottom of the dial was lost. The screw now moves the top of the scale instead — +3 dB means full deflection is reached 3 dB earlier, −3 dB the opposite. Zero reduction stays the resting position whatever the trim, so the dial always reads from 0 to the top of its scale. Level meters (`IN` / `OUT`) keep the offset trim, which is what a dial calibrated in dBFS expects.

**A smoother needle.** The rise was instantaneous: the needle planted itself on every value it was handed, and since the source publishes in bursts — 30 Hz on the track-meter route, the audio block otherwise — it shivered in place. Both directions now go through the same one-pole filter, the rise still clearly quicker than the fall, the way a console VU behaves. Peak hold keeps its instant detection: showing the transient the needle smooths over is its job.

**The calibration screw goes wider: ±20 dB instead of ±6**, still in 0.5 dB steps, still zeroed by a double-click. On a GR meter the deflection now doubles every 10 dB of screw — +10 reads twice as far, +20 four times, −10 half. A sensitivity does little near the bottom of the dial, which is where a gain-reduction needle spends most of its life: at 3 dB of reduction the old ±10 bought a seventh of the dial, where ±20 buys nearly half. The law also lost its edge — the previous one moved the top of the scale closer and ran to infinity as the screw reached it, so it could not be opened up any further; this one climbs by the same step everywhere.

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
