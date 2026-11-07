--!nocheck
local DrawingUtil = {}
local NEAR_PLANE = 0.05

local LINE_INDICES = {
    {1, 2},
    {2, 6},
    {6, 5},
    {5, 1},
    {1, 3},
    {2, 4},
    {6, 8},
    {5, 7},
    {3, 4},
    {4, 8},
    {8, 7},
    {7, 3},
}

local LINE_PROPERTIES = {
    Color = true,
    Thickness = true,
    Transparency = true,
    ZIndex = true,
}

local TEXT_PROPERTIES = {
    Color = true,
    Transparency = true,
    ZIndex = true,
    Size = true,
    Center = true,
    Outline = true,
    OutlineColor = true,
    Font = true,
}

local active_handles = {}
-- Weak keys allow destroyed/unreferenced targets to be garbage-collected.
local target_handles = setmetatable({}, { __mode = "k" })

local function create_drawing(drawing_type, defaults, options, allowed_properties)
    if Drawing == nil or type(Drawing.new) ~= "function" then
        error("DrawingUtil requires Drawing.new(), which is unavailable in this environment.", 3)
    end

    local drawing = Drawing.new(drawing_type)

    for property, value in pairs(defaults) do
        pcall(function()
            drawing[property] = value
        end)
    end

    if options then
        for property, value in pairs(options) do
            if allowed_properties[property] then
                pcall(function()
                    drawing[property] = value
                end)
            end
        end
    end

    return drawing
end

local function remove_drawing(drawing)
    if drawing then
        pcall(function()
            drawing:Remove()
        end)
    end
end

local function hide_handle(handle)
    for _, drawing in ipairs(handle.drawings) do
        pcall(function()
            drawing.Visible = false
        end)
    end
end

