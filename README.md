# Nixpkgs PR Tracker (Noctalia v5 plugin)

Watch one or more **nixpkgs pull requests** and get a desktop notification when
each one reaches a target branch (default `nixos-unstable`). Also shows a compact
status tile on the Noctalia bar.

Data comes from [nixpk.gs](https://nixpk.gs/pr-tracker.html) (Alyssa Ross's
`pr-tracker`). NixOS-friendly: never writes into its own (possibly read-only)
plugin directory.

---

## How it works

| Piece | File | Role |
|-------|------|------|
| Background service | `background.luau` | Polls nixpk.gs on an interval, parses each PR's branch tree, and fires a **one-time** notification per PR when it reaches the target branch. Runs for the whole session. |
| Bar widget | `widget.luau` | Thin presentation tile: shows `merged/total`, a per-PR tooltip and an icon; left-click triggers a manual refresh. |

**Why a service, not widget-only?** Noctalia's `[[service]]` entry runs headless
for the entire session, independent of whether any widget is placed on the bar.
The official `screen_recorder` plugin uses exactly this split. Putting the polling
+ notification logic in the service means **notifications fire even when the
widget isn't visible / isn't added to your bar**, which is what you asked for. The
widget is a pure mirror of the service's published `status` and drives a manual
refresh through the shared `command` channel.

### Data source

There is **no JSON API**. `https://nixpk.gs/pr-tracker.html?pr=<N>` is Alyssa
Ross's [`pr-tracker`](https://git.qyliss.net/pr-tracker) and returns **fully
server-side-rendered HTML** — no client-side JS, no XHR/fetch to intercept. The
plugin requests that URL and parses the nested branch tree directly. Each node is:

```html
<span class="state-accepted">✅</span>
<a href="https://hydra.nixos.org/...">nixos-unstable</a>
```

States are `accepted` (✔ reached/merged), `pending` (⚪ not yet), `unknown` (?),
`rejected` (❌ closed unmerged / will never arrive). **"Reached branch X"** means
the `<a>` whose text is `X` has class `state-accepted`. A captured sample lives in
[`samples/pr-530302.html`](samples/pr-530302.html) (and a 404 in
`samples/pr-not-found.html`), which the parser is tested against.

---

## Install

Copy this directory into Noctalia's plugin folder so the manifest sits at
`.../plugins/nixos-tracker/plugin.toml`:

```sh
# default XDG_DATA_HOME is ~/.local/share
mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}/noctalia/plugins"
cp -r . "${XDG_DATA_HOME:-$HOME/.local/share}/noctalia/plugins/nixos-tracker"
```

> **NixOS note.** If you deploy plugins via home-manager into the read-only Nix
> store, that's fine — the plugin never writes into its own directory. Its
> "already notified" state is stored under
> `${XDG_STATE_HOME:-~/.local/state}/noctalia/nixos-tracker/notified.json`,
> which stays writable across rebuilds.

Then in Noctalia:

1. **Settings → Plugins** → enable **Nixpkgs PR Tracker**.
2. **Settings → Plugins → Nixpkgs PR Tracker** → set your options (below).
3. Add the **Nixpkgs PR Tracker** widget to your bar (Bar settings / Add widget) —
   optional; notifications work without it.

`.luau` edits hot-reload automatically. Changes to `plugin.toml` are picked up on
the next config reload.

---

## Configuration

| Setting | Key | Default | Notes |
|---------|-----|---------|-------|
| Pull requests | `prs` | *(empty)* | Comma-separated. Bare numbers, `#123`, or full GitHub PR URLs all work, e.g. `530302, #528900, https://github.com/NixOS/nixpkgs/pull/527000`. |
| Target branch | `target_branch` | `nixos-unstable` | e.g. `nixos-unstable`, `nixos-unstable-small`, `nixpkgs-unstable`, `master`, `nixos-25.05`. Must match the branch label nixpk.gs shows. |
| Poll interval (seconds) | `poll_interval` | `600` | Minimum **60s** (enforced in code too). Be polite to nixpk.gs. |

