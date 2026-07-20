local lib = {}

local LIB_ID = "object-editor"

-- Register global for interop
Registry.registerGlobal("ObjectEditor", lib)

-- ============================================================
-- Configuration
-- ============================================================

local function cfg(key)
    return Kristal.getLibConfig(LIB_ID, key)
end

-- ============================================================
-- State Machine
-- ============================================================

local TFM = { IDLE = 0, GRAB = 1, ROTATE = 2, SCALE = 3 }

local TF = {
    mode = TFM.IDLE,
    obj = nil,
    -- Snapshot for cancel
    orig_x = 0, orig_y = 0,
    orig_sx = 1, orig_sy = 1,
    orig_rot = 0,
    undo_x = 0, undo_y = 0,
    undo_sx = 1, undo_sy = 1,
    undo_rot = 0,
    -- Mouse reference
    ref_mx = 0, ref_my = 0,
    orig_screen_x = 0, orig_screen_y = 0,
    -- Axis constraint: nil=free, "x"/"y"=lock, exclude=true means shift+axis
    axis = nil,
    exclude = false,
    -- Numeric input buffer
    num = "",
    has_num = false,
}

-- ============================================================
-- Undo / Redo
-- ============================================================

local undo = {}
local redo = {}
local DEFAULT_MAX_UNDO = 64
local patch_debug_system

-- Pending undo: saved when a continuous operation starts (grab, wheel),
-- committed to the undo stack only when the operation ends (release, click, key).
-- This avoids flooding the stack with per-tick / per-wheel-notch entries.
local grab_pending = nil   -- snapshot saved on LMB press, committed on LMB release
local wheel_pending = nil  -- snapshot saved before first wheel tick, committed on next action
local handled_key_event = nil
local handled_wheel_event = nil

local function get_max_undo()
    local max = tonumber(cfg("max_undo")) or DEFAULT_MAX_UNDO
    return math.max(1, math.floor(max))
end

local function trim_stack(stack)
    local max = get_max_undo()
    while #stack > max do
        table.remove(stack, 1)
    end
end

local function object_removed(obj)
    return (not obj) or (obj.isRemoved and obj:isRemoved())
end

local function uncache_object(obj)
    if Object and Object.uncache and obj then
        Object.uncache(obj)
    end
end

local function atan2(y, x)
    if math.atan2 then
        return math.atan2(y, x)
    end
    return math.atan(y, x)
end

local function editor_input_blocked(ds)
    ds = ds or Kristal.DebugSystem
    return (Kristal.Console and Kristal.Console.is_open)
        or (TextInput and TextInput.active)
        or (ds and (ds.window or ds.context))
end

local function console_open()
    return Kristal.Console and Kristal.Console.is_open
end

local function same_transform(obj, x, y, sx, sy, r)
    return obj
        and obj.x == x
        and obj.y == y
        and obj.scale_x == sx
        and obj.scale_y == sy
        and obj.rotation == r
end

local function snap(obj)
    if object_removed(obj) then return end
    return { kind = "transform", obj = obj, x = obj.x, y = obj.y, sx = obj.scale_x, sy = obj.scale_y, r = obj.rotation }
end

local function child_index(parent, child)
    if not parent or not parent.children then return end
    for i, obj in ipairs(parent.children) do
        if obj == child then return i end
    end
end

local function snap_delete(obj)
    if object_removed(obj) or not obj.parent then return end
    return {
        kind = "delete",
        obj = obj,
        parent = obj.parent,
        index = child_index(obj.parent, obj),
        x = obj.x,
        y = obj.y,
        sx = obj.scale_x,
        sy = obj.scale_y,
        r = obj.rotation,
    }
end

local function remove_all(tbl, value)
    if not tbl then return end
    for i = #tbl, 1, -1 do
        if tbl[i] == value then
            table.remove(tbl, i)
        end
    end
end

local function purge_stage_refs(stage, obj)
    if not stage or not obj then return end
    remove_all(stage.objects, obj)
    remove_all(stage.objects_to_remove, obj)
    if stage.objects_by_class then
        for _, objects in pairs(stage.objects_by_class) do
            remove_all(objects, obj)
        end
    end
    for _, child in ipairs(obj.children or {}) do
        purge_stage_refs(stage, child)
    end
end

