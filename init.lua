--!nocheck
-- Immediate-mode DrawingUtil for DrawingImmediate.
--
-- IMPORTANT:
-- Call drawBox/drawText/drawPointer from inside DrawingImmediate.GetPaint(zIndex).
-- These functions issue primitives for the current paint only. Nothing is retained
-- between frames, so call them again on every paint where the drawing should appear.

local DrawingUtil = {}

local Players = game:GetService("Players")
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

-- Resolve the classic six body regions across both R6 and R15 rigs.
-- Accessories, tools, HumanoidRootPart, and other extra parts are intentionally
-- excluded from player-character bounds.
local PLAYER_BODY_PART_NAMES = {
    "Head",

    -- Torso region (R6 and R15)
    "Torso",
    "UpperTorso",
    "LowerTorso",

    -- Right arm region
    "Right Arm",
    "RightUpperArm",
    "RightLowerArm",
    "RightHand",

    -- Left arm region
    "Left Arm",
    "LeftUpperArm",
    "LeftLowerArm",
    "LeftHand",

    -- Right leg region
    "Right Leg",
    "RightUpperLeg",
    "RightLowerLeg",
    "RightFoot",

    -- Left leg region
    "Left Leg",
    "LeftUpperLeg",
    "LeftLowerLeg",
    "LeftFoot",
}

local function get_player_character_bounds(character)
    local ok, pivot = pcall(function()
        return character:GetPivot()
    end)
    if not ok then
        return nil
    end

    local min_x, min_y, min_z = math.huge, math.huge, math.huge
    local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge
    local found_part = false

    for _, part_name in ipairs(PLAYER_BODY_PART_NAMES) do
        local part = character:FindFirstChild(part_name)
        if part and part:IsA("BasePart") then
            found_part = true
            local half = part.Size * 0.5

            -- Transform every limb corner into character-pivot space. This
            -- gives one character-aligned box enclosing only the body regions.
            for x = -1, 1, 2 do
                for y = -1, 1, 2 do
                    for z = -1, 1, 2 do
                        local world_corner = part.CFrame:PointToWorldSpace(
                            Vector3.new(half.X * x, half.Y * y, half.Z * z)
                        )
                        local local_corner = pivot:PointToObjectSpace(world_corner)

                        min_x = math.min(min_x, local_corner.X)
                        min_y = math.min(min_y, local_corner.Y)
                        min_z = math.min(min_z, local_corner.Z)
                        max_x = math.max(max_x, local_corner.X)
                        max_y = math.max(max_y, local_corner.Y)
                        max_z = math.max(max_z, local_corner.Z)
                    end
                end
            end
        end
    end

    if not found_part then
        return nil
    end

    local center = Vector3.new(
        (min_x + max_x) * 0.5,
        (min_y + max_y) * 0.5,
        (min_z + max_z) * 0.5
    )
    local size = Vector3.new(
        max_x - min_x,
        max_y - min_y,
        max_z - min_z
    )

    return pivot * CFrame.new(center), size
end

local function get_bounds(target)
    if typeof(target) ~= "Instance" or not target.Parent then
        return nil
    end

    if target:IsA("BasePart") then
        return target.CFrame, target.Size
    elseif target:IsA("Model") then
        -- Only actual player characters use the body-part-only bounds.
        -- NPCs and ordinary models retain Roblox's normal model bounds.
        if Players:GetPlayerFromCharacter(target) then
            local body_cframe, body_size = get_player_character_bounds(target)
            if body_cframe and body_size then
                return body_cframe, body_size
            end
            return nil
        end

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
-- Resolve a stable attachment origin. BaseParts use their exact CFrame;
-- Models use GetPivot(), NOT the changing bounding-box center. This prevents
-- animated limbs / changing model bounds from moving the attachment frame.
local function get_target_origin(target)
    if target:IsA("BasePart") then
        return target.CFrame
    end

    local ok, pivot = pcall(function()
        return target:GetPivot()
    end)
    if ok then return pivot end
    return nil
end

