-- Nixpkgs PR Tracker — headless [[service]] (the polling + notification engine).
--
-- Runs for the whole Noctalia session with no UI, so notifications fire even when
-- the bar widget is not placed. It:
--   1. reads the plugin settings (prs / target_branch / poll_interval),
--   2. polls https://nixpk.gs/pr-tracker.html?pr=<N> for each PR on an interval,
--   3. parses the server-rendered HTML tree to learn which branches each PR has
--      reached, and notifies exactly once per PR when it reaches the target branch,
--   4. publishes a "status" snapshot on the shared state channel for the widget,
--   5. listens on the "command" channel for a manual "refresh" from the widget.
--
-- Data source: nixpk.gs is Alyssa Ross's `pr-tracker` (git.qyliss.net/pr-tracker).
-- There is NO JSON API — the page is fully server-side rendered HTML. The branch
-- tree is a nested <ol>/<ul>; each entry is `<span class="state-STATE">…</span>
-- <a …>BRANCHNAME</a>` where STATE is accepted | pending | unknown | rejected.
-- "Reached branch X" == the <a> whose text is X has state "accepted". See
-- samples/pr-530302.html for a captured response.

-----------------------------------------------------------------------------
-- Config
-----------------------------------------------------------------------------

local TRACKER_URL = "https://nixpk.gs/pr-tracker.html?pr="
local MIN_INTERVAL = 60 -- seconds; floor regardless of what the setting says

local function cfgString(key, fallback)
  local v = noctalia.getConfig(key)
  if type(v) == "string" and v ~= "" then
    return v
  end
  return fallback
end

local function targetBranch()
  return cfgString("target_branch", "nixos-unstable")
end

local function pollSeconds()
  local v = tonumber(noctalia.getConfig("poll_interval")) or 600
  if v < MIN_INTERVAL then
    v = MIN_INTERVAL
  end
  return math.floor(v)
end

-- Parse the comma-separated PR setting into a deduplicated list of numbers.
-- Each token may be a bare number, "#530302", or a full GitHub PR URL — we just
-- take the first run of digits in each comma-delimited field.
local function parsePrList(s)
  local out, seen = {}, {}
  for token in (s or ""):gmatch("[^,]+") do
    local digits = token:match("%d+")
    if digits then
      local n = tonumber(digits)
      if n and not seen[n] then
        seen[n] = true
        table.insert(out, n)
      end
    end
  end
  return out
end

-----------------------------------------------------------------------------
-- Persistence: the "already notified" set survives reloads and restarts.
-- Stored under XDG_STATE_HOME so it works even if the plugin is installed into a
-- read-only path (e.g. the Nix store via home-manager).
-----------------------------------------------------------------------------

local function stateDir()
  local base = noctalia.getenv("XDG_STATE_HOME")
  if not base or base == "" then
    base = `{noctalia.getenv("HOME") or "/tmp"}/.local/state`
  end
  return `{base}/noctalia/nixos-tracker`
end

local NOTIFIED_FILE = `{stateDir()}/notified.json`

-- Key a notification by PR *and* target branch, so changing the target re-arms
-- notifications for the new branch without losing history for the old one.
local function notifyKey(pr, target)
  return `{pr}@{target}`
end

local notified = {} -- set: notifyKey -> true

local function loadNotified()
  notified = {}
  local ok, raw = pcall(noctalia.readFile, NOTIFIED_FILE)
  if not ok or type(raw) ~= "string" or raw == "" then
    return
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) == "table" then
    -- stored as an array of keys
    for _, key in decoded do
      if type(key) == "string" then
        notified[key] = true
      end
    end
  end
end

local function saveNotified()
  local arr = {}
  for key in notified do
    table.insert(arr, key)
  end
  -- Best-effort: never let a write failure crash the poller.
  pcall(noctalia.runAsync, `mkdir -p '{stateDir()}'`)
  local ok, err = pcall(function()
    noctalia.writeFile(NOTIFIED_FILE, noctalia.json.encode(arr))
  end)
  if not ok then
    noctalia.log(`nixos-tracker: could not persist notified set: {err}`)
  end
end

-----------------------------------------------------------------------------
-- HTML parsing
-----------------------------------------------------------------------------

-- Returns { found, prState, title, branches } for a tracker page body.
--   found    : false when nixpk.gs reports "No such nixpkgs PR".
--   prState  : state of the PR node itself (accepted = merged to master,
--              rejected = closed unmerged, pending/unknown otherwise).
--   title    : PR title text, or nil.
--   branches : map of branch name -> state string.
local function parseTracker(body)
  body = body or ""

  if body:find("No such nixpkgs PR", 1, true) then
    return { found = false }
  end

  local title = body:match('<title>Nixpkgs PR #%d+ %("(.-)"%) progress</title>')

  -- Each tree node renders as: state span immediately followed by an anchor.
  -- The first node is the PR itself (anchor text "#<number>"); the rest are
  -- branches (anchor text is the branch name).
  local prState = nil
  local branches = {}
  local sawPrNode = false

  for state, name in body:gmatch('state%-(%a+)".-<a[^>]->([^<]*)</a>') do
    if name:sub(1, 1) == "#" then
      if not sawPrNode then
        prState = state
        sawPrNode = true
      end
    else
      branches[name] = state
    end
  end

  if not sawPrNode and next(branches) == nil then
    -- Neither a PR node nor any branch: the page shape changed or was empty.
    return { found = false, parseError = true }
  end

  return { found = true, prState = prState, title = title, branches = branches }
