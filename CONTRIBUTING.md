# Sharing a StripTease preset

Built a panel you are proud of? Share it: once accepted, it is listed in
[Community/](Community/) and every StripTease user can install it from ReaPack.

A preset is an **FX chain** (`.RfxChain`): the StripTease panel together with the plugin it
drives. Its Direct Links are rebuilt automatically when someone else loads it.

## 1. Save your chain in REAPER

1. On the track, open the FX window with the StripTease panel and its plugin.
2. Select the panel and the plugin (Ctrl/Cmd-click), right-click them, then
   **Save selected FX as chain...**. If the plugin sits in a container, select the container
   and the panel.
3. Load the chain on an **empty track** and check that the controls move the plugin.

A panel on its own, without any plugin, is welcome too: it is a *Panel only* preset.

## 2. Name the file

```
StripTease <Plugin> - <Author>.RfxChain
```

| Example | |
| --- | --- |
| `StripTease Pro-C 3 - Jane.RfxChain` | Jane's panel for FabFilter Pro-C 3 |
| `StripTease UADx 1176 - JohnDoe.RfxChain` | JohnDoe's panel for the UADx 1176 |
| `StripTease Panel only - Jane.RfxChain` | Jane's panel with no plugin |

- Always start with `StripTease ` (no hyphen), like the chains that come with StripTease.
- `<Plugin>` is the plugin the panel drives (`Panel only` when there is none), `<Author>` is
  your name or nickname.
- Exactly one ` - ` separator (space, hyphen, space): no ` - ` inside the names themselves.
- None of these characters: `< > : " / \ | ? *`
- One preset per plugin and per author: to improve yours, upload it again under the same
  name and it replaces the previous one.

## 3. Send it

**On GitHub, no git knowledge needed**

1. Open the [Community/](Community/) folder and click **Add file > Upload files**.
2. Drop your `.RfxChain` file(s), then **Propose changes**. GitHub copies the project to
   your account and prepares the pull request.
3. Fill in the form and click **Create pull request**.

**Without a GitHub pull request:** open an issue with the
[Share a preset](https://github.com/ericdevcire/StripTease/issues/new?template=preset-submission.yml) form and attach your chain,
zipped.

## 4. Automatic checks

Each pull request is checked automatically. The check fails, with an explanation, when:

- it changes anything other than new or updated `.RfxChain` files directly in `Community/`;
- the file name does not follow the rule above;
- the chain holds no StripTease panel, or the panel does not point to
  `StripTease/StripTease Panel NNN px` (the standard ReaPack install);
- a *Panel only* preset contains a plugin, or a preset named after a plugin contains none;
- the chain is larger than 1 MB, is truncated, or refers to a file on your disk
  (sample, impulse response...).

Fix the file, upload it again to the same pull request, and the check runs again.

Want to check before sending? From a copy of the repository:

```
python3 .github/scripts/community.py validate
```

## 5. After review

The maintainer loads every preset in REAPER before merging it. Once it is merged, the catalog and the
**StripTease Community Presets** ReaPack package update by themselves within a few minutes.

## Rights

By submitting a preset, you confirm that you created it and you accept its distribution with
StripTease under the *Contributions* section of [licence.md](licence.md). A preset stores
plugin settings, never the plugin itself: users still need their own licensed copy.
