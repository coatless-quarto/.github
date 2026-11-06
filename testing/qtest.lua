--- qtest: a test runner for Quarto extensions that needs nothing but Quarto.
---
--- Usage, from an extension repo's root:
---   quarto pandoc lua /path/to/qtest.lua [pattern]
---
--- It runs every tests/*.test.lua file (or only the ones whose name contains
--- `pattern`) and prints TAP. The exit code is the number of failed checks.
---
--- Test files call the functions in the `qtest` module:
---
---   local t = require("qtest")
---   t.test("one tab per code block", function()
---     local r = t.render("basic.qmd", "html")
---     r:succeeded()
---     t.count(r.text, 'class="panel-tabset', 1)
---   end)
---
--- t.render copies tests/fixtures/ and the repo's _extensions/ into a fresh
--- temporary folder, renders there with `quarto render`, and returns the
--- output as text. Nothing is written into the repo. Tests that render the
--- same fixture with the same options share one render.
---
--- QUARTO=/path/to/bin/quarto picks the Quarto to render with.

local M = {}

local QUARTO = os.getenv("QUARTO") or "quarto"
local ROOT = pandoc.system.get_working_directory()
local TESTS = pandoc.path.join({ ROOT, "tests" })
local FIXTURES = pandoc.path.join({ TESTS, "fixtures" })

local count, failures, current = 0, 0, nil

---------------------------------------------------------------------------
-- Reporting
---------------------------------------------------------------------------

--- A check failed: raise an error the enclosing t.test turns into "not ok".
---@param message string
local function fail(message)
  error({ qtest = true, message = message }, 0)
end

--- Run one named test and print a TAP line for it.
---@param name string
---@param fn fun()
function M.test(name, fn)
  count = count + 1
  local ok, err = pcall(fn)
  if ok then
    print(string.format("ok %d - %s", count, name))
    return
  end
  failures = failures + 1
  print(string.format("not ok %d - %s", count, name))
  local message = type(err) == "table" and err.message or tostring(err)
  print("  ---")
  print("  file: " .. tostring(current))
  for line in (message .. "\n"):gmatch("(.-)\n") do
    print("  " .. line)
  end
  print("  ...")
end

---------------------------------------------------------------------------
-- Checks
---------------------------------------------------------------------------

local function show(value)
  if type(value) == "string" then
    return string.format("%q", value)
  end
  return tostring(value)
end

--- Count plain (non-pattern) occurrences of `needle` in `text`.
---@param text string
---@param needle string
---@return integer
local function occurrences(text, needle)
  local n, from = 0, 1
  while true do
    local s, e = text:find(needle, from, true)
    if not s then return n end
    n, from = n + 1, e + 1
  end
end
M.occurrences = occurrences

function M.ok(value, what)
  if not value then fail((what or "expected a true value") .. ", got " .. show(value)) end
end

function M.eq(actual, expected, what)
  if actual ~= expected then
    fail(string.format("%s\nexpected: %s\nactual:   %s", what or "values differ", show(expected), show(actual)))
  end
end

function M.contains(text, needle)
  if not text:find(needle, 1, true) then
    fail("output does not contain " .. show(needle))
  end
end

function M.not_contains(text, needle)
  if text:find(needle, 1, true) then
    fail("output unexpectedly contains " .. show(needle))
  end
end

function M.count(text, needle, n)
  local got = occurrences(text, needle)
  if got ~= n then
    fail(string.format("expected %d of %s, found %d", n, show(needle), got))
  end
end

--- Check that the needles appear in this order.
---@param text string
---@param needles string[]
function M.in_order(text, needles)
  local from = 1
  for _, needle in ipairs(needles) do
    local s, e = text:find(needle, from, true)
    if not s then
      fail("expected " .. show(needle) .. " after position " .. from .. " (order: " .. table.concat(needles, ", ") .. ")")
    end
    from = e + 1
  end
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

--- Copy a file or folder tree.
---@param from string
---@param to string
local function copy_tree(from, to)
  if pandoc.path.exists(from, "directory") then
    pandoc.system.make_directory(to, true)
    for _, entry in ipairs(pandoc.system.list_directory(from)) do
      copy_tree(pandoc.path.join({ from, entry }), pandoc.path.join({ to, entry }))
    end
  else
    pandoc.system.copy(from, to)
  end
end

--- List every file under `dir`, relative to it.
---@param dir string
---@param prefix? string
---@param acc? table<string, boolean>
---@return table<string, boolean>
local function list_files(dir, prefix, acc)
  acc = acc or {}
  for _, entry in ipairs(pandoc.system.list_directory(dir)) do
    local rel = prefix and (prefix .. "/" .. entry) or entry
    local full = pandoc.path.join({ dir, entry })
    if pandoc.path.exists(full, "directory") then
      list_files(full, rel, acc)
    else
      acc[rel] = true
    end
  end
  return acc
end

-- How to turn each format's output into searchable text
local OUTPUTS = {
  html = { ext = ".html" },
  revealjs = { ext = ".html" },
  gfm = { ext = ".md" },
  typst = { ext = ".typ", args = { "-M", "keep-typ:true" } },
  pdf = { ext = ".tex", args = { "-M", "keep-tex:true" } },
  latex = { ext = ".tex" },  -- the LaTeX a pdf render starts from, no TeX needed
  beamer = { ext = ".tex", args = { "-M", "keep-tex:true" } },
  docx = { ext = ".docx", reader = "docx" },
  epub = { ext = ".epub", reader = "epub" },
}

---@class QtestResult
---@field format string
---@field code integer Exit code of `quarto render`
---@field log string Everything quarto printed
---@field text string The output as text ("" when there is none)
---@field doc pandoc.Pandoc|nil The parsed document, for docx and epub output
---@field files table<string, boolean> Every file in the render folder afterwards
local Result = {}
Result.__index = Result

--- The log lines worth showing in a failure: errors and warnings, else the tail.
---@param log string
---@return string
local function log_excerpt(log)
  log = log:gsub("\27%[[%d;]*m", "")
  local keep, all = {}, {}
  for line in (log .. "\n"):gmatch("(.-)\n") do
    all[#all + 1] = line
    if line:find("ERROR", 1, true) or line:find("WARN", 1, true) or line:find("attempt to", 1, true)
        or line:find("(E)", 1, true) or line:find("(W)", 1, true)
        or line:find("%.lua:%d+:") then
      keep[#keep + 1] = line
    end
  end
  if #keep == 0 then
    keep = { table.unpack(all, math.max(1, #all - 15)) }
  end
  return table.concat(keep, "\n")
end

--- The render exited 0 and printed no errors.
function Result:succeeded()
  if self.code ~= 0 then
    fail(string.format("quarto render exited %d\n%s", self.code, log_excerpt(self.log)))
  end
  -- Quarto's filters print errors and carry on, so check the log too
  -- quarto.log.error prints "(E)"
  for _, marker in ipairs({ "ERROR", "(E)", "Error running filter", "stack traceback" }) do
    if self.log:find(marker, 1, true) then
      fail("quarto render printed " .. show(marker) .. "\n" .. log_excerpt(self.log))
    end
  end
  if self.text == "" then
    fail("quarto render produced no " .. self.format .. " output\n" .. log_excerpt(self.log))
  end
end

--- The render exited with a non-zero code.
function Result:failed()
  if self.code == 0 then
    fail("expected quarto render to fail, but it exited 0\n" .. log_excerpt(self.log))
  end
end

--- The render printed no warnings.
function Result:no_warnings()
  -- quarto.log.warning prints "(W)"
  if self.log:find("WARN", 1, true) or self.log:find("(W)", 1, true) then
    fail("quarto render printed a warning\n" .. log_excerpt(self.log))
  end
end

local cache = {}

--- Render a fixture and return its output as text.
---
--- opts.args: extra arguments for `quarto render`
--- opts.read: extra files to read afterwards, relative to the render folder
--- opts.output: the file to read as `r.text`, for a folder (project) fixture
--- opts.times: render this many times in the same folder (default 1), e.g.
---   to check that a project renders again on top of its own output
---@param fixture string File or folder under tests/fixtures/
---@param format string Quarto format, e.g. "html" or "typst"
---@param opts? {args?: string[], read?: string[], output?: string, times?: integer}
---@return QtestResult
function M.render(fixture, format, opts)
  opts = opts or {}
  local key = table.concat({ fixture, format, table.concat(opts.args or {}, " "),
    table.concat(opts.read or {}, " "), opts.output or "", tostring(opts.times or 1) }, "\0")
  if not cache[key] then
    cache[key] = M.render_fresh(fixture, format, opts)
  end
  return cache[key]
end

--- Like t.render, but always renders anew instead of sharing a render.
---@param fixture string
---@param format string
---@param opts? {args?: string[], read?: string[], output?: string, times?: integer}
---@return QtestResult
function M.render_fresh(fixture, format, opts)
  opts = opts or {}
  local out = OUTPUTS[format] or { ext = "." .. format }
  return pandoc.system.with_temporary_directory("qtest", function(tmp)
    copy_tree(FIXTURES, tmp)
    local extensions = pandoc.path.join({ ROOT, "_extensions" })
    copy_tree(extensions, pandoc.path.join({ tmp, "_extensions" }))
    -- A folder fixture is its own project, and Quarto looks for extensions
    -- in the project, so it gets a copy too
    if pandoc.path.exists(pandoc.path.join({ tmp, fixture }), "directory") then
      copy_tree(extensions, pandoc.path.join({ tmp, fixture, "_extensions" }))
    end

    local args = { "render", fixture, "--to", format }
    for _, a in ipairs(out.args or {}) do args[#args + 1] = a end
    for _, a in ipairs(opts.args or {}) do args[#args + 1] = a end

    -- The first failing render's exit code wins; the logs are joined
    local code, logs = 0, {}
    for i = 1, opts.times or 1 do
      local c, stdout, stderr = pandoc.system.with_working_directory(tmp, function()
        return pandoc.system.command(QUARTO, args)
      end)
      c = tonumber(c) or 0
      if code == 0 then code = c end
      logs[#logs + 1] = (opts.times or 1) > 1 and ("--- render " .. i .. " ---\n") or ""
      logs[#logs + 1] = (stdout or "") .. (stderr or "")
    end

    local result = setmetatable({
      format = format,
      code = code,
      log = table.concat(logs),
      text = "",
      extra = {},
    }, Result)

    local file = pandoc.path.join({ tmp, opts.output or (pandoc.path.split_extension(fixture) .. out.ext) })
    if pandoc.path.exists(file, "file") then
      local content = pandoc.system.read_file(file)
      if out.reader then
        result.doc = pandoc.read(content, out.reader)
        content = pandoc.write(result.doc, "native")
      end
      result.text = content
    end
    for _, rel in ipairs(opts.read or {}) do
      local path = pandoc.path.join({ tmp, rel })
      result.extra[rel] = pandoc.path.exists(path, "file") and pandoc.system.read_file(path) or nil
    end
    result.files = list_files(tmp)
    return result
  end)
end

---------------------------------------------------------------------------
-- Runner
---------------------------------------------------------------------------

local function run(pattern)
  if not pandoc.path.exists(TESTS, "directory") then
    io.stderr:write("qtest: no tests/ folder in " .. ROOT .. "\n")
    os.exit(2)
  end
  -- Let tests `require` the harness and the extension's own Lua modules
  local paths = { pandoc.path.directory(PANDOC_SCRIPT_FILE or arg[0]) .. "/?.lua" }
  local ext_root = pandoc.path.join({ ROOT, "_extensions" })
  if pandoc.path.exists(ext_root, "directory") then
    for _, name in ipairs(pandoc.system.list_directory(ext_root)) do
      paths[#paths + 1] = pandoc.path.join({ ext_root, name, "?.lua" })
    end
  end
  package.path = table.concat(paths, ";") .. ";" .. package.path
  package.loaded["qtest"] = M

  local files = pandoc.system.list_directory(TESTS)
  table.sort(files)
  for _, entry in ipairs(files) do
    if entry:match("%.test%.lua$") and (not pattern or entry:find(pattern, 1, true)) then
      current = entry
      print("# " .. entry)
      local ok, err = pcall(dofile, pandoc.path.join({ TESTS, entry }))
      if not ok then
        count, failures = count + 1, failures + 1
        print(string.format("not ok %d - %s failed to load: %s", count, entry, tostring(err)))
      end
    end
  end
  print("1.." .. count)
  print(string.format("# %d passed, %d failed", count - failures, failures))
  os.exit(failures > 0 and 1 or 0)
end

-- Run when executed as a script; act as a plain module when required
if not package.loaded["qtest"] then
  run(arg and arg[1])
end

return M
