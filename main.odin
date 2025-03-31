package main

import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:math"
import "core:math/rand"
import "core:math/linalg"
import "core:math/noise"
import stbi "vendor:stb/image"
import sapp "shared:sokol/app"
import shelpers "shared:sokol/helpers"
import sg "shared:sokol/gfx"
import fmt "core:fmt"
import sglue "shared:sokol/glue"
import slog "shared:sokol/log"
import "shaders"
import "core:c"
import "core:time"

// Debug logging that only prints in development builds
debug_print :: proc(args: ..any) {
    when DEBUG_MODE {
        fmt.println(..args)
    }
}

// For format strings
debug_printf :: proc(format: string, args: ..any) {
    when DEBUG_MODE {
        fmt.printf(format, ..args)
    }
}

// Set to true for development features, false for release
DEBUG_MODE :: #config(DEBUG, true)

// Runtime constant that can be checked by any code
IS_DEV_BUILD :: DEBUG_MODE

default_context: runtime.Context

Globals :: struct {
    world_size: Vec2f,
}
g := new(Globals)

// Our renderer will have a resolution of 320x180, 16:9
// - 40 tiles wide
// - 22.5 tiles high, with the half tile being on the top
TILES_X :: 40
TILES_Y :: 22.5
TILE_UNIT :: 16
GAME_WIDTH :: TILES_X * TILE_UNIT
GAME_HEIGHT :: TILES_Y * TILE_UNIT

SPRITES :: #partial [Sprite_Name]Sprite {
    .PINK_MONSTER = {
        frames = {{0, 0}, {19, 0}, {38, 0}, {0, 28}, {19, 28}, {38, 28}},
        size = {19, 28},
    },
    .NONE = {
        frames = {},
        size = {},
    },
    .DIRT = {
        frames = {{0*BLOCK_SIZE, 0*BLOCK_SIZE}},
        size = {BLOCK_SIZE, BLOCK_SIZE},
    },
    .STONE = {
        frames = {{8*BLOCK_SIZE, 0*BLOCK_SIZE}},
        size = {BLOCK_SIZE, BLOCK_SIZE},
    },

}

//// Vector Types ////
// Vector types for 2D and 4D (RGBA) values.
Vec2f :: struct {
    x, y: f32,
}

vec2f :: proc(x, y: f32) -> Vec2f {
    return Vec2f{x, y}
}

Vec2i :: struct {
    x: i32,
    y: i32,
}

Vec3 :: struct {
    x, y, z: f32,
}

vec3 :: proc(x, y, z: f32) -> Vec3 {
    return Vec3{x, y, z}
}

Vec4 :: struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
}

// Matrix types
Mat4 :: [16]f32

// Uniforms for sanity
Pos :: [2]f32
Color :: [4]f32
Scale :: [2]i32

Coroutine :: struct {
    active: bool,
    update: proc(^Coroutine) -> bool,
    data: rawptr,
}

coroutines: [dynamic]^Coroutine

init_coroutines :: proc() {
    coroutines = make([dynamic]^Coroutine)
}

update_coroutines :: proc() {
    for coroutine, idx in coroutines {
        if coroutine.active {
            still_running := coroutine.update(coroutine)
            coroutine.active = still_running
            if !still_running {
                delete_coroutine(idx)
            }
        }
    }
}

add_coroutine :: proc(update_fn: proc(^Coroutine) -> bool, data: rawptr = nil) {
    coroutine := new(Coroutine)
    coroutine.active = true
    coroutine.update = update_fn
    coroutine.data = data
    append(&coroutines, coroutine)
}

delete_coroutine :: proc(idx: int) {
    remove_ordered(&coroutines, idx)
}

remove_ordered :: proc(array: ^[dynamic]^Coroutine, index: int) {
    if len(array^) == 0 || index < 0 || index >= len(array^) {
        return
    }

    copy(array^[index:], array^[index+1:])
    resize(array, len(array^) - 1)
}

// Timer structure for animations
Timer :: struct {
    animation: u64,
    current:   time.Time,
}

// Some helpers to easily store our sprite atlas locations for rendering
Sprite_To_Render :: struct {
    position: Pos,
    color:    Color,
    scale:    Scale,
    sprite:   Sprite,
}

Sprite :: struct {
    frames: [][2]u16,
    size:   [2]u16,
}

