--!nocheck
-- Immediate-mode DrawingUtil for DrawingImmediate.
--
-- IMPORTANT:
-- Call drawBox/drawText/drawPointer from inside DrawingImmediate.GetPaint(zIndex).
-- These functions issue primitives for the current paint only. Nothing is retained
-- between frames, so call them again on every paint where the drawing should appear.

local DrawingUtil = {}

local NEAR_PLANE = 0.05

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

local function validate_target(target, function_name)
    if typeof(target) ~= "Instance"
        or (not target:IsA("BasePart") and not target:IsA("Model")) then
        error(function_name .. " expects a BasePart or Model.", 3)
    end
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

local function get_style(options, defaults)
    options = options or {}
    defaults = defaults or {}

    return {
        Color = options.Color or defaults.Color or Color3.new(1, 1, 1),
        Transparency = options.Transparency == nil and 1 or options.Transparency,
        Thickness = options.Thickness or defaults.Thickness or 1,
        Font = options.Font == nil and 0 or options.Font,
        Size = options.Size or 14,
        ZIndex = options.ZIndex == nil and (defaults.ZIndex or 1) or options.ZIndex,
    }
end

local function get_camera(options)
    local camera = options and options.Camera or workspace.CurrentCamera
    if not camera then
        return nil
    end
    return camera
end

-- Draws a box for the current paint only.
-- Call this again from the next GetPaint callback to keep it visible.
function DrawingUtil.drawBox(target, options)
    validate_target(target, "drawBox")
    options = options or {}

    local camera = get_camera(options)
    if not camera then return end

    local cframe, size = get_bounds(target)
    if not cframe or not size then return end

    local style = get_style(options, { ZIndex = 1 })
    local corners = get_corners(cframe, size)
    local api = get_immediate()

    for _, indices in ipairs(LINE_INDICES) do
        local point_a, point_b = project_segment(
            camera,
            corners[indices[1]],
            corners[indices[2]]
        )

        if point_a and point_b then
            api.Line(
                point_a,
                point_b,
                style.Color,
                style.Transparency,
                style.Thickness
            )
        end
    end
end

-- Draws text for the current paint only.
-- Font is the numeric font identifier expected by DrawingImmediate.
function DrawingUtil.drawText(target, text, options)
    validate_target(target, "drawText")
    if text == nil then
        error("drawText expects text as its second argument.", 2)
    end

    options = options or {}
    local camera = get_camera(options)
    if not camera then return end

    local cframe, size = get_bounds(target)
    if not cframe or not size then return end

    local style = get_style(options, { ZIndex = 2 })
    local padding = options.Padding or 2
    local offset = options.Offset

    if typeof(offset) ~= "Vector3" then
        offset = Vector3.new(0, size.Y * 0.5 + padding, 0)
    end

    local world_position = cframe:PointToWorldSpace(offset)
    local screen_position, on_screen = project_point(camera, world_position)

    if not screen_position or (options.OnScreenOnly ~= false and not on_screen) then
        return
    end

    local center = options.Center ~= false
    local content = tostring(text)
    local api = get_immediate()

    if options.Outline ~= false then
        local outline_color = options.OutlineColor or Color3.new(0, 0, 0)
        local outline_opacity = options.OutlineTransparency
        if outline_opacity == nil then
            outline_opacity = style.Transparency
        end

        api.OutlinedText(
            screen_position,
            style.Font,
            style.Size,
            style.Color,
            style.Transparency,
            outline_color,
            outline_opacity,
            content,
            center
        )
    else
        api.Text(
            screen_position,
            style.Font,
            style.Size,
            style.Color,
            style.Transparency,
            content,
            center
        )
    end
end

-- Draws a 3D line for the current paint only.
function DrawingUtil.drawPointer(position1, position2, options)
    if typeof(position1) ~= "Vector3" or typeof(position2) ~= "Vector3" then
        error("drawPointer expects two Vector3 positions.", 2)
    end

    options = options or {}
    local camera = get_camera(options)
    if not camera then return end

    local point_a, point_b = project_segment(camera, position1, position2)
    if not point_a or not point_b then return end

    local style = get_style(options, { ZIndex = 2 })
    get_immediate().Line(
        point_a,
        point_b,
        style.Color,
        style.Transparency,
        style.Thickness
    )
end

-- Immediate-mode drawings cannot be removed after their primitive has been
-- submitted. They disappear automatically on the next paint unless redrawn.
-- Kept as a compatibility no-op so older call sites do not error.
function DrawingUtil.remove(_target)
    return false
end

function DrawingUtil.removeAll()
    -- Nothing is retained between paint callbacks.
end

DrawingUtil.destroy = DrawingUtil.removeAll

return DrawingUtil
