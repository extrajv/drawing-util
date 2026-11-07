--!nocheck
-- DrawingUtil backed by DrawingImmediate.
-- DrawingImmediate primitives must only be called from their matching GetPaint(zIndex) event.

local DrawingUtil = {}

local NEAR_PLANE = 0.05
local active_handles = {}
local target_handles = setmetatable({}, { __mode = "k" })
local paint_connections = {}

local LINE_INDICES = {
    {1, 2}, {2, 6}, {6, 5}, {5, 1},
    {1, 3}, {2, 4}, {6, 8}, {5, 7},
    {3, 4}, {4, 8}, {8, 7}, {7, 3},
}

local function get_immediate()
    local api = DrawingImmediate
    if type(api) ~= "table" then
        error("DrawingUtil requires the DrawingImmediate library.", 3)
    end
    return api
end

local function get_bounds(target)
    if typeof(target) ~= "Instance" or not target.Parent then
        return nil
    end

    if target:IsA("BasePart") then
        return target.CFrame, target.Size
    elseif target:IsA("Model") then
        local ok, cframe, size = pcall(function()
            return target:GetBoundingBox()
        end)
        if ok then
            return cframe, size
        end
    end

    return nil
end

local function validate_target(target, function_name)
    if typeof(target) ~= "Instance"
        or (not target:IsA("BasePart") and not target:IsA("Model")) then
        error(function_name .. " expects a BasePart or Model.", 3)
    end
end

local function get_corners(cframe, size)
    local half = size * 0.5
    local corners = {}

    for x = -1, 1, 2 do
        for y = -1, 1, 2 do
            for z = -1, 1, 2 do
                corners[#corners + 1] = cframe:PointToWorldSpace(
                    Vector3.new(half.X * x, half.Y * y, half.Z * z)
                )
            end
        end
    end

    return corners
end

local function project_segment(camera, world_a, world_b)
    local camera_cf = camera.CFrame
    local local_a = camera_cf:PointToObjectSpace(world_a)
    local local_b = camera_cf:PointToObjectSpace(world_b)
    local depth_a, depth_b = -local_a.Z, -local_b.Z

    if depth_a <= NEAR_PLANE and depth_b <= NEAR_PLANE then
        return nil
    end

    local original_a, original_b = world_a, world_b

    if depth_a <= NEAR_PLANE then
        local alpha = (NEAR_PLANE - depth_a) / (depth_b - depth_a)
        world_a = original_a:Lerp(original_b, alpha)
    end

    if depth_b <= NEAR_PLANE then
        local alpha = (depth_a - NEAR_PLANE) / (depth_a - depth_b)
        world_b = original_a:Lerp(original_b, alpha)
    end

    local screen_a = camera:WorldToViewportPoint(world_a)
    local screen_b = camera:WorldToViewportPoint(world_b)

    if screen_a.Z <= 0 or screen_b.Z <= 0 then
        return nil
    end

    return Vector2.new(screen_a.X, screen_a.Y),
        Vector2.new(screen_b.X, screen_b.Y)
end

local function project_point(camera, world_position)
    local point, on_screen = camera:WorldToViewportPoint(world_position)
    if point.Z <= NEAR_PLANE then
        return nil, false
    end
    return Vector2.new(point.X, point.Y), on_screen
end

local function get_target_handle(target, kind)
    local entries = target_handles[target]
    return entries and entries[kind] or nil
end

local function register_target_handle(target, kind, handle)
    if not target then return end
    local entries = target_handles[target]
    if not entries then
        entries = {}
        target_handles[target] = entries
    end
    entries[kind] = handle
    handle._target = target
    handle._kind = kind
end

local function unregister_target_handle(handle)
    local target, kind = handle._target, handle._kind
    if not target or not kind then return end

    local entries = target_handles[target]
    if entries and entries[kind] == handle then
        entries[kind] = nil
        if next(entries) == nil then
            target_handles[target] = nil
        end
    end

    handle._target = nil
    handle._kind = nil
end

local function stop_paint_if_idle(z_index)
    for handle in pairs(active_handles) do
        if not handle._removed and handle._zIndex == z_index then
            return
        end
    end

    local connection = paint_connections[z_index]
    if connection then
        connection:Disconnect()
        paint_connections[z_index] = nil
    end
end

