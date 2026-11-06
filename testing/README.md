# Extension tests

`qtest.lua` runs an extension's `tests/*.test.lua` files. It needs only Quarto:

```bash
quarto pandoc lua path/to/qtest.lua           # every test file
quarto pandoc lua path/to/qtest.lua tabby     # files whose name contains "tabby"
```

Each test renders a fixture from `tests/fixtures/` in a temporary folder and checks the output:

```lua
local t = require("qtest")

t.test("html: one tabset with a tab per language", function()
  local r = t.render("basic.qmd", "html")
  r:succeeded()
  t.count(r.text, '<div class="panel-tabset">', 1)
end)
```

`r:succeeded()` fails on a non-zero exit and also on `ERROR`, `(E)` or a stack trace in the log, because Quarto filters print errors and keep going. The checks are `t.ok`, `t.eq`, `t.contains`, `t.not_contains`, `t.count` and `t.in_order`. See the comments at the top of `qtest.lua` for the render options.

Write the right amount of tests: one render per output format the extension supports, one test per documented option that changes the output, and one regression test per bug fixed. Unit-test only helpers with tricky logic, such as escaping or parsing.

The repo's workflow calls `.github/workflows/extension-tests.yml`, which also runs `luals/check.sh` on every folder in `_extensions/`.
