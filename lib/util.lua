-- Small shared helpers with no KOReader dependencies.
--
-- Error formatting exists in two flavours on purpose: log_error keeps the whole
-- message (control characters flattened) for the log, while display_error keeps
-- only the first line for an InfoMessage. Both truncate so a runaway traceback
-- can never flood the log or overflow a dialog.
--
-- Kept free of KOReader dependencies so it can be required from any module and
-- unit-tested with a plain Lua interpreter.

local Util = {}

Util.unpack = unpack or table.unpack

function Util.log_error(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 500 then
        return text:sub(1, 500) .. "..."
    end
    return text
end

function Util.display_error(err)
    local text = tostring(err)
    text = text:match("^[^\r\n]+") or text
    if #text > 300 then
        return text:sub(1, 300) .. "..."
    end
    return text
end

function Util.file_exists(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

return Util
