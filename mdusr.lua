-- mdusr
-- Machinedrum USR machine loader
-- + SysEx backup/restore
--
-- E1 page   E2 scroll   E3 option
-- K2 back   K3 select / send
-- machine list: E3 right/left
-- adds/removes it from the
-- collection (send all at once)
--
-- page 1 LOAD: browse machines
-- from the listed sites, send
-- the .syx to the Machinedrum.
-- page 2 BACKUP: request/capture
-- dumps, save, restore.

local json = include("lib/json")
local text = include("lib/text")
local sysex = include("lib/sysex")
local net = include("lib/net")
local sources = include("lib/sources")

local DATA = _path.data .. "mdusr/"
local CACHE = DATA .. "cache/"
local BACKUPS = DATA .. "backups/"
local LOCAL = DATA .. "local/"

local md -- midi device
local dirty = true
local page = 1
local toast, toast_t = nil, 0

-- ---------------------------------------------------------------- state
local idx = {}        -- source id -> index table
local busy = nil      -- string while a background job runs
local L = { level = "sources", sel = { sources = 1, cats = 1, machines = 1 }, scroll = 0, file = 1 }
local send = { active = false, abort = false, done = 0, total = 0, msg = 0, msgs = 0, label = "", result = nil }
local B = { sel = 1, listen = false, capture = {}, kit = 0, pattern = 0, song = 0, global = 0,
  files = {}, fsel = 1, level = "menu", full = nil, waiting = nil, last = "" }
local pending = nil   -- prepared file waiting for confirm: { msgs, bytes, label, back }

local function say(s, secs) toast = s; toast_t = util.time() + (secs or 2.5); dirty = true end

local function mkdirs()
  for _, d in ipairs({ DATA, CACHE, BACKUPS, LOCAL }) do util.make_dir(d) end
end

local function exists(p) local f = io.open(p, "rb"); if f then f:close(); return true end return false end

local function write_text(p, s) local f = io.open(p, "wb"); if f then f:write(s); f:close(); return true end end

