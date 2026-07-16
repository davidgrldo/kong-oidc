local M = {}

function M.should_process(filters, path)
  for _, excluded_path in ipairs(filters or {}) do
    if path == excluded_path then
      return false
    end
  end
  return true
end

return M