Sprite_Name :: enum {
    NONE,
    PINK_MONSTER,
    DIRT,
    STONE,
}

player: Player = Player{
    position = {f32(GAME_WIDTH/2), f32(GAME_HEIGHT/2)}, // Center of screen
    sprite = SPRITES[.PINK_MONSTER],
    color = {255, 255, 255, 1},
    scale = {1, 1},
    facingRight = true,
    velocity = {0, 0},
    health = 100.0,
}

Player :: struct {
    position: Pos,
    sprite : Sprite,
    color : Color,
    scale : Scale,
    facingRight : bool,
    velocity: Vec2f,
    health:   f32,
}

// Block structure: each block (or pixel) in our simulation.
Block :: struct {
    Type:         int,   // Block type: air, dirt, stone, water, etc.
    Sprite:       Sprite, // Sprite to render
    Density:      f32,   // For physics-based interactions
    Color:        Color,  // RGBA color for rendering
    Health:       f32,   // Durability, used for damage or decay simulation
    Velocity:     Vec2f,  // Dynamic movement (for falling or fluid behavior)
    Temperature:  f32,   // For thermal effects (melting, burning, etc.)
    Flags:        int,   // Bitmask for extra properties (flammable, liquid, etc.)
}

Camera :: struct {
    position: Vec2f,  // Camera position in world space
    target: ^Player,  // Optional target to follow (can be nil)
    bounds: struct {  // Optional camera bounds
        min_x, min_y: f32,
        max_x, max_y: f32,
    },
    smoothing: f32,   // Camera movement smoothing factor (0-1)
    zoom: f32,        // Future expansion: camera zoom
}

// Global camera instance
camera: Camera

// Block type constants.
BLOCK_AIR : Block = {
    Type = 0,
    Density = 0.0,
    Color = {0, 0, 0, 0},
    Health = 0.0,
    Velocity = {0, 0},
    Temperature = 0.0,
    Flags = 0
}
BLOCK_DIRT : Block = {
    Type = 1,
    Density = 1.0,
    Color = {0.5, 0.3, 0.1, 1.0},
    Health = 1.0,
    Velocity = {0, 0},
    Temperature = 0.0,
    Flags = 0
}
BLOCK_STONE : Block = {
    Type = 2,
    Density = 2.0,
    Color = {0.5, 0.5, 0.5, 1.0},
    Health = 2.0,
    Velocity = {0, 0},
    Temperature = 0.0,
    Flags = 0
}
BLOCK_WATER : Block = {
    Type = 3,
    Density = 1.0,
    Color = {0.0, 0.0, 1.0, 0.5},
    Health = 1.0,
    Velocity = {0, 0},
    Temperature = 0.0,
    Flags = FLAG_IS_LIQUID
}

FLAG_IS_FLAMMABLE := 1 << 0
FLAG_IS_LIQUID    := 1 << 1


// World generation parameters.

BLOCK_SIZE :: 16 // Block size (in pixels)
WORLD_WIDTH  :: 50 // Width of the world (in pixels)
WORLD_HEIGHT :: 23  // At least as tall as game view (22.5 tiles)

World :: struct {
    width: int, // Width in blocks
    height: int, // Height in blocks
    seed: i64,
    noiseFreq: f32,
    worldGrid: [][]Block,
}
w : World

WORLD_SEED: i64 = 0
WORLD_NOISE_FREQ: f32 = 0.1

// Some sprites to render
// `[?]` to infer the fixed array length.
// https://odin-lang.org/docs/overview/#fixed-arrays

// ITEM_WIDTH
// ITEM_INDEX
sprites_to_render := make([dynamic]Sprite_To_Render)

//// Math Shit ////
easeInSine :: proc(x: f32) -> f32{
    return 1 - math.cos_f32((x * math.PI) / 2)
}

easeOutSine :: proc(x: f32) -> f32{
    return math.sin_f32((x * math.PI) / 2)
}


FlipPlayer :: proc(p : ^Player) {
    p.scale = {-p.scale.x, p.scale.y}
}