local function ensure_paint(z_index)
    if paint_connections[z_index] then return end

    local signal = get_immediate().GetPaint(z_index)
    if not signal or type(signal.Connect) ~= "function" then
        error("DrawingImmediate.GetPaint(zIndex) did not return a connectable signal.", 3)
    end

    paint_connections[z_index] = signal:Connect(function()
        local camera = workspace.CurrentCamera
        if not camera then return end

        -- Snapshot to tolerate handles being removed/added while painting.
        local snapshot = {}
        for handle in pairs(active_handles) do
            if not handle._removed and handle._enabled and handle._zIndex == z_index then
                snapshot[#snapshot + 1] = handle
            end
        end

        for _, handle in ipairs(snapshot) do
            if not handle._removed and handle._enabled then
                local ok, err = pcall(handle._paint, handle, camera, get_immediate())
                if not ok then
                    warn("[DrawingUtil] Paint failed:", err)
                    handle:Remove()
                end
            end
        end
    end)
end

local function create_handle(paint_function, options, target, kind)
    options = options or {}
    local z_index = options.ZIndex
    if z_index == nil then z_index = 1 end
    if type(z_index) ~= "number" or z_index % 1 ~= 0 then
        error("ZIndex must be an integer.", 3)
    end

    local handle = {
        _removed = false,
        _enabled = true,
        _paint = paint_function,
        _zIndex = z_index,
    }

    function handle:SetVisible(visible)
        if not self._removed then
            self._enabled = visible == true
        end
    end

    function handle:Remove()
        if self._removed then return end
        self._removed = true
        active_handles[self] = nil
        unregister_target_handle(self)
        stop_paint_if_idle(self._zIndex)
    end

    handle.Destroy = handle.Remove
    active_handles[handle] = true
    register_target_handle(target, kind, handle)

    local ok, err = pcall(ensure_paint, z_index)
    if not ok then
        handle:Remove()
        error(err, 3)
    end

    return handle
end

local function get_style(options, defaults)
    options = options or {}
    return {
        Color = options.Color or defaults.Color or Color3.new(1, 1, 1),
        Transparency = options.Transparency == nil and (defaults.Transparency or 1) or options.Transparency,
        Thickness = options.Thickness or defaults.Thickness or 1,
        ZIndex = options.ZIndex == nil and (defaults.ZIndex or 1) or options.ZIndex,
    }
end

function DrawingUtil.drawBox(target, options)
    validate_target(target, "drawBox")
    options = options or {}

    local existing = get_target_handle(target, "Box")
    if existing and not existing._removed then return existing end

    local style = get_style(options, { ZIndex = 1 })
    return create_handle(function(_, camera, api)
        local cframe, size = get_bounds(target)
        if not cframe or not size then return end

        local corners = get_corners(cframe, size)
        for _, indices in ipairs(LINE_INDICES) do
            local a, b = project_segment(camera, corners[indices[1]], corners[indices[2]])
            if a and b then
                api.Line(a, b, style.Color, style.Transparency, style.Thickness)
            end
        end
    end, style, target, "Box")
end

function DrawingUtil.drawText(target, text, options)
    validate_target(target, "drawText")
    if text == nil then
        error("drawText expects text as its second argument.", 2)
    end
    options = options or {}

    local existing = get_target_handle(target, "Text")
    if existing and not existing._removed then return existing end

    local style = get_style(options, { ZIndex = 2 })
    local font = options.Font
    if font == nil then font = 0 end
    local font_size = options.Size or 14
    local center = options.Center ~= false
    local outline = options.Outline ~= false
    local outline_color = options.OutlineColor or Color3.new(0, 0, 0)
    local outline_opacity = options.OutlineTransparency
    if outline_opacity == nil then outline_opacity = style.Transparency end
    local offset = options.Offset
    local padding = options.Padding or 2
    local on_screen_only = options.OnScreenOnly ~= false
    local current_text = tostring(text)

    local handle = create_handle(function(_, camera, api)
        local cframe, size = get_bounds(target)
        if not cframe or not size then return end

        local local_offset = offset
        if typeof(local_offset) ~= "Vector3" then
            local_offset = Vector3.new(0, size.Y * 0.5 + padding, 0)
        end

        local world_position = cframe:PointToWorldSpace(local_offset)
        local screen_position, on_screen = project_point(camera, world_position)
        if not screen_position or (on_screen_only and not on_screen) then return end

        if outline then
            api.OutlinedText(
                screen_position, font, font_size, style.Color, style.Transparency,
                outline_color, outline_opacity, current_text, center
            )
        else
            api.Text(screen_position, font, font_size, style.Color, style.Transparency, current_text, center)
        end
    end, style, target, "Text")

    function handle:SetText(new_text)
        if not self._removed then current_text = tostring(new_text) end
    end

    function handle:SetOffset(new_offset)
        if self._removed then return end
        if new_offset ~= nil and typeof(new_offset) ~= "Vector3" then
            error("SetOffset expects a Vector3 or nil.", 2)
        end
        offset = new_offset
    end

    return handle
end

function DrawingUtil.drawPointer(position1, position2, options)
    if typeof(position1) ~= "Vector3" or typeof(position2) ~= "Vector3" then
        error("drawPointer expects two Vector3 positions.", 2)
    end
    options = options or {}

    local style = get_style(options, { ZIndex = 2 })
    local handle = create_handle(function(_, camera, api)
        local a, b = project_segment(camera, position1, position2)
        if a and b then
            api.Line(a, b, style.Color, style.Transparency, style.Thickness)
        end
    end, style, nil, nil)

    function handle:SetPositions(new_position1, new_position2)
        if self._removed then return end
        if typeof(new_position1) ~= "Vector3" or typeof(new_position2) ~= "Vector3" then
            error("SetPositions expects two Vector3 positions.", 2)
        end
        position1, position2 = new_position1, new_position2
    end

    return handle
end

function DrawingUtil.remove(target)
    validate_target(target, "remove")
    local entries = target_handles[target]
    if not entries then return false end

    local handles = {}
    for _, handle in pairs(entries) do
        handles[#handles + 1] = handle
    end
    for _, handle in ipairs(handles) do
        handle:Remove()
    end
    return #handles > 0
end

DrawingUtil.removeDrawing = DrawingUtil.remove

function DrawingUtil.removeAll()
    local handles = {}
    for handle in pairs(active_handles) do
        handles[#handles + 1] = handle
    end
    for _, handle in ipairs(handles) do
        handle:Remove()
    end
end

DrawingUtil.destroy = DrawingUtil.removeAll

return DrawingUtil
