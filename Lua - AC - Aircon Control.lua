-- AC - AirCon Control (Key-Only Rewrite 20.03.2026)
-- - Overview + Settings views
-- - 12 persistent gas dropdowns
-- - Dropdowns filtered to AirCon + AirCon Mirrored prefabs
-- - Unified aircon read/write path
-- - 0-safe fallback when dropdown not selected
-- last updated March 21th 2026 ~ 3xp

local ui = ss.ui.surface("main")
local W, H = 480, 272

local size = ui:size()
if size then
    W = size.w or W
    H = size.h or H
end

local elapsed = 0
local tick = 0
local view = "overview"
local LIVE_REFRESH_TICKS = 12
local handles = {
    view = nil,
    footer_left = nil,
    footer_right = nil,
    footer_nav_overview = nil,
    footer_nav_settings = nil,
    status_txt = nil,
    overview = {},
}

local function reset_handles()
    handles = {
        view = nil,
        footer_left = nil,
        footer_right = nil,
        footer_nav_overview = nil,
        footer_nav_settings = nil,
        status_txt = nil,
        overview = {},
    }
end

-- ==================== CONSTANTS ====================
local LT = ic.enums.LogicType
local LBM = ic.enums.LogicBatchMethod
local batch_read = ic.batch_read
local batch_read_name = ic.batch_read_name
local batch_write_name = ic.batch_write_name
local currenttime = 0

local AIRCON_PREFAB = -2087593337
local AIRCON_MIRROR_PREFAB = 473473186

-- ==================== MEMORY ====================
local MEM_VIEW = 1
local MEM_SETTINGS_INIT = 2

local function lane_mem_prefab(i)
    return 10 + ((i - 1) * 2)
end

local function lane_mem_namehash(i)
    return 11 + ((i - 1) * 2)
end

local function mem_read_num(addr)
    return tonumber(mem_read(addr)) or 0
end

local function mem_write_num(addr, value)
    mem_write(addr, tonumber(value) or 0)
end

-- ==================== GAS DEFS ====================
local selection_defs = {
    { key = "o2", label = "O2", color = "#ffffff" },
    { key = "co2", label = "CO2", color = "#5d5d5d" },
    { key = "nitrogen", label = "Nitrogen", color = "#6a187b" },
    { key = "pollutant", label = "Pollutant", color = "#f8df00" },
    { key = "nitrous_oxide", label = "Nitrous Oxide", color = "#26ff00" },
    { key = "hydrogen", label = "Hydrogen", color = "#a54f4f" },
    { key = "hydrazine", label = "Hydrazine", color = "#ed7708" },
    { key = "helium", label = "Helium", color = "#a54ab1" },
    { key = "silanol", label = "Silanol", color = "#512c18" },
    { key = "hydrochloric_acid", label = "Hydrochloric Acid", color = "#4f9849" },
    { key = "ozone", label = "Ozone", color = "#ed12e2" },
    { key = "methane", label = "Methane", color = "#f50a0a" },
}

local key_to_selection_index = {}
local settings_dropdown_open = {}
local settings_dropdown_selected = {}

for i, def in ipairs(selection_defs) do
    key_to_selection_index[def.key] = i
    settings_dropdown_open[def.key] = "false"
    settings_dropdown_selected[def.key] = 0
end

local function init_settings_memory()
    if mem_read_num(MEM_SETTINGS_INIT) == 1 then
        view = (mem_read_num(MEM_VIEW) == 1) and "settings" or "overview"
        return
    end

    for i = 1, #selection_defs do
        mem_write_num(lane_mem_prefab(i), 0)
        mem_write_num(lane_mem_namehash(i), 0)
    end

    mem_write_num(MEM_VIEW, 0)
    mem_write_num(MEM_SETTINGS_INIT, 1)
    view = "overview"
end

local function selected_pair_for_key(gas_key)
    local idx = key_to_selection_index[gas_key]
    if idx == nil then return 0, 0 end

    local prefab = mem_read_num(lane_mem_prefab(idx))
    local namehash = mem_read_num(lane_mem_namehash(idx))
    return prefab, namehash
end

-- ==================== HELPERS ====================
local function fmt(v, decimals)
    decimals = decimals or 1
    return string.format("%." .. decimals .. "f", tonumber(v) or 0)
end

local function pct_color(v)
    v = tonumber(v) or 0
    if v >= 60 then return "#00E676" end
    if v >= 30 then return "#FFEB3B" end
    if v >= 15 then return "#FF9800" end
    return "#FF5252"
end

