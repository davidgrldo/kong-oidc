local M = {}

-- Segment-boundary prefix: "/public" matches "/public" and "/public/x", but
-- not "/publicity". Avoids a prefix accidentally exempting sibling paths.
local function matches_prefix(path, prefix)
  return path == prefix or path:sub(1, #prefix + 1) == prefix .. "/"
end

function M.should_process(filters, filters_prefix, path)
  for _, excluded_path in ipairs(filters or {}) do
    if path == excluded_path then
      return false
    end
  end
  for _, prefix in ipairs(filters_prefix or {}) do
    if matches_prefix(path, prefix) then
      return false
    end
  end
  return true
end

return M