-- Build a frame relative to the target's stable origin. Offset is always in
-- target-local studs. Rotation accepts a CFrame or Vector3 Euler angles (radians).
local function get_attachment_frame(target, options, default_offset)
    local origin = get_target_origin(target)
    local _, bounds_size = get_bounds(target)
    if not origin or not bounds_size then return nil, nil end

    local offset = options.Offset
    if offset == nil then offset = default_offset or Vector3.zero end
    if typeof(offset) ~= "Vector3" then
        error("Offset must be a target-local Vector3.", 3)
    end

    local rotation = options.Rotation
    if rotation == nil then
        rotation = CFrame.identity
    elseif typeof(rotation) == "Vector3" then
        rotation = CFrame.fromOrientation(rotation.X, rotation.Y, rotation.Z)
    elseif typeof(rotation) ~= "CFrame" then
        error("Rotation must be a Vector3 (radians) or CFrame.", 3)
    end

    return origin * CFrame.new(offset) * rotation, bounds_size
end

local function project_triangle(camera, a, b, c)
    local pa = camera.CFrame:PointToObjectSpace(a)
    local pb = camera.CFrame:PointToObjectSpace(b)
    local pc = camera.CFrame:PointToObjectSpace(c)
    if -pa.Z <= NEAR_PLANE or -pb.Z <= NEAR_PLANE or -pc.Z <= NEAR_PLANE then
        return nil
    end
    local sa = camera:WorldToViewportPoint(a)
    local sb = camera:WorldToViewportPoint(b)
    local sc = camera:WorldToViewportPoint(c)
    return Vector2.new(sa.X, sa.Y), Vector2.new(sb.X, sb.Y), Vector2.new(sc.X, sc.Y)
end

local function submit_filled_triangle(api, camera, a, b, c, style)
    local sa, sb, sc = project_triangle(camera, a, b, c)
    if sa and sb and sc then
        api.FilledTriangle(sa, sb, sc, style.Color, style.Transparency)
        return true
    end
    return false
end