local function apply_transform(obj, x, y, sx, sy, r)
    obj.x, obj.y = x, y
    obj.scale_x, obj.scale_y = sx, sy
    obj.rotation = r
    uncache_object(obj)
end

local function object_origin_screen_pos(obj)
    if object_removed(obj) then return end

    local ox, oy
    if obj.getOriginExact then
        ox, oy = obj:getOriginExact()
    else
        ox = (obj.width or 0) * (obj.origin_x or 0)
        oy = (obj.height or 0) * (obj.origin_y or 0)
    end
    return obj:getFullTransform():transformPoint(ox or 0, oy or 0)
end

local function object_rotation_origin_screen_pos(obj)
    if object_removed(obj) then return end

    local ox, oy
    if obj.getRotationOriginExact then
        ox, oy = obj:getRotationOriginExact()
    elseif obj.getOriginExact then
        ox, oy = obj:getOriginExact()
    else
        ox = (obj.width or 0) * (obj.origin_x or 0)
        oy = (obj.height or 0) * (obj.origin_y or 0)
    end
    return obj:getFullTransform():transformPoint(ox or 0, oy or 0)
end

local function unsnap(s)
    if not s or object_removed(s.obj) then return false end
    apply_transform(s.obj, s.x, s.y, s.sx, s.sy, s.r)
    return true
end

local function can_apply_undo(entry)
    if not entry or not entry.obj then return false end
    if entry.kind == "delete" then
        return entry.parent and not object_removed(entry.parent)
    end
    return not object_removed(entry.obj)
end

local function can_apply_redo(entry)
    if not entry or not entry.obj then return false end
    if entry.kind == "delete" then
        return not object_removed(entry.obj)
    end
    return not object_removed(entry.obj)
end

local function history_entry_changed(entry)
    if not entry then return false end
    if entry.kind == "delete" then return true end
    if object_removed(entry.obj) then return false end
    return not same_transform(entry.obj, entry.x, entry.y, entry.sx, entry.sy, entry.r)
end

local function push_undo_entry(entry)
    if not history_entry_changed(entry) then return false end
    table.insert(undo, entry)
    trim_stack(undo)
    redo = {}
    return true
end

local function push_redo_entry(entry)
    if not entry then return false end
    table.insert(redo, entry)
    trim_stack(redo)
    return true
end

