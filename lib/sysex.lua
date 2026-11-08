-- SysEx helpers for mdusr: split/validate files, Machinedrum requests,
-- and an assembler that rebuilds F0..F7 messages from midi.event chunks.
local sysex = {}

sysex.MD_HEADER = { 0xF0, 0x00, 0x20, 0x3C, 0x02, 0x00 }

-- Machinedrum message IDs (as used by the MD SysEx spec and jmamma/MCL)
sysex.ID = {
  GLOBAL = 0x50, GLOBAL_REQ = 0x51,
  KIT = 0x52, KIT_REQ = 0x53,
  PATTERN = 0x67, PATTERN_REQ = 0x68,
  SONG = 0x69, SONG_REQ = 0x6A,
  STATUS_REQ = 0x70, STATUS = 0x72,
}

sysex.ID_NAME = {
  [0x50] = "global", [0x52] = "kit", [0x67] = "pattern", [0x69] = "song", [0x72] = "status",
}

-- read a whole binary file -> string or nil, err
function sysex.read_file(path)
  local f, e = io.open(path, "rb")
  if not f then return nil, e end
  local s = f:read("a")
  f:close()
  return s
end

-- bytes table <-> string
function sysex.to_string(bytes)
  local parts, CH = {}, 4096
  for i = 1, #bytes, CH do
    parts[#parts + 1] = string.char(table.unpack(bytes, i, math.min(i + CH - 1, #bytes)))
  end
  return table.concat(parts)
end

local function to_bytes(s, a, b)
  local t = {}
  local n = 0
  local CH = 4096
  for i = a, b, CH do
    local chunk = { s:byte(i, math.min(i + CH - 1, b)) }
    for k = 1, #chunk do n = n + 1; t[n] = chunk[k] end
  end
  return t
end

-- split raw file data into messages.
-- returns { msgs = { {bytes...}, ... }, bytes = total, errors = {..}, junk = n }
function sysex.split(data)
  local res = { msgs = {}, bytes = 0, errors = {}, junk = 0 }
  local i, len = 1, #data
  while i <= len do
    local s = data:find("\xF0", i, true)
    if not s then res.junk = res.junk + (len - i + 1); break end
    res.junk = res.junk + (s - i)
    local e = data:find("\xF7", s + 1, true)
    if not e then
      res.errors[#res.errors + 1] = ("message %d: no F7 terminator"):format(#res.msgs + 1)
      break
    end
    -- a status byte inside the body means a broken/truncated message
    local body = data:sub(s + 1, e - 1)
    local bad = body:find("[\x80-\xFF]")
    if bad then
      res.errors[#res.errors + 1] = ("message %d: status byte 0x%02X inside body"):format(#res.msgs + 1, body:byte(bad))
      i = s + bad -- resync at the offending byte
    else
      res.msgs[#res.msgs + 1] = to_bytes(data, s, e)
      res.bytes = res.bytes + (e - s + 1)
      i = e + 1
    end
  end
  return res
end

-- true if message carries the Elektron manufacturer ID 00 20 3C
function sysex.is_elektron(m)
  return m[2] == 0x00 and m[3] == 0x20 and m[4] == 0x3C
end

function sysex.is_md(m)
  return sysex.is_elektron(m) and m[5] == 0x02 and m[6] == 0x00
end

-- short human label for a message
function sysex.describe(m)
  if sysex.is_md(m) then
    local id = m[7]
    local name = sysex.ID_NAME[id]
    if name then
      local pos = m[10]
      if id == 0x67 and pos then -- pattern number position
        return ("%s %s"):format(name, sysex.pattern_name(pos))
      end
      return name .. (pos and (" " .. (pos + 1)) or "")
    end
    return ("MD 0x%02X"):format(id or 0)
  elseif sysex.is_elektron(m) then
    return "elektron"
  end
  return "other"
end

-- pattern 0..127 -> "A01".."H16"
function sysex.pattern_name(n)
  local bank = string.char(string.byte("A") + (n // 16))
  return ("%s%02d"):format(bank, (n % 16) + 1)
end

-- build a Machinedrum request message
function sysex.md_request(id, value)
  local m = {}
  for i, b in ipairs(sysex.MD_HEADER) do m[i] = b end
  m[#m + 1] = id
  if value then m[#m + 1] = value & 0x7F end
  m[#m + 1] = 0xF7
  return m
end

-- Assembler: feed() it every midi.event data table; complete messages are
-- passed to on_message(bytes). Handles sysex split over many callbacks and
-- ignores realtime bytes (clock etc.) interleaved inside a dump.
function sysex.assembler(on_message, max_len)
  local a = { buf = nil, n = 0, aborted = 0, max = max_len or 262144 }
  function a.feed(data)
    for i = 1, #data do
      local b = data[i]
      if b == 0xF0 then
        if a.buf then a.aborted = a.aborted + 1 end
        a.buf, a.n = { 0xF0 }, 1
      elseif a.buf then
        if b == 0xF7 then
          a.n = a.n + 1
          a.buf[a.n] = 0xF7
          local m = a.buf
          a.buf, a.n = nil, 0
          on_message(m)
        elseif b >= 0xF8 then
          -- realtime: legal anywhere, not part of the dump
        elseif b >= 0x80 then
          a.aborted = a.aborted + 1
          a.buf, a.n = nil, 0
        else
          a.n = a.n + 1
          a.buf[a.n] = b
          if a.n > a.max then a.aborted = a.aborted + 1; a.buf, a.n = nil, 0 end
        end
      end
    end
  end
  function a.reset() a.buf, a.n = nil, 0 end
  function a.busy() return a.buf ~= nil end
  return a
end

-- write a list of messages to a .syx file
function sysex.write_file(path, msgs)
  local f, e = io.open(path, "wb")
  if not f then return false, e end
  for _, m in ipairs(msgs) do f:write(sysex.to_string(m)) end
  f:close()
  return true
end

return sysex
