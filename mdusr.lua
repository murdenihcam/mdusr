-- mdusr
-- Machinedrum USR machine loader
-- + SysEx backup/restore
--
-- E1 page   E2 scroll   E3 option
-- K2 back   K3 select / send
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

local function refresh(list)
  if busy then return say("busy: " .. busy) end
  clock.run(function()
    for i, s in ipairs(list) do
      if s.id == "local" then
        load_local_index()
      else
        busy = ("refresh %s (%d/%d)"):format(s.name, i, #list)
        dirty = true
        local ok, res, err = pcall(s.load, make_env(s))
        if ok and res then
          res.updated = os.time()
          table.sort(res.machines, function(a, b)
            if a.category ~= b.category then return (a.sort or 0) < (b.sort or 0) end
            return (a.sort or 0) < (b.sort or 0)
          end)
          idx[s.id] = res
          write_text(CACHE .. "index_" .. s.id .. ".json", json.encode(res))
        else
          local msg = ok and err or res
          print("mdusr: " .. s.name .. ": " .. tostring(msg))
          local old = idx[s.id] or { machines = {}, notes = {} }
          old.error = tostring(msg)
          idx[s.id] = old
          say(s.name .. ": failed, cache kept", 3)
        end
      end
    end
    busy = nil
    dirty = true
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

local function machines_in(sid, cat)
  local out = {}
  for _, m in ipairs((idx[sid] or {}).machines or {}) do
    if cat == nil or m.category == cat then out[#out + 1] = m end
  end
  return out
end

-- ---------------------------------------------------------------- sending
local function wire_sleep(nbytes)
  local rate = params:get("rate")
  clock.sleep(nbytes / rate)
end

-- send a list of messages, paced. Runs inside a clock coroutine.
local function send_msgs(msgs, label)
  if not md then say("no MIDI device"); return false end
  local total = 0
  for _, m in ipairs(msgs) do total = total + #m end
  send.active, send.abort, send.done, send.total = true, false, 0, total
  send.msg, send.msgs, send.label, send.result = 0, #msgs, label, nil
  dirty = true
  local chunk = params:get("chunk")
  local gap = params:get("gap") / 1000
  for i, m in ipairs(msgs) do
    send.msg = i
    for a = 1, #m, chunk do
      if send.abort then break end
      local b = math.min(a + chunk - 1, #m)
      local part = { table.unpack(m, a, b) }
      md:send(part)
      send.done = send.done + #part
      dirty = true
      wire_sleep(#part)
    end
    if send.abort then
      -- never leave the MD inside an open SysEx: close it
      if send.done < total then md:send({ 0xF7 }) end
      break
    end
    if i < #msgs and gap > 0 then clock.sleep(gap) end
  end
  send.result = send.abort and "aborted" or "done"
  send.active = false
  dirty = true
  return not send.abort
end

-- read + validate a .syx file into a pending send
local function prepare_path(path, label, back)
  local data, e = sysex.read_file(path)
  if not data then say("read failed: " .. tostring(e)); return end
  local r = sysex.split(data)
  if #r.msgs == 0 then say("no SysEx in file"); return end
  pending = { msgs = r.msgs, bytes = r.bytes, label = label, back = back, errors = r.errors,
    junk = r.junk, elektron = sysex.is_elektron(r.msgs[1]) }
  dirty = true
end

-- make sure a machine file is on disk, then prepare it
local function prepare_file(sid, f, back)
  if busy then return say("busy: " .. busy) end
  clock.run(function()
    local path = f.path
    if not path then
      local dir = CACHE .. sid .. "/"
      util.make_dir(dir)
      path = dir .. text.safe(f.filename or text.basename(f.url or f.zip_member or "x.syx"))
      if not exists(path) then
        busy = "downloading " .. (f.filename or "")
        dirty = true
        local ok, e
        if f.zip_member then
          if not exists(f.zip) then
            busy = nil; dirty = true
            return say("zip missing: refresh source")
          end
          ok, e = net.unzip_extract(f.zip, f.zip_member, path)
        else
          ok, e = net.get_file(f.url, path)
        end
        busy = nil
        dirty = true
        if not ok then return say("offline? " .. tostring(e), 3) end
      end
    end
    prepare_path(path, f.filename or text.basename(path), back)
  end)
end

local function est_seconds(p)
  local gap = params:get("gap") / 1000
  return p.bytes / params:get("rate") + gap * math.max(0, #p.msgs - 1)
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
    local items = {}
    for _, s in ipairs(list) do items[#items + 1] = s end
    items[#items + 1] = { id = "_refresh", name = "Refresh all" }
    return items
  elseif L.level == "cats" then
    local items = { "Refresh this source" }
    for _, c in ipairs(categories(L.sid)) do items[#items + 1] = c end
    return items
  elseif L.level == "machines" then
    return machines_in(L.sid, L.cat)
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

function key(n, z)
  if z == 0 then return end
  -- global: sending / confirm screens capture keys
  if send.active then
    if n == 2 then send.abort = true; say("aborting...") end
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
      clock.run(function() send_msgs(p.msgs, p.label) end)
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
        local m = items[L.sel.machines]
        if m then L.machine = m; L.level = "detail"; L.scroll = 0; L.file = 1 end
      elseif L.level == "detail" then
        local f = L.machine.files[L.file]
        if f then prepare_file(L.sid, f, "detail") else say("no .syx for this machine") end
      end
    elseif n == 2 then
      if L.level == "detail" then L.level = "machines"
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
  if n == 1 then
    if not send.active and not pending and not B.full then page = util.clamp(page + d, 1, 2) end
    dirty = true
    return
  end
  if pending or send.active then return end
  if page == 1 then
    if L.level == "detail" then
      if n == 2 then L.scroll = math.max(0, L.scroll + d)
      elseif n == 3 then L.file = util.clamp(L.file + d, 1, math.max(1, #L.machine.files)) end
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
  header("SENDING " .. send.label)
  screen.level(10)
  screen.move(0, 22)
  screen.text(("msg %d/%d  %d/%d B"):format(send.msg, send.msgs, send.done, send.total))
  progress(30, send.total > 0 and send.done / send.total or 0)
  screen.level(4); screen.move(0, 62); screen.text("K2 abort")
end

local function draw_result()
  header(send.result == "done" and "SENT" or "ABORTED")
  screen.level(10)
  local lines = send.result == "done" and {
    send.label .. " sent.",
    "Check the MD screen for",
    "DSP FULL / MEM FULL /",
    "BUFFER FULL (try slower).",
  } or { "Transfer stopped.", "The MD slot may hold a", "partial machine: resend." }
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
  else
    lines = { "On the MD: GLOBAL > FILE >", "MACHINE MGR, pick a slot,", "arm RECV. Then K3." }
  end
  lines[#lines + 1] = ("%d msg, %d B, ~%ds"):format(#p.msgs, p.bytes, math.ceil(est_seconds(p)))
  local warn = {}
  if #p.errors > 0 then warn[#warn + 1] = #p.errors .. " broken msg skipped" end
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
      local x = idx[s.id]
      local n = x and #(x.machines or {}) or 0
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
    header(L.cat or L.sname, "1/2")
    local items = load_items()
    if #items == 0 then
      screen.level(6); screen.move(0, 24); screen.text("nothing cached")
      screen.move(0, 34); screen.text("K2 back, then Refresh")
      local x = idx[L.sid]
      if x and x.error then screen.move(0, 44); screen.text(fit(x.error, 128)) end
    else
      draw_list(items, L.sel.machines, function(m)
        return m.name, m.version and tostring(m.version):sub(1, 6) or nil
      end)
    end
  elseif L.level == "detail" then
    local m = L.machine
    header(m.name, m.version and tostring(m.version) or nil)
    local body = {}
    if m.title and m.title ~= "" and m.title ~= m.name then body[#body + 1] = m.title end
    for _, l in ipairs(text.wrap(text.ascii(m.desc or ""), 124, measure)) do body[#body + 1] = l end
    for _, e in ipairs(m.extra or {}) do
      for _, l in ipairs(text.wrap(text.ascii(e), 124, measure)) do body[#body + 1] = l end
    end
    local f = m.files[L.file]
    if f and f.scope then body[#body + 1] = "File: " .. f.scope end
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
      local lab = (#m.files > 1 and (L.file .. "/" .. #m.files .. " ") or "") .. f.label
      screen.text(fit(lab, 104))
      screen.move(W, 63); screen.text_right("K3")
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

function redraw()
  screen.clear()
  screen.font_face(1)
  screen.font_size(8)
  if send.active then draw_send()
  elseif send.result then draw_result()
  elseif pending then draw_confirm()
  elseif page == 1 then draw_load()
  else draw_backup() end
  if busy and not send.active and not B.full then
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
  params:add_option("autorefresh", "refresh on start", { "if empty", "always", "never" }, 1)
  params:read()
  params:bang()

  load_cache()
  local mode = params:get("autorefresh")
  local empty = true
  for _, s in ipairs(sources) do if idx[s.id] and #(idx[s.id].machines or {}) > 0 then empty = false end end
  if mode == 2 or (mode == 1 and empty) then refresh(source_list()) end

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