// Initialize the Sokol application
init_cb :: proc "c" () {
    context = default_context

    player.position = {WORLD_WIDTH * BLOCK_SIZE / 2, WORLD_HEIGHT * BLOCK_SIZE / 2} // Place player at center of world

    sg.setup({
		environment = shelpers.glue_environment(),
		allocator = sg.Allocator(shelpers.allocator(&default_context)),
		logger = sg.Logger(shelpers.logger(&default_context)),
	})
    sapp.show_mouse(true)

    init_coroutines()

    assert(GAME_WIDTH > 0, fmt.tprintf("game_width > 0: %v", GAME_WIDTH))
    assert(GAME_HEIGHT > 0, fmt.tprintf("game_height > 0: %v", GAME_HEIGHT))

    init_renderer(GAME_WIDTH, GAME_HEIGHT)
    fmt.println("Sprite atlas initialized with size:", renderer.offscreen.sprite_atlas_size)

    // Initialize camera
    camera = Camera{
        position = {GAME_WIDTH/2, GAME_HEIGHT/2},  // Start at center of game
        target = &player,                          // Follow the player
        bounds = {
            min_x = 0, min_y = 0,
            // Apply max function directly in the initialization
            max_x = max(0, WORLD_WIDTH * BLOCK_SIZE - GAME_WIDTH),
            max_y = max(0, WORLD_HEIGHT * BLOCK_SIZE - GAME_HEIGHT),
        },
        smoothing = 0.1,   // Slight smoothing for nice feel (0=instant, 1=no movement)
        zoom = 1.0,        // Default zoom level
    }

    // Ensure viewport multiplier is initialized properly
    renderer.offscreen.pixel_to_viewport_multiplier = 
        gfx_get_pixel_to_viewport_multiplier(GAME_WIDTH, GAME_HEIGHT)

    frame_cb() // Force a frame update to apply initial camera position
}
update_camera :: proc() {
    // If we have a target, camera follows it
    if camera.target != nil {
        // Calculate desired position (center the target)
        target_x := camera.target.position[0] - GAME_WIDTH/2
        target_y := camera.target.position[1] - GAME_HEIGHT/2
        
        // Apply smoothing
        if camera.smoothing > 0 {
            camera.position.x = math.lerp(camera.position.x, target_x, 1 - camera.smoothing)
            camera.position.y = math.lerp(camera.position.y, target_y, 1 - camera.smoothing)
        } else {
            camera.position.x = target_x
            camera.position.y = target_y
        }
    }
    
    // Apply bounds constraints
    camera.position.x = math.clamp(camera.position.x, camera.bounds.min_x, camera.bounds.max_x)
    camera.position.y = math.clamp(camera.position.y, camera.bounds.min_y, camera.bounds.max_y)
}
world_to_screen :: proc(world_pos: [2]f32) -> [2]f32 {
    screen_x := world_pos[0] - camera.position.x
    screen_y := world_pos[1] - camera.position.y
    return {screen_x, screen_y}
}
draw_world_sprite :: proc(
    world_pos: [2]f32, 
    sprite: Sprite,
    scale := Scale{1,1}, 
    color := Color{255, 255, 255, 1}
) {
    screen_pos := world_to_screen(world_pos)
    
    // Only draw if on screen (basic culling)
    // Cast sprite size from u16 to f32 to match screen_pos type
    if screen_pos[0] > -f32(sprite.size[0]) && screen_pos[0] < GAME_WIDTH &&
       screen_pos[1] > -f32(sprite.size[1]) && screen_pos[1] < GAME_HEIGHT {
        append(&sprites_to_render, Sprite_To_Render{
            position = screen_pos,
            sprite   = sprite,
            scale    = scale,
            color    = color,
        })
    }
}
// Frame update function
frame_cb :: proc "c" () {
    context = runtime.default_context()

    ////////////////////////////////////////////////////////////////////////////
    // Timers & Input
    update_coroutines()
    tick()
    handle_input()
    update_camera()

    // Setup resolution scale depending on current display size
    dpi_scale := sapp.dpi_scale()
    display_width := sapp.widthf()
    display_height := sapp.heightf()
    resolution_scale := gfx_get_resolution_scaling(
        display_width,
        display_height,
        dpi_scale,
    )
    clear(&sprites_to_render)
    
    // Append the player sprite instead of a separate draw call.
    screen_pos := world_to_screen(player.position)
    append(&sprites_to_render, Sprite_To_Render{
        position = screen_pos,
        color    = player.color,
        scale    = player.scale,
        sprite   = player.sprite,
    })
    
    // Add test sprites at fixed world positions
    draw_dev_sprites()

    update_renderer(display_width, display_height)

    mouse_move = {}
    key_down_last = key_down

    debug_print("Player world pos:", player.position)
    debug_print("Camera position:", camera.position)
    debug_print("Player screen pos:", world_to_screen(player.position))
    debug_print("Sprite count:", len(sprites_to_render))
}