-- Draws an actual target-aligned 3D cuboid. Each face is split into two
-- projected triangles, so perspective and target rotation are preserved.
-- Options: Offset (target-local Vector3), Size (Vector3, defaults to target bounds),
-- Rotation (Vector3 radians or CFrame), Color, Transparency, Camera.
function DrawingUtil.drawFilledBox(target, options)
    validate_target(target, "drawFilledBox")
    options = options or {}
    local camera = get_camera(options)
    if not camera then return end

    local _, bounds_size = get_bounds(target)
    if not bounds_size then return end
    -- The cuboid is centered on the true target origin by default. Set Offset
    -- explicitly to move it in target-local studs; it will never inherit a
    -- recomputed Model:GetBoundingBox() center.
    local frame = get_attachment_frame(target, options, Vector3.zero)
    if not frame then return end
    local size = options.Size or bounds_size
    if typeof(size) ~= "Vector3" or size.X <= 0 or size.Y <= 0 or size.Z <= 0 then
        error("drawFilledBox Size must be a positive Vector3.", 2)
    end

    local style = get_style(options, { ZIndex = 1 })
    local corners = get_corners(frame, size)
    -- Each face is a quad represented by two triangles. Faces are submitted
    -- back-to-front to make overlap look natural with the 2D immediate API.
    local faces = {
        {1, 2, 4, 3}, {5, 7, 8, 6},
        {1, 5, 6, 2}, {3, 4, 8, 7},
        {1, 3, 7, 5}, {2, 6, 8, 4},
    }
    local camera_pos = camera.CFrame.Position
    local ordered = {}
    for _, face in ipairs(faces) do
        local center = (corners[face[1]] + corners[face[2]] + corners[face[3]] + corners[face[4]]) / 4
        ordered[#ordered + 1] = { face = face, depth = (center - camera_pos).Magnitude }
    end
    table.sort(ordered, function(a, b) return a.depth > b.depth end)

    local api = get_immediate()
    for _, entry in ipairs(ordered) do
        local f = entry.face
        submit_filled_triangle(api, camera, corners[f[1]], corners[f[2]], corners[f[3]], style)
        submit_filled_triangle(api, camera, corners[f[1]], corners[f[3]], corners[f[4]], style)
    end
end

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

-- Convert a screen-space Vector2 or world-space Vector3 into a screen point.
local function to_screen_point(point, camera, function_name)
    if typeof(point) == "Vector2" then
        return point
    elseif typeof(point) == "Vector3" then
        local screen_point = project_point(camera, point)
        return screen_point
    end

    error(function_name .. " expects Vector2 screen points or Vector3 world points.", 3)
end

-- Draws a filled circle. Target form:
-- drawFilledCircle(partOrModel, radius, { Offset = Vector3, Rotation = Vector3/CFrame })
-- Radius is in studs in target form; the circle lies in the target-local XY plane.
-- Legacy form remains supported: drawFilledCircle(Vector2/Vector3, pixelRadius, options).
function DrawingUtil.drawFilledCircle(target_or_center, radius, options)
    options = options or {}
    if type(radius) ~= "number" or radius < 0 then
        error("drawFilledCircle expects a non-negative radius.", 2)
    end
    local camera = get_camera(options)
    if not camera then return end

    local style = get_style(options, { ZIndex = 2 })
    local api = get_immediate()
    local sides = math.max(3, math.floor(options.NumSides or 40))

    if typeof(target_or_center) == "Instance" then
        validate_target(target_or_center, "drawFilledCircle")
        local frame = get_attachment_frame(target_or_center, options)
        if not frame then return end
        local center = frame.Position
        local points = {}
        for i = 0, sides - 1 do
            local angle = (i / sides) * math.pi * 2
            points[#points + 1] = frame:PointToWorldSpace(Vector3.new(math.cos(angle) * radius, math.sin(angle) * radius, 0))
        end
        for i = 1, sides do
            submit_filled_triangle(api, camera, center, points[i], points[(i % sides) + 1], style)
        end
    else
        if typeof(target_or_center) ~= "Vector2" and typeof(target_or_center) ~= "Vector3" then
            error("drawFilledCircle expects a target, Vector2, or Vector3 center.", 2)
        end
        local screen_center = to_screen_point(target_or_center, camera, "drawFilledCircle")
        if not screen_center then return end
        api.FilledCircle(screen_center, radius, style.Color, sides, style.Transparency)
    end
end

-- Target form uses target-local Vector3 vertices:
-- drawFilledTriangle(partOrModel, localA, localB, localC, options)
-- Offset and Rotation move/rotate the local coordinate frame. The legacy
-- world/screen form drawFilledTriangle(a, b, c, options) remains supported.
function DrawingUtil.drawFilledTriangle(a, b, c, d, e)
    local target_form = typeof(a) == "Instance"
    local target, point_a, point_b, point_c, options
    if target_form then
        target, point_a, point_b, point_c, options = a, b, c, d, e or {}
        validate_target(target, "drawFilledTriangle")
    else
        point_a, point_b, point_c, options = a, b, c, d or {}
    end
    options = options or {}
    local camera = get_camera(options)
    if not camera then return end
    local style = get_style(options, { ZIndex = 2 })
    local api = get_immediate()

    if target_form then
        if typeof(point_a) ~= "Vector3" or typeof(point_b) ~= "Vector3" or typeof(point_c) ~= "Vector3" then
            error("Target-attached triangle vertices must be target-local Vector3 values.", 2)
        end
        local frame = get_attachment_frame(target, options)
        if not frame then return end
        submit_filled_triangle(api, camera,
            frame:PointToWorldSpace(point_a),
            frame:PointToWorldSpace(point_b),
            frame:PointToWorldSpace(point_c), style)
    else
        local screen_a = to_screen_point(point_a, camera, "drawFilledTriangle")
        local screen_b = to_screen_point(point_b, camera, "drawFilledTriangle")
        local screen_c = to_screen_point(point_c, camera, "drawFilledTriangle")
        if not screen_a or not screen_b or not screen_c then return end
        api.FilledTriangle(screen_a, screen_b, screen_c, style.Color, style.Transparency)
    end
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
