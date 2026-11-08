-- text helpers: HTML stripping, entity decoding, ASCII folding for the norns font
local text = {}

local named = {
  amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
  middot = "-", mdash = "-", ndash = "-", hellip = "...", rsquo = "'", lsquo = "'",
  rdquo = '"', ldquo = '"', times = "x", deg = "deg", plusmn = "+/-",
}

function text.entities(s)
  s = s:gsub("&#[xX](%x+);", function(h) return utf8.char(tonumber(h, 16)) end)
  s = s:gsub("&#(%d+);", function(d) return utf8.char(tonumber(d)) end)
  s = s:gsub("&(%a+);", function(n) return named[n] or ("&" .. n .. ";") end)
  return s
end

function text.strip_tags(s)
  s = s:gsub("<[^>]*>", " ")
  return s
end

-- fold common UTF-8 punctuation to ASCII and drop anything else non-ASCII
local folds = {
  ["\u{00B7}"] = "-", ["\u{2014}"] = "-", ["\u{2013}"] = "-", ["\u{2212}"] = "-",
  ["\u{2018}"] = "'", ["\u{2019}"] = "'", ["\u{201C}"] = '"', ["\u{201D}"] = '"',
  ["\u{2026}"] = "...", ["\u{00A0}"] = " ", ["\u{00D7}"] = "x", ["\u{00B1}"] = "+/-",
  ["\u{2192}"] = "->", ["\u{2190}"] = "<-", ["\u{00B0}"] = "deg", ["\u{00E9}"] = "e",
  ["\u{2022}"] = "*", ["\u{00B5}"] = "u",
}

function text.ascii(s)
  if not s then return "" end
  s = s:gsub("[\xC2-\xF4][\x80-\xBF]+", function(c) return folds[c] or "" end)
  s = s:gsub("[\x80-\xFF]", "")
  return s
end

function text.squash(s)
  return (s:gsub("%s+", " "):gsub(" ([%.,;:!%?%)])", "%1"):gsub("%( ", "("):gsub("^ ", ""):gsub(" $", ""))
end

-- HTML fragment -> one clean ASCII line
function text.clean(s)
  if not s then return "" end
  return text.squash(text.ascii(text.entities(text.strip_tags(s))))
end

-- markdown paragraph -> plain text
function text.unmarkdown(s)
  s = s:gsub("!%[[^%]]*%]%([^%)]*%)", "")      -- images
  s = s:gsub("%[([^%]]*)%]%([^%)]*%)", "%1")   -- links
  s = s:gsub("[*_`]+", "")
  return text.clean(s)
end

-- first real paragraph of a README (skips headings, badges, tables, lists, html)
function text.readme_summary(md)
  if not md then return nil end
  md = md:gsub("\r", "")
  for para in (md .. "\n\n"):gmatch("(.-)\n%s*\n") do
    local p = para:gsub("^%s+", "")
    local first = p:sub(1, 1)
    if #p > 0 and first ~= "#" and first ~= "!" and first ~= "|" and first ~= "<"
      and first ~= ">" and first ~= "-" and first ~= "*" and not p:match("^%d+%.")
      and not p:match("^```") and not p:match("^%[!") then
      local t = text.unmarkdown(p)
      if #t > 20 then return t end
    end
  end
  return nil
end

-- word-wrap to lines no wider than width_px using measure(str)->px
function text.wrap(s, width_px, measure)
  measure = measure or function(x) return #x * 5 end
  local lines, line = {}, ""
  for word in s:gmatch("%S+") do
    local try = (line == "") and word or (line .. " " .. word)
    if measure(try) <= width_px then
      line = try
    else
      if line ~= "" then lines[#lines + 1] = line end
      -- hard-break very long words
      while measure(word) > width_px and #word > 1 do
        local k = #word
        while k > 1 and measure(word:sub(1, k)) > width_px do k = k - 1 end
        lines[#lines + 1] = word:sub(1, k)
        word = word:sub(k + 1)
      end
      line = word
    end
  end
  if line ~= "" then lines[#lines + 1] = line end
  return lines
end

-- resolve a relative URL against a base page/dir URL
function text.resolve(base, rel)
  if not rel or rel == "" then return nil end
  if rel:match("^https?://") then return rel end
  local root = base:match("^(https?://[^/]+)")
  if rel:sub(1, 1) == "/" then return root .. rel end
  local dir = base:match("^(.*/)") or (base .. "/")
  if not base:match("^https?://[^/]+/") then dir = base .. "/" end
  rel = rel:gsub("^%./", "")
  while rel:sub(1, 3) == "../" do
    rel = rel:sub(4)
    dir = dir:gsub("[^/]+/$", "")
  end
  return dir .. rel
end

-- url-encode path segments (spaces etc.), keep / and existing %xx
function text.urlpath(p)
  return (p:gsub("[^%w%-%._~/%%]", function(c) return ("%%%02X"):format(c:byte()) end))
end

function text.basename(p)
  return (p:gsub("[?#].*$", ""):match("([^/]+)$")) or p
end

-- filesystem-safe name
function text.safe(s)
  return (s:gsub("[^%w%-%._]", "_"))
end

return text