local function restore_deleted(entry)
    local obj, parent = entry.obj, entry.parent
    if not obj or object_removed(parent) then return false end

    apply_transform(obj, entry.x, entry.y, entry.sx, entry.sy, entry.r)

    if not object_removed(obj) then
        return true
    end

    if parent.children_to_remove then
        parent.children_to_remove[obj] = nil
    end
    remove_all(parent.children, obj)

    local stage = parent.stage
    if stage then
        purge_stage_refs(stage, obj)
    end

    parent:addChild(obj)

    if entry.index and parent.children[#parent.children] == obj then
        table.remove(parent.children)
        table.insert(parent.children, math.min(entry.index, #parent.children + 1), obj)
        parent.update_child_list = true
    end

    return not object_removed(obj)
end

local function remove_deleted(entry)
    if object_removed(entry.obj) then return false end
    local ds = Kristal.DebugSystem
    if ds and ds.object == entry.obj then
        ds:unselectObject()
    end
    entry.obj:remove()
    return true
end

-- Commit any pending (grab/wheel) snapshot to the undo stack.
-- Called when the continuous operation ends: mouse release, new key action, etc.
local function commit_pending_undo()
    if grab_pending then
        push_undo_entry(grab_pending)
        grab_pending = nil
    end
    if wheel_pending then
        push_undo_entry(wheel_pending)
        wheel_pending = nil
    end
end

local function push_undo_values(obj, x, y, sx, sy, r)
    if object_removed(obj) then return end
    commit_pending_undo()  -- flush any pending operation first
    push_undo_entry({ kind = "transform", obj = obj, x = x, y = y, sx = sx, sy = sy, r = r })
end

local function push_undo(obj)
    local s = snap(obj)
    if not s then return end
    push_undo_values(obj, s.x, s.y, s.sx, s.sy, s.r)
end

local function push_delete_undo(obj)
    local s = snap_delete(obj)
    if not s then return end
    commit_pending_undo()
    push_undo_entry(s)
end

local function do_undo()
    while #undo > 0 do
        local s = undo[#undo]
        if not can_apply_undo(s) then
            table.remove(undo)  -- discard stale snapshot
        else
            break
        end
    end
    if #undo == 0 then return end
    local s = table.remove(undo)

    if s.kind == "delete" then
        if restore_deleted(s) then
            push_redo_entry(s)
            if Kristal.DebugSystem then
                Kristal.DebugSystem:selectObject(s.obj)
            end
        end
    else
        local cur = snap(s.obj)
        if cur then push_redo_entry(cur) end
        if unsnap(s) and Kristal.DebugSystem then
            Kristal.DebugSystem:selectObject(s.obj)
        end
    end
end

local function do_redo()
    while #redo > 0 do
        local s = redo[#redo]
        if not can_apply_redo(s) then
            table.remove(redo)
        else
            break
        end
    end
    if #redo == 0 then return end
    local s = table.remove(redo)

    if s.kind == "delete" then
        local cur = snap_delete(s.obj) or s
        if remove_deleted(s) then
            table.insert(undo, cur)
            trim_stack(undo)
        end
    else
        local cur = snap(s.obj)
        if cur then
            table.insert(undo, cur)
            trim_stack(undo)
        end
        if unsnap(s) and Kristal.DebugSystem then
            Kristal.DebugSystem:selectObject(s.obj)
        end
    end
end

local function clear_history()
    undo = {}
    redo = {}
    grab_pending = nil
    wheel_pending = nil
end

-- ============================================================
-- Transform: enter / exit / confirm / cancel
-- ============================================================

local function tf_enter(mode, obj)
    if not obj or obj:isRemoved() then return false end
    TF.mode = mode
    TF.obj = obj
    TF.orig_x, TF.orig_y = obj.x, obj.y
    TF.orig_sx, TF.orig_sy = obj.scale_x, obj.scale_y
    TF.orig_rot = obj.rotation
    TF.undo_x, TF.undo_y = obj.x, obj.y
    TF.undo_sx, TF.undo_sy = obj.scale_x, obj.scale_y
    TF.undo_rot = obj.rotation
    TF.axis = nil
    TF.exclude = false
    TF.num = ""
    TF.has_num = false
    TF.ref_mx, TF.ref_my = Input.getCurrentCursorPosition()
    TF.orig_screen_x, TF.orig_screen_y = obj:getScreenPos()
    -- Release DebugSystem grab so we take over
    if Kristal.DebugSystem then
        Kristal.DebugSystem.grabbing = false
    end
    return true
end

local function tf_switch(mode)
    if TF.mode == TFM.IDLE then return false end
    if TF.obj and not TF.obj:isRemoved() then
        TF.orig_x, TF.orig_y = TF.obj.x, TF.obj.y
        TF.orig_sx, TF.orig_sy = TF.obj.scale_x, TF.obj.scale_y
        TF.orig_rot = TF.obj.rotation
        TF.orig_screen_x, TF.orig_screen_y = TF.obj:getScreenPos()
    end
    TF.mode = mode
    TF.axis = nil
    TF.exclude = false
    TF.num = ""
    TF.has_num = false
    TF.ref_mx, TF.ref_my = Input.getCurrentCursorPosition()
    return true
end

local function tf_exit()
    TF.mode = TFM.IDLE
    TF.obj = nil
    TF.axis = nil
    TF.exclude = false
    TF.num = ""
    TF.has_num = false
end

local function tf_confirm()
    if TF.mode == TFM.IDLE then return end
    if TF.obj and not TF.obj:isRemoved() then
        -- Push pre-transform state to undo (the current transformed state is the new baseline)
        push_undo_values(TF.obj, TF.undo_x, TF.undo_y, TF.undo_sx, TF.undo_sy, TF.undo_rot)
    end
    tf_exit()
end

local function tf_cancel()
    if TF.mode == TFM.IDLE then return end
    if TF.obj and not TF.obj:isRemoved() then
        apply_transform(TF.obj, TF.undo_x, TF.undo_y, TF.undo_sx, TF.undo_sy, TF.undo_rot)
    end
    tf_exit()
end

-- ============================================================
-- Transform: apply from mouse delta
-- ============================================================

local function tf_apply_move(dx, dy)
    local obj = TF.obj
    if not obj or obj:isRemoved() then return end

    local gx, gy = dx, dy

    -- Snap
    if Input.ctrl() then
        local grid = cfg("snap_grid") or 1
        gx = math.floor(gx / grid + 0.5) * grid
        gy = math.floor(gy / grid + 0.5) * grid
    end
    -- Fine
    if Input.shift() then
        local ff = cfg("fine_factor") or 0.1
        gx, gy = gx * ff, gy * ff
    end
    -- Axis
    if TF.axis == "x" then
        if TF.exclude then gx = 0 else gy = 0 end
    elseif TF.axis == "y" then
        if TF.exclude then gy = 0 else gx = 0 end
    end

    if obj.parent then
        obj.x, obj.y = obj.parent:getFullTransform():inverseTransformPoint(TF.orig_screen_x + gx, TF.orig_screen_y + gy)
    else
        obj.x = TF.orig_x + gx
        obj.y = TF.orig_y + gy
    end
    uncache_object(obj)
end

local function tf_apply_rotate(mx, my)
    local obj = TF.obj
    if not obj or obj:isRemoved() then return end

    local cx, cy = object_rotation_origin_screen_pos(obj)
    if not cx then return end

    local a0 = atan2(TF.ref_my - cy, TF.ref_mx - cx)
    local a1 = atan2(my - cy, mx - cx)
    local da = a1 - a0
    if da > math.pi then da = da - 2 * math.pi end
    if da < -math.pi then da = da + 2 * math.pi end

    if Input.ctrl() then
        local snap_deg = cfg("snap_angle") or 5
        local snap_rad = math.rad(snap_deg)
        da = math.floor(da / snap_rad + 0.5) * snap_rad
    end
    if Input.shift() then
        da = da * (cfg("fine_factor") or 0.1)
    end

    obj.rotation = TF.orig_rot + da
    uncache_object(obj)
end

local function tf_apply_scale(dx)
    local obj = TF.obj
    if not obj or obj:isRemoved() then return end

    local factor = 1.0 + dx * 0.01
    if Input.shift() then
        factor = 1.0 + dx * 0.01 * (cfg("fine_factor") or 0.1)
    end

    local sx = TF.orig_sx * factor
    local sy = TF.orig_sy * factor

    if TF.axis == "x" then
        if TF.exclude then sx = TF.orig_sx else sy = TF.orig_sy end
    elseif TF.axis == "y" then
        if TF.exclude then sy = TF.orig_sy else sx = TF.orig_sx end
    end

    if Input.ctrl() then
        local snap_s = cfg("snap_scale") or 0.1
        sx = math.floor(sx / snap_s + 0.5) * snap_s
        sy = math.floor(sy / snap_s + 0.5) * snap_s
    end

    obj.scale_x = math.max(0.01, sx)
    obj.scale_y = math.max(0.01, sy)
    uncache_object(obj)
end

-- ============================================================
-- Transform: numeric apply
-- ============================================================

local function tf_num_move(val)
    local obj = TF.obj
    if not obj or obj:isRemoved() then return end
    local gx, gy = 0, 0
    if TF.axis == "x" then
        if TF.exclude then gy = val else gx = val end
    elseif TF.axis == "y" then
        if TF.exclude then gx = val else gy = val end
    else
        gx = val
    end
    if obj.parent then
        obj.x, obj.y = obj.parent:getFullTransform():inverseTransformPoint(TF.orig_screen_x + gx, TF.orig_screen_y + gy)
    else
        obj.x = TF.orig_x + gx
        obj.y = TF.orig_y + gy
    end
    uncache_object(obj)
end

local function tf_num_rotate(val)
    local obj = TF.obj
    if not obj or obj:isRemoved() then return end
    obj.rotation = TF.orig_rot + math.rad(val)
    uncache_object(obj)
end

local function tf_num_scale(val)
    local obj = TF.obj
    if not obj or obj:isRemoved() then return end
    local sx = TF.orig_sx * val
    local sy = TF.orig_sy * val
    if TF.axis == "x" then
        if TF.exclude then sx = TF.orig_sx else sy = TF.orig_sy end
    elseif TF.axis == "y" then
        if TF.exclude then sy = TF.orig_sy else sx = TF.orig_sx end
    end
    obj.scale_x = math.max(0.01, sx)
    obj.scale_y = math.max(0.01, sy)
    uncache_object(obj)
end

local function tf_num_replay()
    if TF.num == "" then
        if TF.obj and not TF.obj:isRemoved() then
            if TF.mode == TFM.GRAB then
                TF.obj.x = TF.orig_x; TF.obj.y = TF.orig_y
            elseif TF.mode == TFM.ROTATE then
                TF.obj.rotation = TF.orig_rot
            elseif TF.mode == TFM.SCALE then
                TF.obj.scale_x = TF.orig_sx; TF.obj.scale_y = TF.orig_sy
            end
            uncache_object(TF.obj)
        end
        return
    end
    local val = tonumber(TF.num)
    if not val then return end
    if TF.mode == TFM.GRAB then tf_num_move(val)
    elseif TF.mode == TFM.ROTATE then tf_num_rotate(val)
    elseif TF.mode == TFM.SCALE then tf_num_scale(val)
    end
end

local function tf_num_push(c)
    if c == "-" then
        if #TF.num > 0 then return end  -- only at start
    elseif c == "." then
        if TF.num:find("%.") then return end
    end
    TF.num = TF.num .. c
    TF.has_num = true
    tf_num_replay()
end

local function tf_num_backspace()
    if TF.num == "" then return end
    TF.num = TF.num:sub(1, -2)
    if TF.num == "-" then TF.num = "" end
    tf_num_replay()
end

local function mark_key_event_handled(key, is_repeat)
    handled_key_event = { key = key, is_repeat = is_repeat, runtime = RUNTIME }
end

local function consume_marked_key_event(key, is_repeat)
    local event = handled_key_event
    if event
    and event.key == key
    and event.is_repeat == is_repeat
    and event.runtime == RUNTIME then
        handled_key_event = nil
        return true
    end
    return false
end

local function mark_wheel_event_handled(wx, wy)
    handled_wheel_event = { wx = wx, wy = wy, runtime = RUNTIME }
end

local function consume_marked_wheel_event(wx, wy)
    local event = handled_wheel_event
    if event
    and event.wx == wx
    and event.wy == wy
    and event.runtime == RUNTIME then
        handled_wheel_event = nil
        return true
    end
    return false
end

local function selection_timestop_enabled(ds)
    return ds
        and ds.state == "SELECTION"
        and Kristal.Config["objectSelectionSlowdown"]
end

local function arrow_nudge_delta(key)
    if Input.is("left", key) then
        return -1, 0
    elseif Input.is("right", key) then
        return 1, 0
    elseif Input.is("up", key) then
        return 0, -1
    elseif Input.is("down", key) then
        return 0, 1
    end
end

local function nudge_selected_object(ds, key)
    if TF.mode ~= TFM.IDLE or not selection_timestop_enabled(ds) then
        return false
    end

    local obj = ds.object
    if not obj or obj:isRemoved() then
        return false
    end

    local dx, dy = arrow_nudge_delta(key)
    if not dx or not dy then
        return false
    end

    local before = snap(obj)
    local screen_x, screen_y = obj:getScreenPos()
    obj:setScreenPos(screen_x + dx, screen_y + dy)
    uncache_object(obj)
    if before then
        push_undo_entry(before)
    end
    return true
end

-- ============================================================
-- KRISTAL_EVENT: onKeyPressed
-- ============================================================

local function handle_key_pressed(key, is_repeat)
    local ds = Kristal.DebugSystem
    if not ds or ds.state ~= "SELECTION" then return false end
    if editor_input_blocked(ds) then
        commit_pending_undo()
        if TF.mode ~= TFM.IDLE then tf_cancel() end
        return false
    end

    if is_repeat then
        return nudge_selected_object(ds, key)
    end

    -- Flush pending wheel/grab undo before any key action
    commit_pending_undo()

    -- ---- Undo / Redo ----
    if Input.ctrl() and not Input.shift() and key == "z" then
        do_undo(); return true
    end
    if (Input.ctrl() and key == "y") or (Input.ctrl() and Input.shift() and key == "z") then
        do_redo(); return true
    end

    -- ---- Delete with undo ----
    if key == "delete" and ds.object and TF.mode == TFM.IDLE then
        local obj = ds.object
        push_delete_undo(obj)
        ds:unselectObject()
        obj:remove()
        return true
    end

    -- ---- Pixel nudge selected object while Object Selector timestop is enabled ----
    if nudge_selected_object(ds, key) then
        return true
    end

    -- ---- In transform mode ----
    if TF.mode ~= TFM.IDLE then
        -- Cancel
        if key == "escape" then
            tf_cancel(); return true
        end

        -- Confirm
        if key == "return" then
            tf_confirm(); return true
        end

        -- Re-press same mode key toggles confirm (Blender convention)
        if (key == "g" and TF.mode == TFM.GRAB)
        or (key == "r" and TF.mode == TFM.ROTATE)
        or (key == "s" and TF.mode == TFM.SCALE) then
            tf_confirm(); return true
        end

        -- Switch mode directly (G→R, R→S, etc.)
        if key == "g" and TF.mode ~= TFM.GRAB then
            tf_switch(TFM.GRAB); return true
        elseif key == "r" and TF.mode ~= TFM.ROTATE then
            tf_switch(TFM.ROTATE); return true
        elseif key == "s" and TF.mode ~= TFM.SCALE then
            tf_switch(TFM.SCALE); return true
        end

        -- Axis constraint (Grab and Scale modes; Rotate has no axis in 2D)
        if (TF.mode == TFM.GRAB or TF.mode == TFM.SCALE) and not TF.has_num then
            if key == "x" then
                if Input.shift() then
                    TF.axis = "x"; TF.exclude = true
                elseif TF.axis == "x" and not TF.exclude then
                    TF.axis = nil; TF.exclude = false
                else
                    TF.axis = "x"; TF.exclude = false
                end
                -- Re-apply from original
                if TF.mode == TFM.GRAB then
                    local mx, my = Input.getCurrentCursorPosition()
                    tf_apply_move(mx - TF.ref_mx, my - TF.ref_my)
                else
                    local mx = Input.getCurrentCursorPosition()
                    tf_apply_scale(mx - TF.ref_mx)
                end
                return true
            end
            if key == "y" then
                if Input.shift() then
                    TF.axis = "y"; TF.exclude = true
                elseif TF.axis == "y" and not TF.exclude then
                    TF.axis = nil; TF.exclude = false
                else
                    TF.axis = "y"; TF.exclude = false
                end
                if TF.mode == TFM.GRAB then
                    local mx, my = Input.getCurrentCursorPosition()
                    tf_apply_move(mx - TF.ref_mx, my - TF.ref_my)
                else
                    local mx = Input.getCurrentCursorPosition()
                    tf_apply_scale(mx - TF.ref_mx)
                end
                return true
            end
        end

        -- Numeric input
        if key == "backspace" then
            tf_num_backspace(); return true
        end
        if (key >= "0" and key <= "9") or key == "." or key == "-" then
            tf_num_push(key); return true
        end

        -- Consume all other keys during transform
        return true
    end

    -- ---- Enter transform mode ----
    local obj = ds.object
    if not obj or obj:isRemoved() then return false end

    if key == "g" then
        tf_enter(TFM.GRAB, obj); return true
    elseif key == "r" then
        tf_enter(TFM.ROTATE, obj); return true
    elseif key == "s" then
        tf_enter(TFM.SCALE, obj); return true
    end

    return false
end

function lib:onKeyPressed(key, is_repeat)
    if handle_key_pressed(key, is_repeat) then
        mark_key_event_handled(key, is_repeat)
        return true
    end
end

-- ============================================================
-- KRISTAL_EVENT: onMouseMoved
-- ============================================================

function lib:onMouseMoved(x, y, dx, dy, istouch)
    if TF.mode == TFM.IDLE then return end
    if editor_input_blocked() then tf_cancel(); return end
    if not TF.obj or TF.obj:isRemoved() then tf_exit(); return end
    if TF.has_num then return end  -- numeric mode: mouse doesn't transform

    local mx, my = Input.getCurrentCursorPosition()

    if TF.mode == TFM.GRAB then
        tf_apply_move(mx - TF.ref_mx, my - TF.ref_my)
    elseif TF.mode == TFM.ROTATE then
        tf_apply_rotate(mx, my)
    elseif TF.mode == TFM.SCALE then
        tf_apply_scale(mx - TF.ref_mx)
    end
end

-- ============================================================
-- KRISTAL_EVENT: onWheelMoved  (quick scale / rotate)
-- ============================================================

function lib:onWheelMoved(wx, wy)
    if consume_marked_wheel_event(wx, wy) then
        return true
    end

    local ds = Kristal.DebugSystem
    if not ds or ds.state ~= "SELECTION" then return false end
    if editor_input_blocked(ds) then
        commit_pending_undo()
        if TF.mode ~= TFM.IDLE then tf_cancel() end
        return false
    end
    if TF.mode ~= TFM.IDLE then return true end

    local obj = ds.object
    if not obj then obj = ds:detectObject(Input.getCurrentCursorPosition()) end
    if not obj or obj:isRemoved() then return false end

    -- Save pre-wheel state only once per wheel "session"
    if wheel_pending and wheel_pending.obj ~= obj then
        commit_pending_undo()
    end

    if not wheel_pending then
        wheel_pending = snap(obj)
    end

    if Input.ctrl() then
        local step = math.rad(cfg("wheel_rotate_step") or 5)
        obj.rotation = obj.rotation + wy * step
    else
        local step = cfg("wheel_scale_step") or 0.1
        local f = 1.0 + wy * step
        obj:setScale(
            math.max(0.01, obj.scale_x * f),
            math.max(0.01, obj.scale_y * f)
        )
    end
    uncache_object(obj)
    return true
end

-- ============================================================
-- KRISTAL_EVENT: onMousePressed  (drag-start undo snapshot)
-- ============================================================

function lib:onMousePressed(x, y, button, istouch, presses)
    -- During transform mode, handled by monkey-patch
    if TF.mode ~= TFM.IDLE then return end

    local ds = Kristal.DebugSystem
    if not ds or ds.state ~= "SELECTION" then return end
    if editor_input_blocked(ds) then return end
    if ds.__object_editor_patched then return end

    -- Flush pending wheel undo before starting a new operation
    commit_pending_undo()

    -- Save pre-grab state (committed on mouse release, not now)
    if button == 1 and ds.grabbing and ds.object then
        grab_pending = snap(ds.object)
    end
end

-- ============================================================
-- KRISTAL_EVENT: onMouseReleased  (commit grab undo)
-- ============================================================

function lib:onMouseReleased(x, y, button, istouch, presses)
    local ds = Kristal.DebugSystem
    if ds and ds.__object_editor_patched then return end
    if editor_input_blocked(ds) then return end

    -- Commit pending grab undo when the drag ends
    if grab_pending and button == 1 then
        commit_pending_undo()
    end
end

-- ============================================================
-- KRISTAL_EVENT: postDraw  (transform overlay)
-- ============================================================

local MODE_NAMES = { [TFM.GRAB] = "MOVE", [TFM.ROTATE] = "ROTATE", [TFM.SCALE] = "SCALE" }

function lib:postDraw()
    if TF.mode == TFM.IDLE then return end

    local font = Assets.getFont("main", 18)
    love.graphics.setFont(font)

    local parts = { MODE_NAMES[TF.mode] or "?" }

    if TF.axis and (TF.mode == TFM.GRAB or TF.mode == TFM.SCALE) then
        local label = TF.exclude and ("-" .. TF.axis:upper()) or TF.axis:upper()
        table.insert(parts, "[" .. label .. "]")
    end

    if TF.has_num and TF.num ~= "" then
        table.insert(parts, TF.num)
    end

    table.insert(parts, "| LMB/Enter=OK  RMB/Esc=Cancel")

    local text = table.concat(parts, " ")
    local tw = font:getWidth(text)
    local tx = (SCREEN_WIDTH - tw) / 2
    local ty = SCREEN_HEIGHT - 40

    Draw.setColor(0, 0, 0, 0.7)
    love.graphics.print(text, tx + 2, ty + 2)
    Draw.setColor(1, 1, 0.6, 1)
    love.graphics.print(text, tx, ty)

    -- Axis guides
    if TF.mode == TFM.GRAB and TF.obj and not TF.obj:isRemoved() then
        local obj = TF.obj
        local cx, cy = object_origin_screen_pos(obj)
        if not cx then return end

        love.graphics.setLineWidth(1)
        local BIG = 99999

        local show_x = (not TF.axis) or (TF.axis == "x" and not TF.exclude) or (TF.axis == "y" and TF.exclude)
        local show_y = (not TF.axis) or (TF.axis == "y" and not TF.exclude) or (TF.axis == "x" and TF.exclude)

        if show_x then
            Draw.setColor(1, 0.2, 0.2, 0.5)
            love.graphics.line(cx - BIG, cy, cx + BIG, cy)
        end
        if show_y then
            Draw.setColor(0.2, 1, 0.2, 0.5)
            love.graphics.line(cx, cy - BIG, cx, cy + BIG)
        end
    end
end

-- ============================================================
-- Init: monkey-patches for DebugSystem integration
-- ============================================================

patch_debug_system = function(ds)
    if not ds then return end

    if ds.__object_editor_originals then
        local originals = ds.__object_editor_originals
        ds.onStateChange = originals.onStateChange
        ds.onMousePressed = originals.onMousePressed
        ds.onMouseReleased = originals.onMouseReleased
        ds.onKeyPressed = originals.onKeyPressed
        ds.onWheelMoved = originals.onWheelMoved
    end

    local _orig_onStateChange = ds.onStateChange
    local _orig_onMousePressed = ds.onMousePressed
    local _orig_onMouseReleased = ds.onMouseReleased
    local _orig_onKeyPressed = ds.onKeyPressed
    local _orig_onWheelMoved = ds.onWheelMoved

    ds.__object_editor_originals = {
        onStateChange = _orig_onStateChange,
        onMousePressed = _orig_onMousePressed,
        onMouseReleased = _orig_onMouseReleased,
        onKeyPressed = _orig_onKeyPressed,
        onWheelMoved = _orig_onWheelMoved,
    }
    ds.__object_editor_patched = true

    -- Patch 1: onStateChange -> clear history + cancel transform on exit SELECTION
    function ds:onStateChange(old, new)
        _orig_onStateChange(self, old, new)
        if new ~= "SELECTION" then
            if TF.mode ~= TFM.IDLE then tf_cancel() end
            clear_history()
        end
    end

    -- Patch 2: onMousePressed -> intercept transform mode and capture drag starts
    function ds:onMousePressed(x, y, button, istouch, presses)
        if console_open() then
            commit_pending_undo()
            if TF.mode ~= TFM.IDLE then tf_cancel() end
            return
        end

        if editor_input_blocked(self) then
            commit_pending_undo()
            if TF.mode ~= TFM.IDLE then tf_cancel() end
            return _orig_onMousePressed(self, x, y, button, istouch, presses)
        end

        if TF.mode ~= TFM.IDLE then
            if TF.obj and not TF.obj:isRemoved() then
                self:selectObject(TF.obj)
            end
            if button == 1 then
                tf_confirm()
            elseif button == 2 or button == 3 then
                tf_cancel()
            end
            return
        end

        commit_pending_undo()

        local before_object = self.object
        local before_snap = nil
        if button == 1 and before_object and not before_object:isRemoved() then
            before_snap = snap(before_object)
        end

        local result = _orig_onMousePressed(self, x, y, button, istouch, presses)

        if button == 1 and self.grabbing and self.object and not self.object:isRemoved() then
            if before_snap and before_snap.obj == self.object then
                grab_pending = before_snap
            else
                grab_pending = snap(self.object)
            end
        end

        return result
    end

    -- Patch 3: onMouseReleased -> commit drag undo after DebugSystem stops moving
    function ds:onMouseReleased(x, y, button, istouch, presses)
        if TF.mode ~= TFM.IDLE then return end
        local result = _orig_onMouseReleased(self, x, y, button, istouch, presses)
        if grab_pending and button == 1 then
            commit_pending_undo()
        end
        return result
    end

    -- Patch 4: onKeyPressed -> make editor keys win over DebugSystem defaults
    function ds:onKeyPressed(key, is_repeat)
        if console_open() then
            commit_pending_undo()
            if TF.mode ~= TFM.IDLE then tf_cancel() end
            return
        end

        if consume_marked_key_event(key, is_repeat) then
            return
        end
        if handle_key_pressed(key, is_repeat) then
            return
        end
        return _orig_onKeyPressed(self, key, is_repeat)
    end

    -- Patch 5: onWheelMoved -> quick transform without double-applying via Game events
    function ds:onWheelMoved(wx, wy)
        if console_open() then
            commit_pending_undo()
            if TF.mode ~= TFM.IDLE then tf_cancel() end
            return
        end

        if lib:onWheelMoved(wx, wy) then
            mark_wheel_event_handled(wx, wy)
            return
        end
        return _orig_onWheelMoved(self, wx, wy)
    end
end

function lib:init()
    local ds = Kristal.DebugSystem
    if not ds then return end
    patch_debug_system(ds)
end

return lib