local function temp_color(v)
    v = tonumber(v) or 0
    if v >= 50 then return "#e60000" end
    if v >= 30 then return "#ffbe3b" end
    if v >= 15 then return "#00aaff" end
    return "#140cff"
end

-- ==================== CORE READ/WRITE ====================
local function read_aircon_main(prefab_hash, namehash)
    if (tonumber(prefab_hash) or 0) == 0 or (tonumber(namehash) or 0) == 0 then
        return 0, 0, 0, 0
    end

    local t_setting = tonumber(batch_read_name(prefab_hash, namehash, LT.Setting, LBM.Sum)) or 0
    local op_eff = tonumber(batch_read_name(prefab_hash, namehash, LT.OperationalTemperatureEfficiency, LBM.Sum)) or 0
    local td_eff = tonumber(batch_read_name(prefab_hash, namehash, LT.TemperatureDifferentialEfficiency, LBM.Sum)) or 0
    local p_eff = tonumber(batch_read_name(prefab_hash, namehash, LT.PressureEfficiency, LBM.Sum)) or 0

    return t_setting - 273.15, op_eff * 100, td_eff * 100, p_eff * 100
end

local function write_temp_main(prefab_hash, namehash, delta_k)
    if (tonumber(prefab_hash) or 0) == 0 or (tonumber(namehash) or 0) == 0 then return end
    local current = tonumber(batch_read_name(prefab_hash, namehash, LT.Setting, LBM.Sum)) or 0
    if current == 0 then return end
    batch_write_name(prefab_hash, namehash, LT.Setting, current + delta_k)
end

local function write_temp_value_main(prefab_hash, namehash, value_c)
    if (tonumber(prefab_hash) or 0) == 0 or (tonumber(namehash) or 0) == 0 then return end
    local num = tonumber(value_c)
    if num == nil then return end
    batch_write_name(prefab_hash, namehash, LT.Setting, num + 273.15)
end

local function read_aircon(gas_key)
    local prefab, namehash = selected_pair_for_key(gas_key)
    return read_aircon_main(prefab, namehash)
end

local function write_temp(gas_key, delta_k)
    local prefab, namehash = selected_pair_for_key(gas_key)
    write_temp_main(prefab, namehash, delta_k)
end

local function write_temp_value(gas_key, value_c)
    local prefab, namehash = selected_pair_for_key(gas_key)
    write_temp_value_main(prefab, namehash, value_c)
end

-- ==================== STATUS ====================
local function get_overall_status()
    local e1 = tonumber(batch_read(AIRCON_PREFAB, LT.Error, LBM.Sum)) or 0
    local e2 = tonumber(batch_read(AIRCON_MIRROR_PREFAB, LT.Error, LBM.Sum)) or 0
    if e1 > 0 or e2 > 0 then
        return "ERROR", "#ff0000"
    end
    return "NOMINAL", "#00E676"
end

-- ==================== DEVICE LIST ====================
local function device_list_safe()
    local ok, devices = pcall(function()
        if type(device_list) == "function" then return device_list() end
        return {}
    end)
    if ok and type(devices) == "table" then return devices end
    return {}
end

local function build_aircon_dropdown_options()
    local options = { "Select" }
    local candidates = {}

    for i, dev in ipairs(device_list_safe()) do
        local ph = tonumber(dev and dev.prefab_hash) or 0
        if ph == AIRCON_PREFAB or ph == AIRCON_MIRROR_PREFAB then
            local label = tostring((dev and dev.display_name) or ("Device " .. tostring(i)))
            label = label:gsub("|", "/")
            table.insert(options, label)
            table.insert(candidates, dev)
        end
    end

    if #options == 1 then
        table.insert(options, "No devices found")
    end

    return options, candidates
end

local function write_selected_device(index, candidates, mem_prefab, mem_namehash)
    if index == 0 then
        mem_write_num(mem_prefab, 0)
        mem_write_num(mem_namehash, 0)
        return
    end

    local picked = candidates[index]
    if picked ~= nil then
        local ph = tonumber(picked.prefab_hash) or 0
        local nh = tonumber(picked.name_hash) or 0
        if ph == AIRCON_PREFAB or ph == AIRCON_MIRROR_PREFAB then
            mem_write_num(mem_prefab, ph)
            mem_write_num(mem_namehash, nh)
        else
            mem_write_num(mem_prefab, 0)
            mem_write_num(mem_namehash, 0)
        end
    end
end

