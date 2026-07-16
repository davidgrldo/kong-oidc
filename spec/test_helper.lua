local M = { failures = 0 }

function M.equal(actual, expected)
  if actual ~= expected then
    error(("expected %s, got %s"):format(tostring(expected), tostring(actual)), 2)
  end
end

function M.test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    io.write("ok - ", name, "\n")
  else
    M.failures = M.failures + 1
    io.stderr:write("not ok - ", name, ": ", err, "\n")
  end
end

function M.finish()
  if M.failures > 0 then os.exit(1) end
end

return M
