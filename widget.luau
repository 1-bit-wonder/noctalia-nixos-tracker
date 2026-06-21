-- Nixpkgs PR Tracker — bar [[widget]] (thin presentation client).
--
-- All polling and notification logic lives in the [[service]] (background.luau),
-- which runs for the whole session. This widget only:
--   * mirrors the service's published "status" (compact merged/total + tooltip + icon),
--   * triggers a manual refresh by writing to the "command" channel on left click.
--
-- Because the work is in the service, notifications keep firing even if this widget
-- is never placed on the bar.

local GLYPH_DEFAULT = "git-pull-request"
local GLYPH_DONE = "git-merge"
local GLYPH_ERROR = "alert-triangle"
local GLYPH_EMPTY = "git-pull-request"

-- Ask the background service to poll right now. state.watch only fires when the
-- published value changes, so attach a changing nonce — otherwise a second
-- identical "refresh" click would be a no-op.
local refreshNonce = 0
local function requestRefresh()
  refreshNonce += 1
  noctalia.state.set("command", {
    action = "refresh",
    n = refreshNonce,
    t = noctalia.formatTime("%H:%M:%S"),
  })
end

-- One tooltip line per tracked PR.
local function prLine(p)
  local pr = p.pr
  if p.pending then
    return `#{pr}: checking…`
  elseif p.reached then
    return `✓ #{pr} reached — {p.title or ""}`
  elseif p.closed then
    return `✗ #{pr} closed unmerged — {p.title or ""}`
  elseif p.error then
    return `⚠ #{pr}: {p.error}`
  else
    local where = p.branchState or "not yet"
    return `… #{pr} ({where}) — {p.title or ""}`
  end
end

local function buildTooltip(status)
  local lines = {}

  if not status or status.total == 0 then
    table.insert(lines, "Nixpkgs PR Tracker")
    table.insert(lines, "No PRs configured.")
    table.insert(lines, "Set them in Settings → Plugins → Nixpkgs PR Tracker.")
    return table.concat(lines, "\n")
  end

  local header = `Target: {status.target}  —  {status.merged}/{status.total} reached`
  if status.errors and status.errors > 0 then
    header ..= `  ({status.errors} error(s))`
  end
  table.insert(lines, header)

  for _, p in status.prs do
    table.insert(lines, prLine(p))
  end

  if status.checking then
    table.insert(lines, "")
    table.insert(lines, "Refreshing…")
  elseif status.lastChecked and status.lastChecked ~= "" then
    table.insert(lines, "")
    table.insert(lines, `Last checked {status.lastChecked} — click to refresh`)
  end

  return table.concat(lines, "\n")
end

local function applyStatus(status)
  barWidget.setVisible(true)

  if not status or status.total == 0 then
    barWidget.setGlyph(GLYPH_EMPTY)
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setText("—")
    barWidget.setColor("on_surface_variant")
    barWidget.setTooltip(buildTooltip(status))
    return
  end

  barWidget.setText(`{status.merged}/{status.total}`)

  if status.errors and status.errors > 0 then
    barWidget.setGlyph(GLYPH_ERROR)
    barWidget.setGlyphColor("error")
    barWidget.setColor("error")
  elseif status.merged == status.total then
    barWidget.setGlyph(GLYPH_DONE)
    barWidget.setGlyphColor("primary")
    barWidget.setColor("primary")
  else
    barWidget.setGlyph(GLYPH_DEFAULT)
    barWidget.setGlyphColor(if status.checking then "primary" else "on_surface")
    barWidget.setColor("on_surface")
  end

  barWidget.setTooltip(buildTooltip(status))
end

function onClick()
  requestRefresh()
end

-- Called on the widget's own tick. State-driven rendering does the real work, so
-- keep this slow; it just guarantees an initial paint if status arrives late.
function update()
  noctalia.setUpdateInterval(5000)
  applyStatus(noctalia.state.get("status"))
end

-- Paint current status on load, then track every change the service publishes.
applyStatus(noctalia.state.get("status"))
noctalia.state.watch("status", applyStatus)