local function selected_index_from_saved(candidates, mem_prefab, mem_namehash)
    local saved_prefab = mem_read_num(mem_prefab)
    local saved_namehash = mem_read_num(mem_namehash)
    if saved_prefab == 0 or saved_namehash == 0 then return 0 end

    for i, dev in ipairs(candidates) do
        local ph = tonumber(dev and dev.prefab_hash) or 0
        local nh = tonumber(dev and dev.name_hash) or 0
        if ph == saved_prefab and nh == saved_namehash then
            return i
        end
    end
    return 0
end

-- ==================== RENDER PARTS ====================
local function render_footer(gtH, gtM)
    local y = H - 18
    currenttime = util.clock_time()
    ui:element({
        id = "footer_bar",
        type = "panel",
        rect = { unit = "px", x = 0, y = y, w = W, h = 18 },
        style = { bg = "#111827" }
    })

    handles.footer_left = ui:element({
        id = "footer_left",
        type = "label",
        rect = { unit = "px", x = 10, y = H - 17, w = 280, h = 14 },
        props = { text = "Current Time: " .. currenttime},
        style = { font_size = 8, color = "#94A3B8", align = "left" }
    })
    handles.footer_right = ui:element({
        id = "footer_right",
        type = "label",
        rect = { unit = "px", x = W - 170, y = H - 17, w = 165, h = 14 },
        props = { text = "Tick: " .. tostring(elapsed) },
        style = { font_size = 8, color = "#94A3B8", align = "left" }
    })

    handles.footer_nav_overview = ui:element({
        id = "footer_nav_overview",
        type = "button",
        rect = { unit = "px", x = W - 170, y = y + 1, w = 78, h = 14 },
        props = { text = "OVERVIEW" },
        style = { bg = view == "overview" and "#166534" or "#2b2b2b", text = "#FFFFFF", font_size = 8, gradient = "#1a0926", gradient_dir = "vertical" },
        on_click = function()
            view = "overview"
            mem_write_num(MEM_VIEW, 0)
            render(true)
        end
    })

    handles.footer_nav_settings = ui:element({
        id = "footer_nav_settings",
        type = "button",
        rect = { unit = "px", x = W - 86, y = y + 1, w = 74, h = 14 },
        props = { text = "SETTINGS" },
        style = { bg = view == "settings" and "#1E3A5F" or "#2b2b2b", text = "#FFFFFF", font_size = 8, gradient = "#1a0926", gradient_dir = "vertical" },
        on_click = function()
            view = "settings"
            mem_write_num(MEM_VIEW, 1)
            render(true)
        end
    })
end

