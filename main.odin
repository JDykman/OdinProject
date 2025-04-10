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
        //fmt.println(..args)
    }
}

// For format strings
debug_printf :: proc(format: string, args: ..any) {
    when DEBUG_MODE {
        //fmt.printf(format, ..args)
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

ATLAS_HEIGHT :: 256   // Add this constant, adjust the value as needed

SPRITES :: #partial [Sprite_Name]Sprite {
    .PINK_MONSTER = {
        frames = {{0, 2}},
        size = {BLOCK_SIZE, BLOCK_SIZE},
    },
    .NONE = {
        frames = {{0,28}},
        size = {},
    },
    .DIRT = {
        // Use correct coordinates with vertical flip enabled:
        frames = {{0, 0}},
        size = {BLOCK_SIZE, BLOCK_SIZE},
    },
    .STONE = {
        frames = {{0, 1}},
        size = {BLOCK_SIZE, BLOCK_SIZE},
    },
    .GRASS = {
        frames = {{0, 15}},
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
Sprite_Sheet :: struct {
    atlas:   [2]u16,
    size:    [2]u16,
    frames:  [][2]u16,
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
    GRASS,
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
    position: Pos, // Center of the sprite
    sprite : Sprite,
    color : Color,
    scale : Scale,
    facingRight : bool,
    velocity: Vec2f,
    health:   f32,
}

Entity :: struct {
    position: Pos,
    sprite: Sprite,
    color: Color,
    scale: Scale,
    velocity: Vec2f,
    health: f32,
}

// Global camera instance
camera: Camera
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

// Block structure: each block (or pixel) in our simulation.
Block :: struct {
    Type:         i32,   // Block_Dict id: 1=air, 2=dirt, 3=grass, 4=stone, etc.
    Sprite:       Sprite, // Sprite to render
    Solid:        bool,  // Is this block solid?
    Dynamic:      bool,  // Is this block dynamic?
}

Block_Dict := [?]Block{
	// Assign by index
	0 = BLOCK_AIR,
    1 = BLOCK_DIRT,
    2 = BLOCK_STONE,
    3 = BLOCK_GRASS,
}

// Block type constants.
BLOCK_AIR : Block = {
    Type = 0,
    Sprite = SPRITES[.NONE],
    Solid = false
}
BLOCK_DIRT : Block = {
    Type = 1,
    Sprite = SPRITES[.DIRT],
    Solid = true
}
BLOCK_STONE : Block = {
    Type = 2,
    Sprite = SPRITES[.STONE],
    Solid = true
}
BLOCK_GRASS : Block = {
    Type = 3,
    Sprite = SPRITES[.GRASS],
    Solid = true
}

// World generation parameters.

BLOCK_SIZE :: 16 // Block size (in pixels)
WORLD_WIDTH  :: 500 // Width of the world (in pixels)
WORLD_HEIGHT :: 25  // At least as tall as game view (22.5 tiles)

World :: struct {
    width: i32, // Width in blocks
    height: i32, // Height in blocks
    seed: i64,
    noiseFreq: f32,
    worldGrid: [][]int, // Contains block types
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

collideableEntities := make([dynamic]Entity)
dynamicEntities := make([dynamic]Entity)
dynamicBlocks := make([dynamic]Block)
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

IsBlockHere :: proc(w:^World, pos:Vec2i) -> bool {
    i := screen_to_world({f32(pos.x), f32(pos.y)})
    if(w.worldGrid[i.x][i.y] == 0){
        return false
    }
    return true // default return value, implement actual logic as needed
}

PlaceBlock :: proc(w:^World, pos:Vec2i, type:i32, force:bool=false){
    if force || IsBlockHere(w, pos){
        block : Block
        for b in Block_Dict{
            if(b.Type == type){
                block = b
            }
        }
        if block.Solid {
            append(&dynamicBlocks, block)
        }
        w.worldGrid[pos.x][pos.y] = int(block.Type)
    }
}

generateWorld :: proc(w : ^World){
    // Create array
    w.worldGrid = make([][]int, w.width)
    for i in 0..<w.width {
        w.worldGrid[i] = make([]int, w.height)
        for j in 0..<w.height {
            if j < 15 {
                r := rand.int31_max(2)
                r+=1
                fmt.println(r)
                PlaceBlock(w, Vec2i{i32(i), i32(j)}, r, true)
            }else{
                w.worldGrid[i][j] = 0
            }
        }
    }
    //Grass Pass
    for i in 0..<w.height-1 {  // Stop one row before the bottom to avoid out-of-bounds
        for j in 0..<w.width {
            if(w.worldGrid[j][i] == 1) && w.worldGrid[j][i+1] == 0{
                rNum := rand.int31_max(10) + 1
                w.worldGrid[j][i] = 3 // Set block to grass
            }
        }
    }
    fmt.println("World Generated")
}

maybe_grow_grass :: proc() {
    for x in 0..<w.width {
        for y in 0..<w.height {
            if w.worldGrid[x][y] != int(BLOCK_DIRT.Type) {
                continue
            }

            touching_air := false
            touching_grass := false

            directions := [][2]i32{
                {1, 0}, {-1, 0}, {0, 1}, {0, -1},
            }

            for dir in directions {
                nx := x + dir[0]
                ny := y + dir[1]

                if nx < 0 || ny < 0 || nx >= w.width || ny >= w.height {
                    continue
                }

                neighbor := w.worldGrid[nx][ny]
                if neighbor == int(BLOCK_AIR.Type) {
                    touching_air = true
                } else if neighbor == int(BLOCK_GRASS.Type) {
                    touching_grass = true
                }

                // Early exit if both conditions are met
                if touching_air && touching_grass {
                    break
                }
            }

            if touching_air && touching_grass {
                if rand.int31_max(5) == 0 {
                    w.worldGrid[x][y] = int(BLOCK_GRASS.Type)
                }
            }
        }
    }

    fmt.println("Grass growth step completed")
}

renderWorld :: proc() {
    if &w.worldGrid != nil {
        // Loop through all blocks in the world grid
        for x in 0..<w.width {
            for y in 0..<w.height {
                block_type := w.worldGrid[x][y]
                world_pos := [2]f32{f32(x * BLOCK_SIZE), f32(y * BLOCK_SIZE)}
                
                // Skip rendering air blocks
                if block_type == 0 {
                    continue
                }
                
                // Select the appropriate sprite based on block type
                sprite: Sprite
                color := Color{255, 255, 255, 1}

                switch block_type {
                    case 1: // Dirt
                        sprite = BLOCK_DIRT.Sprite
                    case 2: // Stone
                        sprite = BLOCK_STONE.Sprite
                    case 3: // Grass
                        sprite = BLOCK_GRASS.Sprite
                    case: // Default fallback
                        sprite = BLOCK_AIR.Sprite
                }
                
                // Draw the block in world coordinates
                draw_world_sprite(world_pos, sprite, {1, 1}, color)
            }
        }
    }
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
    debug_print("Sprite atlas initialized with size:", renderer.offscreen.sprite_atlas_size)

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
screen_to_world :: proc(screen_pos: [2]f32) -> [2]i32 {
    world_x := (screen_pos[0] / camera.zoom) + camera.position.x
    world_y := ((GAME_HEIGHT - screen_pos[1]) / camera.zoom) + camera.position.y
    return {i32(world_x), i32(world_y)}
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
    
    clear(&sprites_to_render)  // Moved clear to the top

    ////////////////////////////////////////////////////////////////////////////
    // Timers & Input
    update_coroutines()
    tick()
    handle_input()
    update_camera()

    renderWorld()

    // Setup resolution scale depending on current display size
    dpi_scale := sapp.dpi_scale()
    display_width := sapp.widthf()
    display_height := sapp.heightf()
    resolution_scale := gfx_get_resolution_scaling(
        display_width,
        display_height,
        dpi_scale,
    )
    
    // Append the player sprite instead of a separate draw call.
    screen_pos := world_to_screen(player.position)
    append(&sprites_to_render, Sprite_To_Render{
        position = screen_pos,
        color    = player.color,
        scale    = player.scale,
        sprite   = player.sprite,
    })
    
    // Add test sprites at fixed world positions
    //draw_dev_sprites()

    update_renderer(display_width, display_height)

    mouse_move = {}
    key_down_last = key_down

    debug_print("Player world pos:", player.position)
    debug_print("Camera position:", camera.position)
    debug_print("Player screen pos:", world_to_screen(player.position))
    debug_print("Sprite count:", len(sprites_to_render))
}

dirt_check_timer: f64 = 0
DIRT_CHECK_INTERVAL : f64 = 1.0

tick :: proc() {
    new_time := time.now()
    frame_time := time.duration_seconds(time.diff(timer.current, new_time))
    if frame_time > TICK_MAX do frame_time = TICK_MAX
    timer.current = new_time

    dirt_check_timer += frame_time
    if dirt_check_timer >= DIRT_CHECK_INTERVAL {
        dirt_check_timer = 0
        maybe_grow_grass()
    }

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
    if key_down[.SPACE] && !key_down_last[.SPACE] {
        // Generate a new world by updating the global 'w'
        w = World{
            width = WORLD_WIDTH,
            height = WORLD_HEIGHT,
            seed = rand.int63(), // New seed
            noiseFreq = WORLD_NOISE_FREQ,
        }
        generateWorld(&w)
        debug_print("World generated with seed:", w.seed)
    }
    
    // Toggle camera following with Space
    // if key_down[.SPACE] && !key_down_last[.SPACE] {
    //     if camera.target == nil {
    //         camera.target = &player
    //     } else {
    //         camera.target = nil
    //     }
    // }
    
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
    debug_print("Player position:", player.position)
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
    // On click set block at mouse position to air
    if ev.type == .MOUSE_DOWN {
        mouse_pos := [2]f32{ev.mouse_x, ev.mouse_y}
        fmt.println("Mouse pos:", mouse_pos)
        world_pos := screen_to_world(mouse_pos)
        fmt.println("World pos:", world_pos)
        block_x := i32(world_pos[0] / BLOCK_SIZE)
        block_y := i32(world_pos[1] / BLOCK_SIZE)
        if key_down[.LEFT_SHIFT]{
            // Check if within bounds
            if block_x >= 0 && block_x < w.width && block_y >= 0 && block_y < w.height {
                w.worldGrid[block_x][block_y] = int(BLOCK_AIR.Type)
                debug_print("Block at", block_x, block_y, "set to air")
            }
        }else if key_down[.LEFT_CONTROL]{
            // Check if within bounds
            if block_x >= 0 && block_x < w.width && block_y >= 0 && block_y < w.height {
                w.worldGrid[block_x][block_y] = int(BLOCK_DIRT.Type)
                debug_print("Block at", block_x, block_y, "set to dirt")
            }
        }
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