local function read_text(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("a"); f:close(); return s end

-- ---------------------------------------------------------------- sources
local function source_list()
  local list = {}
  for _, s in ipairs(sources) do list[#list + 1] = s end
  list[#list + 1] = { id = "local", name = "Local files", home = LOCAL }
  return list
end

local function load_local_index()
  local ms = {}
  for _, f in ipairs(util.scandir(LOCAL) or {}) do
    if f:lower():match("%.syx$") then
      ms[#ms + 1] = { name = f:gsub("%.[Ss][Yy][Xx]$", ""), title = "", category = "Local",
        desc = "File in dust/data/mdusr/local/", sort = #ms + 1, extra = {},
        files = { { label = f, path = LOCAL .. f, filename = f } } }
    end
  end
  idx["local"] = { machines = ms, notes = { "Copy .syx files to dust/data/mdusr/local/" }, updated = os.time() }
end

local function load_cache()
  for _, s in ipairs(sources) do
    local body = read_text(CACHE .. "index_" .. s.id .. ".json")
    if body then idx[s.id] = json.decode(body) end
  end
  load_local_index()
end

local function make_env(s)
  local dir = CACHE .. s.id .. "/"
  util.make_dir(dir)
  return {
    dir = dir,
    get = function(url) return net.get(url, CACHE) end,
    get_file = net.get_file,
    unzip_list = net.unzip_list,
    unzip_read = function(z, m) return net.unzip_read(z, m, CACHE) end,
  }
end

-- refresh status per source while a refresh runs: "wait" | "get" | "ok" | "fail"
local R = { active = false, state = {}, t0 = 0 }

local function log(line)
  local f = io.open(DATA .. "refresh.log", "a")
  if f then f:write(os.date("%Y-%m-%d %H:%M:%S ") .. line .. "\n"); f:close() end
  print("mdusr: " .. line)
end

local function refresh_one(s)
  if s.id == "local" then load_local_index(); R.state[s.id] = "ok"; return true end
  R.state[s.id] = "get"
  dirty = true
  local t0 = util.time()
  local ok, res, err = pcall(s.load, make_env(s))
  if ok and res then
    res.updated = os.time()
    table.sort(res.machines, function(a, b) return (a.sort or 0) < (b.sort or 0) end)
    idx[s.id] = res
    write_text(CACHE .. "index_" .. s.id .. ".json", json.encode(res))
    R.state[s.id] = "ok"
    local nf = 0
    for _, m in ipairs(res.machines) do nf = nf + #m.files end
    log(("%s: ok, %d machines, %d files, %.1fs"):format(s.name, #res.machines, nf, util.time() - t0))
    for _, n in ipairs(res.notes or {}) do if n:find("failed") then log("  " .. n) end end
  else
    local msg = tostring(ok and err or res)
    local old = idx[s.id] or { machines = {}, notes = {} }
    old.error = msg
    idx[s.id] = old
    R.state[s.id] = "fail"
    log(("%s: FAILED (%s), cached list kept"):format(s.name, msg))
  end
  dirty = true
  return R.state[s.id] == "ok"
end

local function refresh(list)
  if busy then return say("busy: " .. busy) end
  R.active, R.state, R.t0 = true, {}, util.time()
  busy = "refreshing"
  for _, s in ipairs(list) do R.state[s.id] = "wait" end
  log("refresh started (" .. #list .. " sources)")
  local left = #list
  local okn, failn = 0, 0
  -- every source fetches in parallel; the slowest decides the total time
  for _, s in ipairs(list) do
    clock.run(function()
      if refresh_one(s) then okn = okn + 1 else failn = failn + 1 end
      left = left - 1
    end)
  end
  clock.run(function()
    while left > 0 do
      busy = ("refreshing %d/%d  %ds"):format(#list - left, #list, math.floor(util.time() - R.t0))
      dirty = true
      clock.sleep(0.25)
    end
    busy = nil
    R.active = false
    local summary = failn == 0 and ("refresh ok: %d sources"):format(okn)
      or ("%d ok, %d FAILED (data/mdusr/refresh.log)"):format(okn, failn)
    log(summary .. (" in %.1fs"):format(util.time() - R.t0))
    say(summary, 5)
  end)
end

-- categories of a source in first-seen order
local function categories(sid)
  local cats, seen = {}, {}
  for _, m in ipairs((idx[sid] or {}).machines or {}) do
    if not seen[m.category] then seen[m.category] = true; cats[#cats + 1] = m.category end
  end
  return cats
end

-- one row per .syx file: machines with several variants get a row each
local function variant_name(f)
  local n = (f.label or f.filename or "?"):gsub("%s*%(.*$", ""):gsub("%.[Ss][Yy][Xx]$", "")
  return n
end

local function machines_in(sid, cat)
  local out = {}
  for _, m in ipairs((idx[sid] or {}).machines or {}) do
    if cat == nil or m.category == cat then
      if #(m.files or {}) <= 1 then
        out[#out + 1] = { m = m, fi = 1, name = m.name }
      else
        for fi, f in ipairs(m.files) do
          out[#out + 1] = { m = m, fi = fi, name = variant_name(f) }
        end
      end
    end
  end
  return out
end

-- ---------------------------------------------------------------- sending
local function wire_sleep(nbytes)
  local rate = params:get("rate")
  clock.sleep(nbytes / rate)
end

-- send one or more files, paced. jobs = { {label=, msgs=, bytes=}, ... }
-- Runs inside a clock coroutine.
local function send_jobs(jobs)
  if not md then say("no MIDI device"); return false end
  local total = 0
  for _, j in ipairs(jobs) do total = total + j.bytes end
  send.active, send.abort, send.done, send.total, send.result = true, false, 0, total, nil
  send.file, send.files, send.wait_next = 0, #jobs, false
  dirty = true
  local chunk = params:get("chunk")
  local gap = params:get("gap") / 1000
  for fi, j in ipairs(jobs) do
    send.file, send.label, send.msg, send.msgs = fi, j.label, 0, #j.msgs
    if fi > 1 then
      if params:get("between") == 2 then
        -- wait for K3 so a new MACHINE MGR slot can be armed
        send.wait_next = true
        dirty = true
        while send.wait_next and not send.abort do clock.sleep(0.05) end
      else
        clock.sleep(params:get("file_gap") / 1000)
      end
    end
    if send.abort then break end
    local file_done = 0
    for i, m in ipairs(j.msgs) do
      send.msg = i
      for a = 1, #m, chunk do
        if send.abort then break end
        local b = math.min(a + chunk - 1, #m)
        local part = { table.unpack(m, a, b) }
        md:send(part)
        send.done = send.done + #part
        file_done = file_done + #part
        dirty = true
        wire_sleep(#part)
      end
      if send.abort then
        -- never leave the MD inside an open SysEx: close it
        if file_done < j.bytes then md:send({ 0xF7 }) end
        break
      end
      if i < #j.msgs and gap > 0 then clock.sleep(gap) end
    end
    if send.abort then break end
  end
  send.result = send.abort and "aborted" or "done"
  send.sent_files = send.abort and (send.file - 1) or send.files
  send.active, send.wait_next = false, false
  dirty = true
  return not send.abort
end

-- read + validate a .syx file -> job or nil, err
local function load_job(path, label)
  local data, e = sysex.read_file(path)
  if not data then return nil, "read failed: " .. tostring(e) end
  local r = sysex.split(data)
  if #r.msgs == 0 then return nil, "no SysEx in " .. label end
  return { msgs = r.msgs, bytes = r.bytes, label = label, errors = r.errors,
    elektron = sysex.is_elektron(r.msgs[1]) }
end

local function set_pending(jobs, back)
  local p = { jobs = jobs, back = back, bytes = 0, nmsgs = 0, errors = 0, elektron = true }
  for _, j in ipairs(jobs) do
    p.bytes = p.bytes + j.bytes
    p.nmsgs = p.nmsgs + #j.msgs
    p.errors = p.errors + #j.errors
    p.elektron = p.elektron and j.elektron
  end
  p.label = #jobs == 1 and jobs[1].label or (#jobs .. " files")
  pending = p
  dirty = true
end

local function prepare_path(path, label, back)
  local j, e = load_job(path, label)
  if not j then return say(e) end
  set_pending({ j }, back)
end

-- make sure a machine file is on disk (download/extract). In a coroutine.
local function ensure_local(sid, f)
  if f.path then return f.path end
  local dir = CACHE .. sid .. "/"
  util.make_dir(dir)
  local path = dir .. text.safe(f.filename or text.basename(f.url or f.zip_member or "x.syx"))
  if exists(path) then return path end
  busy = "downloading " .. (f.filename or "")
  dirty = true
  local ok, e
  if f.zip_member then
    if not exists(f.zip) then busy = nil; return nil, "zip missing: refresh source" end
    ok, e = net.unzip_extract(f.zip, f.zip_member, path)
  else
    ok, e = net.get_file(f.url, path)
  end
  busy = nil
  dirty = true
  if not ok then return nil, "offline? " .. tostring(e) end
  return path
end

local function prepare_file(sid, f, back)
  if busy then return say("busy: " .. busy) end
  clock.run(function()
    local path, e = ensure_local(sid, f)
    if not path then return say(e, 3) end
    prepare_path(path, f.filename or text.basename(path), back)
  end)
end

local function est_seconds(p)
  local gap = params:get("gap") / 1000
  local s = p.bytes / params:get("rate") + gap * math.max(0, p.nmsgs - #p.jobs)
  if params:get("between") == 1 then s = s + params:get("file_gap") / 1000 * (#p.jobs - 1) end
  return s
end

-- ---------------------------------------------------------------- collection
local C = { items = {}, sel = 1 }
local COLL_FILE = DATA .. "collection.json"

local function coll_key(sid, f) return sid .. ":" .. (f.filename or f.url or "?") end

local function coll_find(key)
  for i, it in ipairs(C.items) do if it.key == key then return i end end
end

local function coll_save() write_text(COLL_FILE, json.encode(C.items)) end

local function coll_load()
  local t = json.decode(read_text(COLL_FILE) or "")
  C.items = type(t) == "table" and t or {}
end

local function coll_set(sid, m, fi, on)
  local f = m.files[fi]
  if not f then return say("no .syx for " .. m.name) end
  local key = coll_key(sid, f)
  local i = coll_find(key)
  if on and not i then
    C.items[#C.items + 1] = { key = key, sid = sid, name = m.name, file = f }
    say("+ " .. (f.filename or m.name) .. " (" .. #C.items .. ")", 1.5)
  elseif not on and i then
    table.remove(C.items, i)
    say("- " .. (f.filename or m.name) .. " (" .. #C.items .. ")", 1.5)
  end
  coll_save()
end

local function row_collected(sid, row)
  local f = row.m.files[row.fi]
  return f and coll_find(coll_key(sid, f)) ~= nil
end

local function prepare_collection()
  if #C.items == 0 then return say("collection is empty") end
  if busy then return say("busy: " .. busy) end
  clock.run(function()
    local jobs = {}
    for i, it in ipairs(C.items) do
      busy = ("preparing %d/%d"):format(i, #C.items)
      dirty = true
      local path, e = ensure_local(it.sid, it.file)
      if not path then busy = nil; return say(it.name .. ": " .. tostring(e), 3) end
      local j, je = load_job(path, it.file.filename or it.name)
      if not j then busy = nil; return say(je, 3) end
      jobs[#jobs + 1] = j
    end
    busy = nil
    set_pending(jobs, "collection")
  end)
end

-- ---------------------------------------------------------------- backup
local function on_sysex(m)
  B.last = sysex.describe(m)
  if B.listen then
    B.capture[#B.capture + 1] = m
  end
  if B.waiting and sysex.is_md(m) and m[7] == B.waiting then B.waiting = nil end
  dirty = true
end

local asm = sysex.assembler(on_sysex)

local function on_midi(data) asm.feed(data) end

local function capture_bytes()
  local n = 0
  for _, m in ipairs(B.capture) do n = n + #m end
  return n
end

local function save_capture(prefix)
  if #B.capture == 0 then return say("nothing captured") end
  local name = (prefix or "backup") .. "_" .. os.date("%Y%m%d-%H%M%S") .. ".syx"
  local ok, e = sysex.write_file(BACKUPS .. name, B.capture)
  if ok then say("saved " .. name, 3) else say("save failed: " .. tostring(e)) end
end

-- send one request and wait for the reply (or timeout). In a coroutine.
local function request(id, value)
  B.listen = true
  B.waiting = id - 1 -- reply id is request id - 1 for global/kit/pattern/song
  md:send(sysex.md_request(id, value))
  local t, limit = 0, params:get("req_timeout")
  while B.waiting and t < limit do clock.sleep(0.02); t = t + 0.02 end
  -- let a dump that is still streaming finish
  while asm.busy() and t < limit * 3 do clock.sleep(0.02); t = t + 0.02 end
  local got = B.waiting == nil
  B.waiting = nil
  return got
end

local function full_backup()
  if not md then return say("no MIDI device") end
  if busy then return say("busy: " .. busy) end
  clock.run(function()
    local jobs = {}
    for i = 0, 7 do jobs[#jobs + 1] = { sysex.ID.GLOBAL_REQ, i } end
    for i = 0, 63 do jobs[#jobs + 1] = { sysex.ID.KIT_REQ, i } end
    for i = 0, 127 do jobs[#jobs + 1] = { sysex.ID.PATTERN_REQ, i } end
    for i = 0, 31 do jobs[#jobs + 1] = { sysex.ID.SONG_REQ, i } end
    B.capture = {}
    B.full = { done = 0, total = #jobs, missed = 0, abort = false }
    busy = "full backup"
    for _, j in ipairs(jobs) do
      if B.full.abort then break end
      if not request(j[1], j[2]) then B.full.missed = B.full.missed + 1 end
      B.full.done = B.full.done + 1
      dirty = true
    end
    busy = nil
    local aborted = B.full.abort
    local missed = B.full.missed
    B.full = nil
    if not aborted then save_capture("full") end
    say(("%s, %d no reply"):format(aborted and "aborted" or "full backup saved", missed), 4)
  end)
end

local function scan_backups()
  B.files = {}
  for _, f in ipairs(util.scandir(BACKUPS) or {}) do
    if f:lower():match("%.syx$") then B.files[#B.files + 1] = f end
  end
  table.sort(B.files, function(a, b) return a > b end) -- newest first
  B.fsel = util.clamp(B.fsel, 1, math.max(1, #B.files))
end

local B_ITEMS = { "listen", "kit", "pattern", "song", "global", "full", "save", "clear", "restore" }

local function b_label(item)
  if item == "listen" then return "Listen: " .. (B.listen and "ON" or "off")
  elseif item == "kit" then return ("Request kit %02d"):format(B.kit + 1)
  elseif item == "pattern" then return "Request pattern " .. sysex.pattern_name(B.pattern)
  elseif item == "song" then return ("Request song %02d"):format(B.song + 1)
  elseif item == "global" then return ("Request global %d"):format(B.global + 1)
  elseif item == "full" then return "Full backup (all)"
  elseif item == "save" then return ("Save capture (%d)"):format(#B.capture)
  elseif item == "clear" then return "Clear capture"
  elseif item == "restore" then return "Restore a file >"
  end
end

local function b_action(item)
  if item == "listen" then B.listen = not B.listen
  elseif item == "kit" or item == "pattern" or item == "song" or item == "global" then
    if not md then return say("no MIDI device") end
    if busy then return say("busy: " .. busy) end
    local id = ({ kit = sysex.ID.KIT_REQ, pattern = sysex.ID.PATTERN_REQ,
      song = sysex.ID.SONG_REQ, global = sysex.ID.GLOBAL_REQ })[item]
    clock.run(function()
      busy = "requesting " .. item
      local ok = request(id, B[item])
      busy = nil
      say(ok and ("got " .. B.last) or "no reply (check MIDI out->in)", 3)
    end)
  elseif item == "full" then full_backup()
  elseif item == "save" then save_capture("backup")
  elseif item == "clear" then B.capture = {}; say("cleared")
  elseif item == "restore" then scan_backups(); B.level = "files"
  end
  dirty = true
end

-- ---------------------------------------------------------------- input
local function load_items()
  local list = source_list()
  if L.level == "sources" then
    local items = { { id = "_coll", name = "Collection" } }
    for _, s in ipairs(list) do items[#items + 1] = s end
    items[#items + 1] = { id = "_refresh", name = "Refresh all" }
    return items
  elseif L.level == "cats" then
    local items = { "Refresh this source" }
    for _, c in ipairs(categories(L.sid)) do items[#items + 1] = c end
    return items
  elseif L.level == "machines" then
    return machines_in(L.sid, L.cat)
  elseif L.level == "collection" then
    local items = { "_send", "_clear" }
    for _, it in ipairs(C.items) do items[#items + 1] = it end
    return items
  end
  return {}
end

local function enter_source(s)
  L.sid = s.id
  L.sname = s.name
  local cats = categories(s.id)
  if #cats <= 1 then
    L.cat = nil
    L.level = "machines"
    L.skipped_cats = true
  else
    L.level = "cats"
    L.skipped_cats = false
  end
  L.sel.cats, L.sel.machines = 1, 1
end

-- ---------------------------------------------------------------- splash / self-update
-- On start the script checks its own GitHub repo. When installed with maiden
-- (;install https://github.com/murdenihcam/mdusr) the folder is a git clone,
-- so "git fetch" tells how many commits it is behind and "git pull" updates.
local REPO = "murdenihcam/mdusr"
local SPL = { active = true, state = "checking", behind = 0, sel = 1, msg = nil, t0 = 0 }

local function script_dir()
  local p = (norns and norns.state and norns.state.path) or (_path.code .. "mdusr/")
  if p:sub(-1) ~= "/" then p = p .. "/" end
  return p
end

local function splash_items()
  local items = {}
  if SPL.state == "updated" then
    return { { id = "restart", label = "Restart norns now" }, { id = "go", label = "Later (old version runs)" } }
  end
  if SPL.state == "behind" then items[#items + 1] = { id = "update", label = ("Update script (%d new)"):format(SPL.behind) } end
  items[#items + 1] = { id = "refresh", label = "Refresh machine lists" }
  items[#items + 1] = { id = "go", label = "Continue" }
  return items
end

local function check_update()
  local dir = net.quote(script_dir())
  local out = net.run(("cd %s && git rev-parse --is-inside-work-tree 2>/dev/null && " ..
    "timeout 30 git fetch -q origin 2>/dev/null && echo FETCH_OK && " ..
    "git rev-list --count HEAD..@{u} 2>/dev/null"):format(dir), 60) or ""
  if not out:find("true", 1, true) then
    SPL.state = "nogit" -- copied by hand: cannot update in place
  elseif not out:find("FETCH_OK", 1, true) then
    SPL.state = "offline"
  else
    SPL.behind = tonumber(out:match("FETCH_OK%s+(%d+)")) or 0
    SPL.state = SPL.behind > 0 and "behind" or "current"
  end
  dirty = true
  -- nothing to decide: leave the splash on its own after a moment
  if SPL.state ~= "behind" then
    clock.sleep(1.2)
    if SPL.state ~= "behind" and SPL.active and SPL.sel == 1 then SPL.active = false end
  end
  dirty = true
end

local function do_update()
  SPL.state = "updating"
  dirty = true
  local out = net.run(("cd %s && git pull --ff-only -q 2>&1 && echo PULL_OK"):format(net.quote(script_dir())), 120) or ""
  if out:find("PULL_OK", 1, true) then
    -- new code only takes effect after a norns restart: ask for one
    SPL.state, SPL.msg, SPL.sel = "updated", "Updated! Restart needed.", 1
  else
    SPL.state, SPL.msg = "failed", "Update failed (local edits?)"
    print("mdusr update: " .. out)
  end
  dirty = true
end

local function splash_key(n)
  if n == 2 then SPL.active = false
  elseif n == 3 then
    if SPL.state == "updating" or SPL.state == "checking" then return end
    local it = splash_items()[SPL.sel]
    if not it then return end
    if it.id == "update" then clock.run(do_update)
    elseif it.id == "restart" then
      SPL.msg = "restarting norns..."
      dirty = true
      redraw()
      -- same as SYSTEM > RESET; falls back to restarting the norns services
      if norns and norns.reset then norns.reset()
      else os.execute("(sleep 1; sudo systemctl restart norns-sclang.service norns-crone.service norns-matron.service) &") end
    elseif it.id == "refresh" then SPL.active = false; refresh(source_list())
    else SPL.active = false end
  end
  dirty = true
end

function key(n, z)
  if z == 0 then return end
  if SPL.active then return splash_key(n) end
  -- global: sending / confirm screens capture keys
  if send.active then
    if n == 2 then send.abort = true; say("aborting...")
    elseif n == 3 and send.wait_next then send.wait_next = false end
    dirty = true
    return
  end
  if send.result then send.result = nil; dirty = true; return end
  if B.full then
    if n == 2 then B.full.abort = true end
    return
  end
  if pending then
    if n == 3 then
      local p = pending
      pending = nil
      clock.run(function() send_jobs(p.jobs) end)
    elseif n == 2 then
      pending = nil
    end
    dirty = true
    return
  end

  if page == 1 then
    local items = load_items()
    if n == 3 then
      if L.level == "sources" then
        local it = items[L.sel.sources]
        if it.id == "_refresh" then refresh(source_list())
        elseif it.id == "_coll" then L.level = "collection"; L.sel.collection = 1
        else enter_source(it) end
      elseif L.level == "cats" then
        if L.sel.cats == 1 then
          refresh({ (function() for _, s in ipairs(source_list()) do if s.id == L.sid then return s end end end)() })
        else
          L.cat = items[L.sel.cats]
          L.level = "machines"
          L.sel.machines = 1
        end
      elseif L.level == "machines" then
        local row = items[L.sel.machines]
        if row then L.machine = row.m; L.row = row; L.level = "detail"; L.scroll = 0; L.file = row.fi end
      elseif L.level == "detail" then
        local f = L.machine.files[L.file]
        if f then prepare_file(L.sid, f, "detail") else say("no .syx for this machine") end
      elseif L.level == "collection" then
        local it = items[L.sel.collection]
        if it == "_send" then prepare_collection()
        elseif it == "_clear" then
          if L.confirm_clear then C.items = {}; coll_save(); L.confirm_clear = false; say("collection cleared")
          else L.confirm_clear = true; say("K3 again to clear all") end
        elseif it then
          table.remove(C.items, L.sel.collection - 2)
          coll_save()
          say("removed " .. (it.file.filename or it.name))
          L.sel.collection = util.clamp(L.sel.collection, 1, #C.items + 2)
        end
      end
    elseif n == 2 then
      if L.level == "detail" then L.level = "machines"
      elseif L.level == "collection" then L.level = "sources"
      elseif L.level == "machines" then L.level = L.skipped_cats and "sources" or "cats"
      elseif L.level == "cats" then L.level = "sources" end
    end
  else
    if B.level == "files" then
      if n == 2 then B.level = "menu"
      elseif n == 3 and B.files[B.fsel] then
        prepare_path(BACKUPS .. B.files[B.fsel], B.files[B.fsel], "files")
      end
    else
      if n == 3 then b_action(B_ITEMS[B.sel]) end
    end
  end
  dirty = true
end

function enc(n, d)
  L.confirm_clear = false
  if SPL.active then
    if n == 2 then SPL.sel = util.clamp(SPL.sel + d, 1, #splash_items()) end
    dirty = true
    return
  end
  if n == 1 then
    if not send.active and not pending and not B.full then page = util.clamp(page + d, 1, 2) end
    dirty = true
    return
  end
  if pending or send.active then return end
  if page == 1 then
    if L.level == "detail" then
      if n == 2 then L.scroll = math.max(0, L.scroll + d)
      elseif n == 3 then
        -- E3 right = add this file to the collection, left = remove
        coll_set(L.sid, L.machine, L.file, d > 0)
      end
    elseif n == 3 and L.level == "machines" then
      -- E3 right = add to collection, left = remove
      local row = load_items()[L.sel.machines]
      if row then coll_set(L.sid, row.m, row.fi, d > 0) end
    elseif n == 3 and L.level == "collection" then
      -- E3 moves the selected file up/down in the send order
      local i = L.sel.collection - 2
      local j = i + (d > 0 and 1 or -1)
      if i >= 1 and j >= 1 and j <= #C.items then
        C.items[i], C.items[j] = C.items[j], C.items[i]
        L.sel.collection = j + 2
        coll_save()
      end
    elseif n == 2 then
      local items = load_items()
      local k = L.level
      L.sel[k] = util.clamp((L.sel[k] or 1) + d, 1, math.max(1, #items))
    end
  else
    if B.level == "files" then
      if n == 2 then B.fsel = util.clamp(B.fsel + d, 1, math.max(1, #B.files)) end
    else
      if n == 2 then B.sel = util.clamp(B.sel + d, 1, #B_ITEMS)
      elseif n == 3 then
        local it = B_ITEMS[B.sel]
        local max = ({ kit = 63, pattern = 127, song = 31, global = 7 })[it]
        if max then B[it] = util.clamp(B[it] + d, 0, max) end
      end
    end
  end
  dirty = true
end

-- ---------------------------------------------------------------- drawing
local W = 128

local function measure(s) return screen.text_extents(s) end

local function fit(s, w)
  s = text.ascii(s or "")
  if measure(s) <= w then return s end
  while #s > 1 and measure(s .. "~") > w do s = s:sub(1, -2) end
  return s .. "~"
end

local function header(title, right)
  screen.level(15)
  screen.move(0, 6)
  screen.text(fit(title, 92))
  if right then screen.move(W, 6); screen.text_right(right) end
  screen.level(2)
  screen.move(0, 9); screen.line(W, 9); screen.stroke()
end

local function draw_list(items, sel, label_fn, y0, rows)
  y0, rows = y0 or 18, rows or 5
  local top = util.clamp(sel - math.floor(rows / 2), 1, math.max(1, #items - rows + 1))
  for r = 0, rows - 1 do
    local i = top + r
    local it = items[i]
    if not it then break end
    local y = y0 + r * 9
    if i == sel then
      screen.level(15); screen.rect(0, y - 7, W, 9); screen.fill()
      screen.level(0)
    else
      screen.level(6)
    end
    local l, rt = label_fn(it, i)
    screen.move(2, y)
    screen.text(fit(l, rt and 96 or 124))
    if rt then screen.move(W - 2, y); screen.text_right(rt) end
  end
  if #items > rows then -- scrollbar
    local h = math.max(4, math.floor(50 * rows / #items))
    local yy = 11 + math.floor((50 - h) * (top - 1) / math.max(1, #items - rows))
    screen.level(4); screen.rect(W - 1, yy, 1, h); screen.fill()
  end
end

local function progress(y, frac, label)
  screen.level(3); screen.rect(4, y, 120, 6); screen.stroke()
  screen.level(15); screen.rect(4, y, math.floor(120 * util.clamp(frac, 0, 1)), 6); screen.fill()
  if label then screen.level(8); screen.move(64, y + 15); screen.text_center(label) end
end

local function draw_send()
  local frac = send.total > 0 and send.done / send.total or 0
  if send.wait_next then
    header(("NEXT %d/%d"):format(send.file, send.files))
    screen.level(15); screen.move(0, 20); screen.text(fit(send.label, 128))
    screen.level(10)
    screen.move(0, 30); screen.text("MACHINE MGR: pick the")
    screen.move(0, 39); screen.text("next slot, arm RECV.")
    progress(43, frac)
    screen.level(4); screen.move(0, 62); screen.text("K2 stop")
    screen.level(15); screen.move(W, 62); screen.text_right("K3 SEND")
    return
  end
  header(send.files > 1 and ("SENDING %d/%d"):format(send.file, send.files) or "SENDING")
  screen.level(15); screen.move(0, 20); screen.text(fit(send.label, 128))
  screen.level(10)
  screen.move(0, 30)
  screen.text(("msg %d/%d  %d/%d B"):format(send.msg, send.msgs, send.done, send.total))
  progress(36, frac)
  screen.level(4); screen.move(0, 62); screen.text("K2 abort")
end

local function draw_result()
  header(send.result == "done" and "SENT" or "ABORTED")
  screen.level(10)
  local what = send.files > 1 and (send.files .. " files") or send.label
  local lines = send.result == "done" and {
    what .. " sent.",
    "Check the MD screen for",
    "DSP FULL / MEM FULL /",
    "BUFFER FULL (try slower).",
  } or { "Transfer stopped.", ("%d of %d files complete."):format(send.sent_files or 0, send.files),
    "The current MD slot may", "hold a partial machine." }
  for i, l in ipairs(lines) do screen.move(0, 10 + i * 9); screen.text(fit(l, 128)) end
  screen.level(4); screen.move(0, 62); screen.text("any key")
end

local function draw_confirm()
  local p = pending
  header("SEND " .. p.label)
  screen.level(10)
  local lines = {}
  if p.back == "files" then
    lines = { "Restore overwrites the", "slots stored in the dump." }
  elseif #p.jobs > 1 then
    lines = { "MACHINE MGR: pick a slot,", "arm RECV. Then K3.",
      params:get("between") == 2 and "K3 again before each file" or
        ("auto, %.1fs between files"):format(params:get("file_gap") / 1000) }
  else
    lines = { "On the MD: GLOBAL > FILE >", "MACHINE MGR, pick a slot,", "arm RECV. Then K3." }
  end
  lines[#lines + 1] = ("%d msg, %d B, ~%ds"):format(p.nmsgs, p.bytes, math.ceil(est_seconds(p)))
  local warn = {}
  if p.errors > 0 then warn[#warn + 1] = p.errors .. " broken msg skipped" end
  if not p.elektron then warn[#warn + 1] = "not Elektron SysEx" end
  if #warn > 0 then lines[#lines + 1] = "! " .. table.concat(warn, ", ") end
  for i, l in ipairs(lines) do screen.move(0, 10 + i * 9); screen.text(fit(l, 128)) end
  screen.level(4); screen.move(0, 62); screen.text("K2 cancel")
  screen.level(15); screen.move(W, 62); screen.text_right("K3 SEND")
end

local function age(t)
  if not t then return "never" end
  local d = os.time() - t
  if d < 3600 then return math.floor(d / 60) .. "m" end
  if d < 86400 then return math.floor(d / 3600) .. "h" end
  return math.floor(d / 86400) .. "d"
end

local function draw_load()
  if L.level == "sources" then
    header("LOAD", "1/2")
    draw_list(load_items(), L.sel.sources, function(s)
      if s.id == "_refresh" then return "> Refresh all" end
      if s.id == "_coll" then return "> Collection", tostring(#C.items) end
      local x = idx[s.id]
      local n = x and #(x.machines or {}) or 0
      local st = R.active and R.state[s.id]
      if st == "wait" then return s.name, "queued" end
      if st == "get" then return s.name, ("..."):sub(1, 1 + math.floor(util.time() * 3) % 3) end
      if st == "fail" then return s.name, "FAIL " .. n end
      local tag = x and x.error and "!" or ""
      return s.name, tag .. n .. " " .. age(x and x.updated)
    end)
  elseif L.level == "cats" then
    header(L.sname, "1/2")
    draw_list(load_items(), L.sel.cats, function(c, i)
      if i == 1 then return "> " .. c end
      return c, tostring(#machines_in(L.sid, c))
    end)
  elseif L.level == "machines" then
    header(L.cat or L.sname, "E3 +coll")
    local items = load_items()
    if #items == 0 then
      screen.level(6); screen.move(0, 24); screen.text("nothing cached")
      screen.move(0, 34); screen.text("K2 back, then Refresh")
      local x = idx[L.sid]
      if x and x.error then screen.move(0, 44); screen.text(fit(x.error, 128)) end
    else
      draw_list(items, L.sel.machines, function(row)
        local mark = row_collected(L.sid, row) and "* " or "  "
        local v = row.m.version
        return mark .. row.name, v and tostring(v):sub(1, 6) or nil
      end)
    end
  elseif L.level == "collection" then
    header("COLLECTION", #C.items .. " files")
    draw_list(load_items(), L.sel.collection, function(it, i)
      if it == "_send" then return "> Send all", #C.items > 0 and "K3" or nil end
      if it == "_clear" then return "> Clear all" end
      return (i - 2) .. " " .. (it.file.filename or it.name), it.sid:sub(1, 5)
    end)
  elseif L.level == "detail" then
    local m = L.machine
    local f = m.files[L.file]
    local rowname = L.row and L.row.name or m.name
    header(rowname, m.version and tostring(m.version) or nil)
    local body = {}
    if rowname ~= m.name then body[#body + 1] = "Variant of " .. m.name end
    if f and #m.files > 1 then body[#body + 1] = "File: " .. text.ascii(f.label) end
    if m.title and m.title ~= "" and m.title ~= m.name then body[#body + 1] = m.title end
    for _, l in ipairs(text.wrap(text.ascii(m.desc or ""), 124, measure)) do body[#body + 1] = l end
    for _, e in ipairs(m.extra or {}) do
      for _, l in ipairs(text.wrap(text.ascii(e), 124, measure)) do body[#body + 1] = l end
    end
    if f and f.scope then body[#body + 1] = "Scope: " .. f.scope end
    L.scroll = math.min(L.scroll, math.max(0, #body - 5))
    screen.level(10)
    for r = 1, 5 do
      local l = body[L.scroll + r]
      if l then screen.move(0, 10 + r * 9); screen.text(l) end
    end
    screen.level(2); screen.move(0, 56); screen.line(W, 56); screen.stroke()
    screen.level(15)
    screen.move(0, 63)
    if f then
      local inc = coll_find(coll_key(L.sid, f)) ~= nil
      screen.text(inc and "* E3< remove" or "E3> collect")
      screen.move(W, 63); screen.text_right("K3 send")
    else
      screen.text("no .syx found")
    end
  end
end

local function draw_backup()
  if B.level == "files" then
    header("RESTORE", "2/2")
    if #B.files == 0 then
      screen.level(6); screen.move(0, 24); screen.text("no backups yet")
      screen.move(0, 34); screen.text("dust/data/mdusr/backups/")
    else
      draw_list(B.files, B.fsel, function(f) return f end)
    end
    return
  end
  header("BACKUP", "2/2")
  if B.full then
    screen.level(10); screen.move(0, 22)
    screen.text(("request %d/%d  missed %d"):format(B.full.done, B.full.total, B.full.missed))
    progress(30, B.full.done / B.full.total, ("%d msgs  %d B"):format(#B.capture, capture_bytes()))
    screen.level(4); screen.move(0, 62); screen.text("K2 abort")
    return
  end
  draw_list(B_ITEMS, B.sel, function(it) return b_label(it) end, 18, 4)
  screen.level(2); screen.move(0, 53); screen.line(W, 53); screen.stroke()
  screen.level(5); screen.move(0, 62)
  screen.text(fit(("cap %d/%dB last:%s"):format(#B.capture, capture_bytes(), B.last), 128))
end

local function draw_splash()
  screen.level(15)
  screen.font_size(16)
  screen.move(0, 16); screen.text("mdusr")
  screen.font_size(8)
  screen.level(5)
  screen.move(W, 7); screen.text_right("MD USR loader")
  local status = ({
    checking = "checking for updates...", current = "up to date",
    behind = "update available", offline = "update check: offline",
    nogit = "not a git install: no updates", updating = "updating...",
  })[SPL.state] or SPL.msg or ""
  if SPL.msg then status = SPL.msg end
  screen.level(SPL.state == "behind" and 15 or 8)
  screen.move(0, 26); screen.text(fit(status, 128))
  draw_list(splash_items(), SPL.sel, function(it) return it.label end, 36, 3)
  screen.level(4); screen.move(0, 62); screen.text("K2 skip")
  screen.move(W, 62); screen.text_right("K3 select")
end

function redraw()
  screen.clear()
  screen.font_face(1)
  screen.font_size(8)
  if SPL.active then draw_splash()
  elseif send.active then draw_send()
  elseif send.result then draw_result()
  elseif pending then draw_confirm()
  elseif page == 1 then draw_load()
  else draw_backup() end
  if SPL.active then
    -- splash keeps its own layout
  elseif busy and not send.active and not B.full then
    screen.level(0); screen.rect(0, 47, W, 9); screen.fill()
    screen.level(12); screen.move(0, 54); screen.text(fit(busy .. "...", 128))
  elseif toast and util.time() < toast_t then
    screen.level(0); screen.rect(0, 47, W, 9); screen.fill()
    screen.level(15); screen.move(0, 54); screen.text(fit(toast, 128))
  end
  screen.update()
end

-- ---------------------------------------------------------------- init
local function connect(port)
  if md then md.event = nil end
  md = midi.connect(port)
  md.event = on_midi
end

function init()
  mkdirs()
  local names = {}
  for i = 1, #midi.vports do
    names[i] = i .. ": " .. (midi.vports[i].name or "none")
  end
  params:add_separator("mdusr")
  params:add_option("midi_port", "MIDI device", names, 1)
  params:set_action("midi_port", connect)
  params:add_number("chunk", "chunk bytes", 16, 1024, 128)
  params:add_number("rate", "max bytes/sec", 200, 3125, 2500)
  params:add_number("gap", "gap between msgs ms", 0, 2000, 150)
  params:add_number("req_timeout", "request timeout s", 1, 10, 2)
  params:add_option("between", "between files", { "auto gap", "wait for K3" }, 1)
  params:add_number("file_gap", "gap between files ms", 0, 10000, 1500)
  params:add_option("autorefresh", "refresh on start", { "new sources", "always", "never" }, 1)
  params:read()
  params:bang()

  net.tmpdir = CACHE
  load_cache()
  coll_load()
  local mode = params:get("autorefresh")
  if mode == 2 then
    refresh(source_list())
  elseif mode == 1 then
    -- fetch any source that has never been fetched (e.g. one added in an update)
    local missing = {}
    for _, s in ipairs(sources) do if not idx[s.id] then missing[#missing + 1] = s end end
    if #missing > 0 then refresh(missing) end
  end

  clock.run(check_update)
  clock.run(function()
    while true do
      clock.sleep(1 / 15)
      if dirty or busy or (toast and util.time() < toast_t + 0.2) then
        dirty = false
        redraw()
      end
    end
  end)
end

function cleanup()
  params:write()
  if md then md.event = nil end
end