local function render_overview(statusText, statusColor)
    ui:element({
        id = "hdr",
        type = "panel",
        rect = { unit = "px", x = 0, y = 0, w = W, h = 30 },
        style = { bg = "#1E293B" }
    })
    ui:element({
        id = "title",
        type = "label",
        rect = { unit = "px", x = 16, y = 6, w = 320, h = 20 },
        props = { text = "AC - AIRCON CONTROL" },
        style = { font_size = 14, color = "#E2E8F0", align = "left" }
    })
    handles.status_txt = ui:element({
        id = "status_txt",
        type = "label",
        rect = { unit = "px", x = W - 90, y = 6, w = 80, h = 20 },
        props = { text = statusText },
        style = { font_size = 10, color = statusColor, align = "right" }
    })

    local content_y = 34
    local panel_w = 220
    local panel_h = 64
    local col_gap = 8
    local row_gap = 4

    for i, def in ipairs(selection_defs) do
        local col = (i - 1) % 2
        local row = math.floor((i - 1) / 2)
        local px = 8 + (col * (panel_w + col_gap))
        local py = content_y + (row * (panel_h + row_gap))
        local ts, op, td, pe = read_aircon(def.key)

        local gas_panel = ui:element({
            id = "gas_panel_" .. def.key,
            type = "panel",
            rect = { unit = "px", x = px, y = py, w = panel_w, h = panel_h },
            style = { bg = "#111827" }
        })

        gas_panel:element({
            id = "gas_lbl_" .. def.key,
            type = "label",
            rect = { unit = "px", x = 4, y = 2, w = 212, h = 10 },
            props = { text = def.label },
            style = { font_size = 7, color = def.color, align = "center" }
        })

        gas_panel:element({
            id = "gas_set_lbl_" .. def.key,
            type = "label",
            rect = { unit = "px", x = 6, y = 14, w = 52, h = 8 },
            props = { text = "Setting" },
            style = { font_size = 6, color = "#94A3B8", align = "center" }
        })

        handles.overview[def.key] = {
            set_val = gas_panel:element({
                id = "gas_set_val_" .. def.key,
                type = "label",
                rect = { unit = "px", x = 6, y = 24, w = 52, h = 8 },
                props = { text = fmt(ts, 1) .. "C" },
                style = { font_size = 6, color = temp_color(ts), align = "center" }
            }),
            td_val = nil,
            op_val = nil,
            pe_val = nil,
        }

        gas_panel:element({
            id = "gas_op_lbl_" .. def.key,
            type = "label",
            rect = { unit = "px", x = 114, y = 14, w = 52, h = 8 },
            props = { text = "OP Effi" },
            style = { font_size = 6, color = "#94A3B8", align = "center" }
        })

        handles.overview[def.key].op_val = gas_panel:element({
            id = "gas_op_val_" .. def.key,
            type = "label",
            rect = { unit = "px", x = 114, y = 24, w = 52, h = 8 },
            props = { text = fmt(op, 0) .. "%" },
            style = { font_size = 6, color = pct_color(op), align = "center" }
        })

        gas_panel:element({
            id = "gas_td_lbl_" .. def.key,
            type = "label",
            rect = { unit = "px", x = 60, y = 14, w = 52, h = 8 },
            props = { text = "Temp Effi" },
            style = { font_size = 6, color = "#94A3B8", align = "center" }
        })

        handles.overview[def.key].td_val = gas_panel:element({
            id = "gas_td_val_" .. def.key,
            type = "label",
            rect = { unit = "px", x = 60, y = 24, w = 52, h = 8 },
            props = { text = fmt(td, 0) .. "%" },
            style = { font_size = 6, color = pct_color(td), align = "center" }
        })

        gas_panel:element({
            id = "gas_pe_lbl_" .. def.key,
            type = "label",
            rect = { unit = "px", x = 168, y = 14, w = 52, h = 8 },
            props = { text = "Press Effi" },
            style = { font_size = 6, color = "#94A3B8", align = "center" }
        })

        handles.overview[def.key].pe_val = gas_panel:element({
            id = "gas_pe_val_" .. def.key,
            type = "label",
            rect = { unit = "px", x = 168, y = 24, w = 52, h = 8 },
            props = { text = fmt(pe, 0) .. "%" },
            style = { font_size = 6, color = pct_color(pe), align = "center" }
        })

        gas_panel:element({
            id = "gas_in_" .. def.key,
            type = "textinput",
            rect = { unit = "px", x = 54, y = 34, w = 120, h = 15 },
            props = { placeholder = "Enter desired temp" },
            style = { bg = "#252724", text = "#FFFFFF", font_size = 7, placeholder_color = "#9a2424", gradient = "#1a0926", gradient_dir = "vertical" },
            on_change = function(v)
                write_temp_value(def.key, tonumber(v) or 0)
                render(false)
            end
        })

        gas_panel:element({
            id = "gas_plus_" .. def.key,
            type = "button",
            rect = { unit = "px", x = 72, y = 50, w = 40, h = 10 },
            props = { text = "+1" },
            style = { bg = "#268409", text = "#FFFFFF", font_size = 6, gradient = "#1a0926", gradient_dir = "vertical" },
            on_click = function()
                write_temp(def.key, 1)
                render(false)
            end
        })

        gas_panel:element({
            id = "gas_minus_" .. def.key,
            type = "button",
            rect = { unit = "px", x = 116, y = 50, w = 40, h = 10 },
            props = { text = "-1" },
            style = { bg = "#880404", text = "#FFFFFF", font_size = 6, gradient = "#1a0926", gradient_dir = "vertical" },
            on_click = function()
                write_temp(def.key, -1)
                render(false)
            end
        })
    end
end