end

-----------------------------------------------------------------------------
-- Polling
-----------------------------------------------------------------------------

local results = {} -- pr (number) -> result table (see makeStatus)
local pollInProgress = false
local lastCheckedStr = ""

local function nowHHMM()
  local s = noctalia.formatTime("%H:%M")
  return if type(s) == "string" then s else ""
end

-- Build and publish the aggregate snapshot the widget mirrors.
local function publishStatus()
  local target = targetBranch()
  local order = parsePrList(cfgString("prs", ""))

  local merged, errors = 0, 0
  local list = {}
  for _, pr in order do
    local r = results[pr]
    if r then
      if r.reached then
        merged += 1
      end
      if r.error then
        errors += 1
      end
      table.insert(list, r)
    else
      table.insert(list, { pr = pr, pending = true })
    end
  end

  noctalia.state.set("status", {
    target = target,
    total = #order,
    merged = merged,
    errors = errors,
    checking = pollInProgress,
    lastChecked = lastCheckedStr,
    prs = list,
  })
end

-- Handle one PR's HTTP response: update its result, fire a one-time notification
-- if it just reached the target branch, then republish status.
local function handleResponse(pr, target, res)
  local result = { pr = pr }

  if type(res) ~= "table" then
    result.error = "no response"
  elseif not res.ok and (res.body == nil or res.body == "") then
    result.error = "network error"
  else
    local body = res.body or ""
    if (res.status == 404) or body:find("No such nixpkgs PR", 1, true) then
      result.error = "not found / deleted"
      result.found = false
    else
      local ok, parsed = pcall(parseTracker, body)
      if not ok or type(parsed) ~= "table" then
        result.error = "parse error"
      elseif not parsed.found then
        result.error = if parsed.parseError then "parse error" else "not found / deleted"
        result.found = false
      else
        result.found = true
        result.title = parsed.title
        result.prState = parsed.prState
        result.branchState = parsed.branches[target]
        result.reached = (result.branchState == "accepted")
        result.closed = (parsed.prState == "rejected") and not result.reached
      end
    end
  end

  results[pr] = result

  if result.error then
    noctalia.log(`nixos-tracker: PR #{pr}: {result.error}`)
  end

  -- Notify exactly once per (pr, target) when the target branch is reached.
  if result.reached then
    local key = notifyKey(pr, target)
    if not notified[key] then
      notified[key] = true
      saveNotified()
      local title = result.title or `PR #{pr}`
      noctalia.notify(`Nixpkgs PR #{pr} reached {target}`, title)
    end
  end

  publishStatus()
end

-- Poll every configured PR. Concurrent HTTP requests; a shared counter publishes
-- the final snapshot once they have all landed.
local function pollAll()
  if pollInProgress then
    return
  end

  local target = targetBranch()
  local prs = parsePrList(cfgString("prs", ""))

  -- Drop results for PRs no longer in the list.
  local keep = {}
  for _, pr in prs do
    keep[pr] = true
  end
  for pr in results do
    if not keep[pr] then
      results[pr] = nil
    end
  end

  if #prs == 0 then
    publishStatus()
    return
  end

  pollInProgress = true
  publishStatus() -- reflect "checking" immediately

  local pending = #prs
  local function settle()
    pending -= 1
    if pending <= 0 then
      pollInProgress = false
      lastCheckedStr = nowHHMM()
      publishStatus()
    end
  end

  for _, pr in prs do
    local url = TRACKER_URL .. tostring(pr)
    local ok = pcall(function()
      noctalia.http({ url = url }, function(res)
        local hok, herr = pcall(handleResponse, pr, target, res)
        if not hok then
          noctalia.log(`nixos-tracker: handler error for PR #{pr}: {herr}`)
        end
        settle()
      end)
    end)
    if not ok then
      -- http() itself failed to dispatch; record and settle so we don't hang.
      results[pr] = { pr = pr, error = "request failed to start" }
      noctalia.log(`nixos-tracker: could not start request for PR #{pr}`)
      settle()
    end
  end
end

-----------------------------------------------------------------------------
-- Lifecycle
-----------------------------------------------------------------------------

loadNotified()
noctalia.setUpdateInterval(pollSeconds() * 1000)

-- Manual refresh: the widget writes { action = "refresh" } (or the string
-- "refresh") to the shared "command" channel.
noctalia.state.watch("command", function(cmd)
  local action = if type(cmd) == "table" then cmd.action else cmd
  if action == "refresh" then
    pollAll()
  end
end)

-- Keep the tick rate in sync if the interval setting changes at runtime.
local currentInterval = pollSeconds()

function update()
  local want = pollSeconds()
  if want ~= currentInterval then
    currentInterval = want
    noctalia.setUpdateInterval(want * 1000)
  end
  pollAll()
end

-- Poll immediately on load / reload / restart instead of waiting a full interval.
pcall(pollAll)