### Behaviour notes

- **Notify-once:** each PR notifies a single time when it reaches the target. The
  notified set is keyed by `PR@branch` and persisted to disk, so it survives
  reloads and restarts — no duplicate pings.
- **Changing the target branch re-arms** notifications for the new branch (old
  history is kept, so switching back won't re-notify).
- **Already-merged when first added:** if you add a PR that has *already* reached
  the target, you'll get one notification on the first poll, then never again.
- **Errors are handled, never fatal:** network failure, parse failure, and
  not-found/deleted/closed PRs are logged via `noctalia.log` and surfaced in the
  widget tooltip; the poller keeps running.

### Widget

- Text: `merged/total` (e.g. `2/3`). `—` when no PRs are configured.
- Icon: `git-pull-request` normally, `git-merge` when all reached, `alert-triangle`
  on errors.
- Tooltip: per-PR status lines + last-checked time.
- **Left click:** refresh now.

---

## Verification status

Built and tested against the **real** nixpk.gs response and the **real** Noctalia
plugin API (cross-checked against the official `example` and `screen_recorder`
plugins). Done here with `luau` 0.720:

- ✅ Both scripts compile (`luau-compile`) and run clean under a mocked host.
- ✅ HTML parser tested against the captured `samples/pr-530302.html`: extracts
  title, PR state, and every branch state correctly (`nixpkgs-unstable=accepted`,
  `nixos-unstable=pending`, …).
- ✅ End-to-end service test: feeding the real sample fires **exactly one**
  notification, dedups across repeated polls, handles a 404 PR as an error, and
  publishes the correct `merged/total/errors` snapshot.

### What I could NOT verify here (please sanity-check in a live Noctalia)

I don't have a running Noctalia instance in this environment, so confirm:

1. **The plugin loads** and appears in Settings → Plugins (manifest accepted).
2. **`noctalia.http` response fields.** I rely on `res.ok` / `res.status` /
   `res.body` (taken from the official `example` plugin). The not-found path
   checks **both** `res.status == 404` *and* the `"No such nixpkgs PR"` body text,
   so it should be robust even if `res.ok`/`status` semantics differ slightly —
   but verify a real fetch returns a non-empty `res.body`.
3. **Glyph names render:** `git-pull-request`, `git-merge`, `alert-triangle`
   (Tabler icons). If one shows blank, Noctalia logs and skips unknown glyphs;
   just swap the name at the top of `widget.luau`.
4. **Theme color names** (`primary`, `error`, `on_surface`, `on_surface_variant`)
   — copied from the official `screen_recorder` widget, so should be valid.
5. **Top-of-load poll:** the service polls immediately on load (wrapped in
   `pcall`) and also on each `update()` tick, so even if load-time HTTP were
   restricted, the first interval tick still polls.
6. **Manual refresh:** click the widget and confirm the tooltip's "Last checked"
   time updates (a nonce is attached to each refresh command so repeated identical
   clicks still register).

### Quick manual test

1. Set `prs = 530302` and `target_branch = nixpkgs-unstable` (this PR has already
   reached `nixpkgs-unstable`), interval `60`.
2. Enable the plugin → within a minute you should get one notification:
   *"Nixpkgs PR #530302 reached nixpkgs-unstable"*. Widget shows `1/1` with the
   merge icon.
3. Reload Noctalia → you should **not** get the notification again.
4. Set `target_branch = nixos-unstable` (not yet reached as of the sample) and add
   a fresh PR → widget should show it as pending until it lands.
5. Check `${XDG_STATE_HOME:-~/.local/state}/noctalia/nixos-tracker/notified.json`
   — it should contain the keys you've been notified for.
6. Watch Noctalia's logs for any `nixos-tracker:` lines if something misbehaves.