local function render_settings_view(statusText, statusColor)
    local options, candidates = build_aircon_dropdown_options()

    ui:element({
        id = "hdr",
        type = "panel",
        rect = { unit = "px", x = 0, y = 0, w = W, h = 30 },
        style = { bg = "#1E293B" }
    })
    ui:element({
        id = "title",
        type = "label",
        rect = { unit = "px", x = 16, y = 6, w = 320, h = 20 },
        props = { text = "AC - AIRCON CONTROL -- SETTINGS" },
        style = { font_size = 14, color = "#E2E8F0", align = "left" }
    })
    handles.status_txt = ui:element({
        id = "status_txt",
        type = "label",
        rect = { unit = "px", x = W - 90, y = 6, w = 80, h = 20 },
        props = { text = statusText },
        style = { font_size = 10, color = statusColor, align = "right" }
    })

    local scroll_y = 48
    local scroll_h = H - scroll_y - 20
    local row_h = 30
    local content_h = (#selection_defs * row_h) + 8

    local scroll = ui:element({
        id = "settings_scroll",
        type = "scrollview",
        rect = { unit = "px", x = 10, y = scroll_y, w = W - 20, h = scroll_h },
        props = { content_height = tostring(content_h) },
        style = { bg = "#0A0E1A", scrollbar_bg = "#1A1A2E", scrollbar_handle = "#6844aa" }
    })

    for i, def in ipairs(selection_defs) do
        local x = 8
        local y = 4 + ((i - 1) * row_h)
        local w = W - 40
        local mem_prefab = lane_mem_prefab(i)
        local mem_namehash = lane_mem_namehash(i)

        settings_dropdown_selected[def.key] = selected_index_from_saved(candidates, mem_prefab, mem_namehash)

        scroll:element({
            id = "cfg_lbl_" .. def.key,
            type = "label",
            rect = { unit = "px", x = x, y = y, w = w, h = 10 },
            props = { text = def.label },
            style = { font_size = 7, color = def.color, align = "left" }
        })

        scroll:element({
            id = "cfg_sel_" .. def.key,
            type = "select",
            rect = { unit = "px", x = x, y = y + 11, w = w, h = 16 },
            props = {
                options = table.concat(options, "|"),
                selected = settings_dropdown_selected[def.key],
                open = settings_dropdown_open[def.key],
            },
            on_toggle = function()
                settings_dropdown_open[def.key] = settings_dropdown_open[def.key] == "true" and "false" or "true"
                render(true)
            end,
            on_change = function(optionIndex)
                settings_dropdown_selected[def.key] = tonumber(optionIndex) or 0
                write_selected_device(settings_dropdown_selected[def.key], candidates, mem_prefab, mem_namehash)
                settings_dropdown_open[def.key] = "false"
                render(true)
            end
        })
    end
end

local function update_footer_dynamic()
    currenttime = util.clock_time()
    if handles.footer_left ~= nil then
        handles.footer_left:set_props({ text = "Current Time: " .. currenttime })
    end
    if handles.footer_right ~= nil then
        handles.footer_right:set_props({ text = "Tick: " .. tostring(elapsed) })
    end
end

local function update_status_dynamic(statusText, statusColor)
    if handles.status_txt ~= nil then
        handles.status_txt:set_props({ text = statusText })
        handles.status_txt:set_style({ font_size = 10, color = statusColor, align = "right" })
    end
end

local function update_overview_dynamic()
    for _, def in ipairs(selection_defs) do
        local ts, op, td, pe = read_aircon(def.key)
        local gas_handles = handles.overview[def.key]
        if gas_handles ~= nil then
            if gas_handles.set_val ~= nil then
                gas_handles.set_val:set_props({ text = fmt(ts, 1) .. "C" })
                gas_handles.set_val:set_style({ font_size = 6, color = temp_color(ts), align = "center" })
            end
            if gas_handles.td_val ~= nil then
                gas_handles.td_val:set_props({ text = fmt(td, 0) .. "%" })
                gas_handles.td_val:set_style({ font_size = 6, color = pct_color(td), align = "center" })
            end
            if gas_handles.op_val ~= nil then
                gas_handles.op_val:set_props({ text = fmt(op, 0) .. "%" })
                gas_handles.op_val:set_style({ font_size = 6, color = pct_color(op), align = "center" })
            end
            if gas_handles.pe_val ~= nil then
                gas_handles.pe_val:set_props({ text = fmt(pe, 0) .. "%" })
                gas_handles.pe_val:set_style({ font_size = 6, color = pct_color(pe), align = "center" })
            end
        end
    end
end

-- ==================== MAIN RENDER ====================
function render(force_rebuild)
    local statusText, statusColor = get_overall_status()
    local gt = util.game_time()
    local gtH = math.floor(gt / 3600)
    local gtM = math.floor((gt % 3600) / 60)

    if force_rebuild or handles.view ~= view then
        ui:clear()
        reset_handles()

        ui:element({
            id = "bg",
            type = "panel",
            rect = { unit = "px", x = 0, y = 0, w = W, h = H },
            style = { bg = "#0A0E1A" }
        })

        if view == "settings" then
            render_settings_view(statusText, statusColor)
        else
            render_overview(statusText, statusColor)
        end

        render_footer(gtH, gtM)
        handles.view = view
    else
        update_status_dynamic(statusText, statusColor)
        update_footer_dynamic()
        if view == "overview" then
            update_overview_dynamic()
        end
    end

    ui:commit()
end

init_settings_memory()
render(true)

while true do
    tick = tick + 1
    elapsed = elapsed + 1
    if tick % LIVE_REFRESH_TICKS == 0 then
        render(false)
    end
    ic.yield()
end