tick :: proc() {
    new_time := time.now()
    frame_time := time.duration_seconds(time.diff(timer.current, new_time))
    if frame_time > TICK_MAX do frame_time = TICK_MAX
    timer.current = new_time

    @(static) timer_tick_animation := TICK_ANIMATION

    timer_tick_animation -= frame_time
    if timer_tick_animation <= 0 {
        timer.animation += 1
        timer_tick_animation += TICK_ANIMATION
    }
}

//TODO: Implement keybinds
handle_input :: proc() {
    if key_down[.ESCAPE] {
        sapp.quit()
        return
    }
    
    // Player movement
    if key_down[.RIGHT] {
        player.position[0] += 3  // Increased speed for better movement
        if !player.facingRight {
            FlipPlayer(&player)
            player.facingRight = true
        }
    }
    if key_down[.LEFT] {
        player.position[0] -= 3  // Increased speed for better movement
        if player.facingRight {
            FlipPlayer(&player)
            player.facingRight = false
        }
    }
    if key_down[.UP] {
        player.position[1] += 3
    }
    if key_down[.DOWN] {
        player.position[1] -= 3
    }
    
    // Toggle camera following with Space
    if key_down[.SPACE] && !key_down_last[.SPACE] {
        if camera.target == nil {
            camera.target = &player
        } else {
            camera.target = nil
        }
    }
    
    // Manual camera control when not following player (WASD)
    if camera.target == nil {
        camera_speed := f32(5)
        if key_down[.W] { camera.position.y -= camera_speed }
        if key_down[.S] { camera.position.y += camera_speed }
        if key_down[.A] { camera.position.x -= camera_speed }
        if key_down[.D] { camera.position.x += camera_speed }
    }
    
    // Keep player within world bounds
    player.position[0] = math.clamp(player.position[0], 0, WORLD_WIDTH * BLOCK_SIZE)
    player.position[1] = math.clamp(player.position[1], 0, WORLD_HEIGHT * BLOCK_SIZE)

    // Print player position
    fmt.println("Player at:", player.position)
}

// Cleanup function
cleanup_cb :: proc "c" () {
    context = default_context

    sg.shutdown()
}

mouse_move: [2]f32
key_down: #sparse[sapp.Keycode]bool
key_down_last: #sparse[sapp.Keycode]bool

// Update the camera projection matrix when the window is resized.
event_cb :: proc "c" (ev: ^sapp.Event) {
    context = default_context

    #partial switch ev.type {
        case .MOUSE_MOVE:
            mouse_move += {ev.mouse_dx, ev.mouse_dy}
        case .KEY_DOWN:
            key_down[ev.key_code] = true
        case .KEY_UP:
            key_down[ev.key_code] = false
    }
    // Update the viewport multiplier and camera projection when the window is resized.
    if ev.type == .RESIZED {
        // Update renderer's viewport multiplier
        renderer.offscreen.pixel_to_viewport_multiplier =
            gfx_get_pixel_to_viewport_multiplier(GAME_WIDTH, GAME_HEIGHT)
        
        // Update camera bounds if needed
        camera.bounds.max_x = max(0, WORLD_WIDTH * BLOCK_SIZE - GAME_WIDTH)
        camera.bounds.max_y = max(0, WORLD_HEIGHT * BLOCK_SIZE - GAME_HEIGHT)
    }
}

main :: proc() {
    context.logger = log.create_console_logger()
	default_context = context
    sapp.run({
		width = GAME_WIDTH,
		height = GAME_HEIGHT,
        //fullscreen = true,
        
		window_title = "Please help me",

		allocator = sapp.Allocator(shelpers.allocator(&default_context)),
		logger = sapp.Logger(shelpers.logger(&default_context)),

		init_cb = init_cb,
		frame_cb = frame_cb,
		cleanup_cb = cleanup_cb,
		event_cb = event_cb,
	})
    
}