local function get_bounds(target)
    if typeof(target) ~= "Instance" or not target.Parent then
        return nil
    end

    if target:IsA("BasePart") then
        return target.CFrame, target.Size
    end

    if target:IsA("Model") then
        local success, cframe, size = pcall(function()
            return target:GetBoundingBox()
        end)

        if success then
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
    local half_size = size * 0.5
    local corners = {}

    for x = -1, 1, 2 do
        for y = -1, 1, 2 do
            for z = -1, 1, 2 do
                local offset = Vector3.new(
                    half_size.X * x,
                    half_size.Y * y,
                    half_size.Z * z
                )

                corners[#corners + 1] = cframe:PointToWorldSpace(offset)
            end
        end
    end

    return corners
end

local function project_segment(camera, world_a, world_b)
    local camera_cframe = camera.CFrame

    local local_a = camera_cframe:PointToObjectSpace(world_a)
    local local_b = camera_cframe:PointToObjectSpace(world_b)

    local depth_a = -local_a.Z
    local depth_b = -local_b.Z

    if depth_a <= NEAR_PLANE and depth_b <= NEAR_PLANE then
        return nil
    end

    local original_a = world_a
    local original_b = world_b

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
    local screen_point, on_screen = camera:WorldToViewportPoint(world_position)

    if screen_point.Z <= NEAR_PLANE then
        return nil, false
    end

    return Vector2.new(screen_point.X, screen_point.Y), on_screen
end

local function get_target_handle(target, drawing_kind)
    local handles = target_handles[target]
    return handles and handles[drawing_kind] or nil
end

local function register_target_handle(target, drawing_kind, handle)
    if not target then
        return
    end

    local handles = target_handles[target]
    if not handles then
        handles = {}
        target_handles[target] = handles
    end

    handles[drawing_kind] = handle
    handle._target = target
    handle._drawing_kind = drawing_kind
end

local function unregister_target_handle(handle)
    local target = handle._target
    local drawing_kind = handle._drawing_kind

    if not target or not drawing_kind then
        return
    end

    local handles = target_handles[target]
    if handles and handles[drawing_kind] == handle then
        handles[drawing_kind] = nil
        if next(handles) == nil then
            target_handles[target] = nil
        end
    end

    handle._target = nil
    handle._drawing_kind = nil
end

local function create_handle(drawings, update_function, target, drawing_kind)
    local handle = {
        drawings = drawings,
        _removed = false,
        _enabled = true,
        _update = update_function,
    }

    function handle:SetVisible(visible)
        if self._removed then
            return
        end

        self._enabled = visible == true

        if not self._enabled then
            hide_handle(self)
        end
    end

    function handle:Remove()
        if self._removed then
            return
        end

        self._removed = true
        active_handles[self] = nil
        unregister_target_handle(self)

        for _, drawing in ipairs(self.drawings) do
            remove_drawing(drawing)
        end

    end

    handle.Destroy = handle.Remove

    active_handles[handle] = true
    register_target_handle(target, drawing_kind, handle)

    return handle
end

-- Updates every active drawing once. Call this from your own loop (e.g. RenderStepped).
-- An optional Camera can be supplied; otherwise workspace.CurrentCamera is used.
function DrawingUtil.update(camera)
    camera = camera or workspace.CurrentCamera

    for handle in pairs(active_handles) do
        if handle._removed then
            active_handles[handle] = nil
        elseif not handle._enabled or not camera then
            hide_handle(handle)
        else
            local success, err = pcall(handle._update, handle, camera)
            if not success then
                warn("[DrawingUtil] Update failed:", err)
                handle:Remove()
            end
        end
    end
end

function DrawingUtil.drawBox(target, options)
    validate_target(target, "drawBox")

    local existing = get_target_handle(target, "Box")
    if existing and not existing._removed then
        return existing
    end

    options = options or {}

    local lines = table.create(#LINE_INDICES)

    for index = 1, #LINE_INDICES do
        lines[index] = create_drawing("Line", {
            Thickness = 1,
            Transparency = 1,
            ZIndex = 1,
            Visible = false,
            Color = Color3.new(1, 1, 1),
        }, options, LINE_PROPERTIES)
    end

    return create_handle(lines, function(self, camera)
        local cframe, size = get_bounds(target)

        if not cframe or not size then
            hide_handle(self)
            return
        end

        local corners = get_corners(cframe, size)

        for index, indices in ipairs(LINE_INDICES) do
            local line = self.drawings[index]

            local point_a, point_b = project_segment(
                camera,
                corners[indices[1]],
                corners[indices[2]]
            )

            if point_a and point_b then
                line.From = point_a
                line.To = point_b
                line.Visible = true
            else
                line.Visible = false
            end
        end
    end, target, "Box")
end

function DrawingUtil.drawText(target, text, options)
    validate_target(target, "drawText")

    local existing = get_target_handle(target, "Text")
    if existing and not existing._removed then
        return existing
    end

    if text == nil then
        error("drawText expects text as its second argument.", 2)
    end

    options = options or {}

    local drawing = create_drawing("Text", {
        Text = tostring(text),
        Size = 14,
        Center = true,
        Outline = true,
        OutlineColor = Color3.new(0, 0, 0),
        Color = Color3.new(1, 1, 1),
        Transparency = 1,
        ZIndex = 2,
        Visible = false,
    }, options, TEXT_PROPERTIES)

    local offset = options.Offset
    local padding = options.Padding or 2
    local on_screen_only = options.OnScreenOnly ~= false

    local handle = create_handle({drawing}, function(self, camera)
        local cframe, size = get_bounds(target)

        if not cframe or not size then
            drawing.Visible = false
            return
        end

        local local_offset = offset

        if typeof(local_offset) ~= "Vector3" then
            local_offset = Vector3.new(0, size.Y * 0.5 + padding, 0)
        end

        local world_position = cframe:PointToWorldSpace(local_offset)
        local screen_position, on_screen = project_point(camera, world_position)

        if not screen_position or (on_screen_only and not on_screen) then
            drawing.Visible = false
            return
        end

        drawing.Position = screen_position
        drawing.Visible = true
    end, target, "Text")

    handle.Drawing = drawing

    function handle:SetText(new_text)
        if self._removed then
            return
        end

        drawing.Text = tostring(new_text)
    end

    function handle:SetOffset(new_offset)
        if self._removed then
            return
        end

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

    local line = create_drawing("Line", {
        Thickness = 1,
        Transparency = 1,
        ZIndex = 2,
        Visible = false,
        Color = Color3.new(1, 1, 1),
    }, options, LINE_PROPERTIES)

    local handle = create_handle({line}, function(self, camera)
        local screen_a, screen_b = project_segment(camera, position1, position2)

        if not screen_a or not screen_b then
            line.Visible = false
            return
        end

        line.From = screen_a
        line.To = screen_b
        line.Visible = true
    end)

    handle.Drawing = line

    function handle:SetPositions(new_position1, new_position2)
        if self._removed then
            return
        end

        if typeof(new_position1) ~= "Vector3"
            or typeof(new_position2) ~= "Vector3" then
            error("SetPositions expects two Vector3 positions.", 2)
        end

        position1 = new_position1
        position2 = new_position2
    end

    return handle
end

-- Removes every DrawingUtil handle associated with this BasePart or Model.
function DrawingUtil.remove(target)
    validate_target(target, "remove")

    local handles_by_kind = target_handles[target]
    if not handles_by_kind then
        return false
    end

    local handles = {}
    for _, handle in pairs(handles_by_kind) do
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
