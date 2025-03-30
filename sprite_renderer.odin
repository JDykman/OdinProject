package main

// The code not really relevant to the rendering, like defining our sprites,
// tick and input can be found in `non_renderer_code.odin`

import "base:runtime"

import "core:c"
import "core:fmt"
import "core:slice"
import "core:time"

import stbi "vendor:stb/image"

import sapp "shared:sokol/app"
import sg "shared:sokol/gfx"
import sglue "shared:sokol/glue"
import slog "shared:sokol/log"

import "shaders"

// I just like having this so I don't accidentally define my quads incorrectly
QUAD_INDEX_SIZE :: 6

BUDGET_SPRITES :: 1024

Sprite_Batch :: struct {
    // Odin uses manual memory management but there is no memory to manage if it's in "rodata" heh!
    // We could also use `[dynamic]` in combination with the `temp_allocator` and begin our frame with
    // `defer free_all(context.temp_allocator)`, whatever floats your boat.
    // I like the idea of having a "budget" for small games.
    // https://odin-lang.org/docs/overview/#allocators
    instances: [BUDGET_SPRITES]Sprite_Instance,
    len:       uint,
}

// This is the thing we will upload to the GPU!
Sprite_Instance :: struct {
    location: [2]f32,
    size:     [2]f32,
    position: [2]f32,
    scale:    [2]f32,
    color:    [4]f32,
}

// This is what we render our game to
Offscreen :: struct {
    pixel_to_viewport_multiplier: [2]f32,
    sprite_atlas_size:            [2]i32,
    pass:                         sg.Pass,
    pipeline:                     sg.Pipeline,
    bindings:                     sg.Bindings,
}

// Our display scales up the `Offscreen` to match our physical display
Display :: struct {
    pass_action: sg.Pass_Action,
    pipeline:    sg.Pipeline,
    bindings:    sg.Bindings,
}

Renderer :: struct {
    offscreen:    Offscreen,
    display:      Display,
    sprite_batch: Sprite_Batch,
}

///////////////////////////////////////////////////////////////////////////////

// Global struct to store the things we need to render
renderer: Renderer

// see `not_renderer_code.odin`
timer: Timer
input: Input

///////////////////////////////////////////////////////////////////////////////

////////////////////////////////////////////////////////////////////////////////
// Draw a sprite by adding it to the sprite batch for the upcoming frame
// position: X and Y coordinates with {0, 0} being bottom-left - I like this for platformers, I guess???
// scale:    Scale of the sprite being rendered
// color:    Color multiplier of the sprite, {255, 255, 255, 1} format
// location: Location in the sprite sheet with {0, 0} being top-left
// size:     Size of the area of the sprite sheet to render
gfx_draw_sprite :: proc(
    position: [2]f32,
    scale: [2]i32 = {1, 1},
    color: [4]f32 = {255, 255, 255, 1},
    location: [2]u16,
    size: [2]u16,
    sprite_batch: ^Sprite_Batch,
) {
    if sprite_batch.len > BUDGET_SPRITES do return

    vertex: Sprite_Instance = {
        location = {f32(location.x), f32(location.y)},
        size     = {f32(size.x), f32(size.y)},
        position = {f32(position.x), f32(position.y)},
        scale    = {f32(scale.x), f32(scale.y)},
        color    = color,
    }
    sprite_batch.instances[sprite_batch.len] = vertex
    sprite_batch.len += 1
}

////////////////////////////////////////////////////////////////////////////////
// Multiplier to convert from from pixel to viewport coordinates
gfx_get_pixel_to_viewport_multiplier :: proc(
    display_width, display_height: f32,
) -> [2]f32 {
    // some Y-axis flipping to put {0, 0} at the bottom-left
    return {2 / display_width, -2 / display_height}
}

////////////////////////////////////////////////////////////////////////////////
// Get viewport size to the largest pixel perfect resolution given game size
gfx_get_pixel_perfect_viewport :: proc(
    display_width, display_height, dpi_scale: f32,
    resolution_scale: u16,
) -> [4]f32 {
    width := display_width / dpi_scale
    height := display_height / dpi_scale

    game_width := GAME_WIDTH * f32(resolution_scale)
    game_height := GAME_HEIGHT * f32(resolution_scale)

    vp_x := dpi_scale * (width - game_width) / 2
    vp_y := dpi_scale * (height - game_height) / 2
    vp_w := dpi_scale * game_width
    vp_h := dpi_scale * game_height

    return {vp_x, vp_y, vp_w, vp_h}
}

////////////////////////////////////////////////////////////////////////////////
// Get the largest possible resolution scaling based on display and GAME size
// For example running on a 1440p monitor will result in a resolution scaling of
// 8 x 180 = 1440 -> 8
gfx_get_resolution_scaling :: proc(
    display_width, display_height, dpi_scale: f32,
) -> u16 {
    width := display_width / dpi_scale
    height := display_height / dpi_scale

    display_aspect := width / height
    offscreen_aspect := f32(GAME_WIDTH / GAME_HEIGHT)

    res :=
        u16(height / GAME_HEIGHT) if offscreen_aspect < display_aspect else u16(width / GAME_WIDTH)

    return res if res > 1 else 1
}

////////////////////////////////////////////////////////////////////////////////
// Convert common types to sokol_gfx Range
// https://odin-lang.org/docs/overview/#explicit-procedure-overloading
as_range :: proc {
    slice_as_range,
    dynamic_array_as_range,
    array_ptr_as_range,
}

// https://odin-lang.org/docs/overview/#parametric-polymorphism
// https://odin-lang.org/docs/overview/#calling-conventions
slice_as_range :: proc "contextless" (val: $T/[]$E) -> (range: sg.Range) {
    range.ptr = raw_data(val)
    range.size = c.size_t(len(val)) * size_of(E)
    return
}

dynamic_array_as_range :: proc "contextless" (
    val: $T/[dynamic]$E,
) -> (
    range: sg.Range,
) {
    range.ptr = raw_data(val)
    range.size = u64(len(val)) * size_of(E)
    return
}

array_ptr_as_range :: proc "contextless" (
    val: ^$T/[$N]$E,
) -> (
    range: sg.Range,
) {
    range.ptr = raw_data(val)
    range.size = c.size_t(len(val)) * size_of(E)
    return
}

// main :: proc() {
//     sapp.run(
//         {
//             init_cb = init,
//             frame_cb = frame,
//             event_cb = event,
//             high_dpi = true,
//             window_title = "odin-sprite-renderer",
//             logger = {func = slog.func},
//         },
//     )
// }
