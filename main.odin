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


default_context: runtime.Context

Globals :: struct {
    world_size: Vec2f,
    cameraPosition: Vec2f,
    cameraRotation: f32,
    camera: Camera2D,
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
    position = {0, 0},
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
WORLD_HEIGHT :: 10 // Height of the world (in pixels)

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

// A simple 2D camera structure
Camera2D :: struct {
    proj: Mat4, // Projection matrix
    view: Mat4, // View matrix
    mvp:  Mat4, // Combined Model-View-Projection matrix
}

// Creates an orthographic camera for a given window size.
// Here we assume (0,0) is top-left, y increases downward.
CreateOrthoCamera :: proc(window_width, window_height: f32) -> Camera2D {
    camera: Camera2D;
    // Ortho with left=0, right=window_width, top=0, bottom=window_height, near=-1, far=1
    camera.proj = Ortho(0.0, window_width, window_height, 0.0, -1.0, 1.0);
    camera.view = IdentityMat4(); // No translation or rotation
    camera.mvp  = MultiplyMat4(camera.proj, camera.view);
    return camera;
}

// Constructs an orthographic projection matrix.
Ortho :: proc(left, right, bottom, top, near, far: f32) -> Mat4 {
    return Mat4{
        2.0 / (right - left),    0.0,                   0.0,                   0.0,
        0.0,                     2.0 / (top - bottom),  0.0,                   0.0,
        0.0,                     0.0,                  -2.0 / (far - near),    0.0,
        -(right + left) / (right - left),
        -(top + bottom) / (top - bottom),
        -(far + near) / (far - near),
        1.0,
    };
}

CameraMoveData :: struct {
    from, to: Vec2f,
    duration: f32,
    elapsed: f32,
    easing: proc(f32) -> f32,
    camera_position: ^Vec2f,
}

update_camera_move :: proc(coroutine: ^Coroutine) -> bool {
    data := cast(^CameraMoveData) coroutine.data
    data.elapsed += get_frame_delta_time()
    
    t := data.elapsed / data.duration
    if t >= 1.0 {
        t = 1.0
    }

    eased_t := data.easing(t)
    data.camera_position^.x = lerp(data.from.x, data.to.x, eased_t)
    data.camera_position^.y = lerp(data.from.y, data.to.y, eased_t)

    return data.elapsed < data.duration
}

// Helper to easily start a camera coroutine
move_camera :: proc(
    from, to: Vec2f, 
    duration: f32, 
    easing: proc(f32) -> f32, 
    camera_position: ^Vec2f,
) {
    data := new(CameraMoveData)
    data.from = from
    data.to = to
    data.duration = duration
    data.elapsed = 0.0
    data.easing = easing
    data.camera_position = camera_position
    
    add_coroutine(update_camera_move, data)
}

UpdateOrtho :: proc() {
    g.camera.proj = Ortho(
        -f32(GAME_WIDTH)/2, f32(GAME_WIDTH)/2,
        -f32(GAME_HEIGHT)/2, f32(GAME_HEIGHT)/2,
        -1.0, 1.0
    )
    g.camera.mvp = MultiplyMat4(g.camera.proj, g.camera.view)
}

UpdateCameraView :: proc(){
    g.camera.view = TranslateMat4(Vec2f{g.cameraPosition.x, g.cameraPosition.y})
    g.camera.mvp = MultiplyMat4(g.camera.proj, g.camera.view)
}

cameraDeltaToWorld :: proc(delta: Vec2f) -> Vec2f {
    return Vec2f{
        delta.x * f32(GAME_WIDTH),
        delta.y * f32(GAME_HEIGHT),
    }
}

worldToCamera :: proc(worldPos: Vec2f) -> Vec2f {
    return Vec2f{
        worldPos.x / f32(GAME_WIDTH),
        worldPos.y / f32(GAME_HEIGHT),
    }
}


// Helper linear interpolation function
lerp :: proc(a, b, t: f32) -> f32 {
    return a + (b - a) * t
}

get_frame_delta_time :: proc() -> f32 {
    return f32(sapp.frame_duration())
}


// Returns an identity 4x4 matrix.
IdentityMat4 :: proc() -> Mat4 {
    return Mat4{
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    };
}

// Multiplies two 4x4 matrices (a * b).
MultiplyMat4 :: proc(a, b: Mat4) -> Mat4 {
    result: Mat4;
    // Use half-open ranges: 0..<4
    for i in 0..<4 {
        for j in 0..<4 {
            sum: f32 = 0.0;
            for k in 0..<4 {
                sum += a[i*4 + k] * b[k*4 + j];
            }
            result[i*4 + j] = sum;
        }
    }
    return result;
}
FlipPlayer :: proc(p : ^Player) {
    p.scale = {-p.scale.x, p.scale.y}
}


TranslateMat4 :: proc(translation: Vec2f) -> Mat4 {
    // Create an identity matrix first:
    t: Mat4 = IdentityMat4();
    t[12] = -translation.x; // x translation
    t[13] = -translation.y; // y translation
    return t;
}

initWorld :: proc(w, h :int) -> World {
    // Create Empty World
    grid := make([][]Block, w)
    for i in 0..<w {
        grid[i] = make([]Block, h)
        for j in 0..<h {
            grid[i][j] = BLOCK_AIR
            fmt.printf("Block: %d %d\n", i, j)
        }
    }

    return World{
        width = w,
        height = h,
        seed = WORLD_SEED,
        noiseFreq = WORLD_NOISE_FREQ,
        worldGrid = grid,
    }
}

generateWorld :: proc(world: ^World) {
    
}

renderWorld :: proc(world: ^World) {
    
}
// Initialize the Sokol application
init_cb :: proc "c" () {
    context = default_context

    // append(&sprites_to_render, Sprite_To_Render{
    //     position = {29 * 0 + 8, 120},
    //     sprite   = SPRITES[.PINK_MONSTER],
    //     color    = {255, 255, 255, 1},
    //     scale    = {1, 1},
    // })

    sg.setup({
		environment = shelpers.glue_environment(),
		allocator = sg.Allocator(shelpers.allocator(&default_context)),
		logger = sg.Logger(shelpers.logger(&default_context)),
	})
    sapp.show_mouse(true)

    init_coroutines()

    assert(GAME_WIDTH > 0, fmt.tprintf("game_width > 0: %v", GAME_WIDTH))
    assert(GAME_HEIGHT > 0, fmt.tprintf("game_height > 0: %v", GAME_HEIGHT))
    // This is a multiplier to translate our GAME coordinates to viewport coordinates
    pixel_to_viewport_multiplier := gfx_get_pixel_to_viewport_multiplier(
        GAME_WIDTH,
        GAME_HEIGHT,
    )

    // Set the camera's center to (0,0) on start.
    g.cameraPosition = Vec2f{0, 0}


    OFFSCREEN_PIXEL_FORMAT :: sg.Pixel_Format.RGBA8
    OFFSCREEN_SAMPLE_COUNT :: 1

    ////////////////////////////////////////////////////////////////////////////
    // `render_target` is a color attachment in the offscreen rendering pass.
    // But also a fragement shader texture in the display rendering pass.
    // Everything that is rendered in our GAME is rendered to this image.
    image_description := sg.Image_Desc {
        render_target = true,
        width         = i32(GAME_WIDTH),
        height        = i32(GAME_HEIGHT),
        pixel_format  = OFFSCREEN_PIXEL_FORMAT,
        sample_count  = OFFSCREEN_SAMPLE_COUNT,
        label         = "color-image-render-target",
    }
    render_target := sg.make_image(image_description)

    // Depth stencil for alpha blending, so we can have transparent sprites.
    image_description.pixel_format = .DEPTH
    image_description.label = "depth-image-render-target"
    depth_image := sg.make_image(image_description)

    // Attach the render target to our offscreen pass.
    offscreen_pass := sg.Pass {
        attachments = sg.make_attachments(
            {
                colors = {0 = {image = render_target}},
                depth_stencil = {image = depth_image},
                label = "offscreen-attachments",
            },
        ),
        action = {
            colors = {
                0 = {
                    load_action = .CLEAR,
                    clear_value = sg.Color{0.2, 0.2, 0.2, 1},
                },
            },
        },
        label = "offscreen-pass",
    }

    // Single quad reused by all our sprites.
    // odinfmt: disable
    // The `offscreen_index_buffer_vertices` will map the values
    // `0, 1, 3` and `1, 2, 3` to these coordinates.
    offscreen_vertex_buffer_vertices := [8]f32{
        1, 1, // [0]
        1, 0, // [1]
        0, 0, // [2]
        0, 1, // [3]
    }
    // Two triangles creates a quad
    // [2] {0, 0}    [1] {1, 0}
    //  \            /
    //   x----------x
    //   |         /|
    //   |  2    /  |
    //   |     /    |
    //   |   /   1  |
    //   | /        |
    //   x__________x
    //  /            \
    // [3] {0, 1}   [0] {1, 1}
    offscreen_index_buffer_vertices := [6]u16{
        0, 1, 3, // triangle 1
        1, 2, 3, // triangle 2
    }
    // odinfmt: enable

    offscreen_vertex_buffer := sg.make_buffer(
        {
            type = .VERTEXBUFFER,
            data = as_range(&offscreen_vertex_buffer_vertices),
            label = "offscreen-vertex-buffer",
        },
    )

    offscreen_index_buffer := sg.make_buffer(
        {
            type = .INDEXBUFFER,
            data = as_range(&offscreen_index_buffer_vertices),
            label = "offscreen-index-buffer",
        },
    )

    // Another vertex buffer, instanced for all data for each sprite.
    // see `usage = .STREAM`
    // This buffer will contain the actual position, color, size etc.
    // We will put a bunch of `Sprite_Instance`s in this each frame.
    offscreen_instance_buffer := sg.make_buffer(
        {
            usage = .STREAM,
            type = .VERTEXBUFFER,
            size = BUDGET_SPRITES * size_of(Sprite_Instance),
            label = "offscreen-instance-buffer",
        },
    )

    // Offscreen pipeline
    offscreen_pipeline := sg.make_pipeline(
        {
            layout = {
                buffers = {1 = {step_func = .PER_INSTANCE}},
                attrs = {
                    // Our quad vertex buffer, index 0
                    shaders.ATTR_offscreen_vertex_position = {
                        format = .FLOAT2,
                        buffer_index = 0,
                    },
                    // All these other values are tied to our instance buffer
                    // Notice how each `format =` lines up with our `Sprite_Instance` struct
                    shaders.ATTR_offscreen_location = {
                        format = .FLOAT2,
                        buffer_index = 1,
                    },
                    shaders.ATTR_offscreen_size = {
                        format = .FLOAT2,
                        buffer_index = 1,
                    },
                    shaders.ATTR_offscreen_position = {
                        format = .FLOAT2,
                        buffer_index = 1,
                    },
                    shaders.ATTR_offscreen_scale = {
                        format = .FLOAT2,
                        buffer_index = 1,
                    },
                    shaders.ATTR_offscreen_color = {
                        format = .FLOAT4,
                        buffer_index = 1,
                    },
                },
            },
            index_type = .UINT16,
            // Load the shader!
            shader = sg.make_shader(
                shaders.offscreen_shader_desc(sg.query_backend()),
            ),
            depth = {
                pixel_format = .DEPTH,
                compare = .LESS_EQUAL,
                write_enabled = true,
            },
            colors = {
                0 = {
                    // This is what enables our sprites to be transparent.
                    // This is also what decides _how_ the are ordered.
                    // https://learnopengl.com/Advanced-OpenGL/Blending
                    blend = {
                        enabled = true,
                        src_factor_rgb = .SRC_ALPHA,
                        dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
                        op_rgb = .ADD,
                        src_factor_alpha = .SRC_ALPHA,
                        dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
                        op_alpha = .ADD,
                    },
                    pixel_format = OFFSCREEN_PIXEL_FORMAT,
                },
            },
            color_count = 1,
            sample_count = OFFSCREEN_SAMPLE_COUNT,
            label = "offscreen-pipeline",
        },
    )

    offscreen_sampler := sg.make_sampler(
        {
            min_filter = .NEAREST,
            mag_filter = .NEAREST,
            label = "offscreen-sampler",
        },
    )

    // Load and create our sprite atlas texture using `stb_image`
    // `#load` embeds the image in our binary!
    // This allows us to ship a single .exe without any assets laying around.
    // https://odin-lang.org/docs/overview/#loadstring-path-or-loadstring-path-type
    asset_sprite_atlas := #load("assets/textures.png")
    sa_w, sa_h, channels: i32
    stbi.set_flip_vertically_on_load(1)
    sprite_atlas := stbi.load_from_memory(
        raw_data(asset_sprite_atlas),
        i32(len(asset_sprite_atlas)),
        &sa_w,
        &sa_h,
        &channels,
        4,
    )
    // free the loaded image at the end of init.
    // `sg.make_image` will do the allocation needed and return a handle
    // after this we don't need the stbi_loaded image.
    // In general all `sg.make_` function do an allocation and return a handle!
    // https://github.com/floooh/sokol/blob/master/sokol_gfx.h#L1320
    // These are (I think lol) the only allocation that are done in this code.
    // https://odin-lang.org/docs/overview/#defer-statement
    defer stbi.image_free(sprite_atlas)

    // Create the image (in the sokol sense), this will be our texture in the shader.
    sprite_atlas_image := sg.make_image(
        {
            width = sa_w,
            height = sa_h,
            data = {
                subimage = {
                    0 = {
                        0 = {
                            ptr = sprite_atlas,
                            size = c.size_t(sa_w * sa_h * 4),
                        },
                    },
                },
            },
            pixel_format = OFFSCREEN_PIXEL_FORMAT,
            label = "sprite-atlas",
        },
    )

    // Here we set the buffers, sampler and image.
    // To get the image into the shader we need:
    // - A texture - our image!
    // - A sampler
    offscreen_bindings := sg.Bindings {
        vertex_buffers = {
            0 = offscreen_vertex_buffer,
            1 = offscreen_instance_buffer,
        },
        index_buffer = offscreen_index_buffer,
        samplers = {shaders.SMP_smp = offscreen_sampler},
        images = {shaders.IMG_tex = sprite_atlas_image},
    }

    ////////////////////////////////////////////////////////////////////////////

    // Store all the things we need in our global struct.
    renderer.offscreen = {
        pixel_to_viewport_multiplier = pixel_to_viewport_multiplier,
        sprite_atlas_size            = {sa_w, sa_h},
        pass                         = offscreen_pass,
        pipeline                     = offscreen_pipeline,
        bindings                     = offscreen_bindings,
    }

    ////////////////////////////////////////////////////////////////////////////
    // Display renderer
    // The display renderer is simpler.
    // The only thing this does is to render our image from the offscreen pass.
    // This image is then scaled up to match our viewport size.

    display_pass_action: sg.Pass_Action
    display_pass_action.colors[0] = {
        load_action = .CLEAR,
        clear_value = {r = 0, g = 0, b = 0, a = 0},
    }

    // The same rules with the two quads as in the offscreen pass applies here too.
    // The only difference is that the viewport coordinate space is
    // {-1, 1} instead of {0, 1}
    // Hence we pass two values:
    // The first is the viewport coordinates
    // The second is the quad from before (offscreen pass) coordinates.
    // Honestly I am not even sure if the name `uv` is correct here.
    // The following code is kinda the same as the Offscreen renderer with one big difference:
    // in the `display_bindings` we set the `image` to the `render_target`!
    // odinfmt: disable
    quad_vertices := [16]f32 {
        // position   uv
        +1, +1,       1, 1,
        +1, -1,       1, 0,
        -1, -1,       0, 0,
        -1, +1,       0, 1,
    }
    // odinfmt: enable
    display_vertex_buffer := sg.make_buffer(
        {
            type = .VERTEXBUFFER,
            data = as_range(&quad_vertices),
            label = "display-vertex-buffer",
        },
    )

    display_index_buffer_vertex := [QUAD_INDEX_SIZE]u16{0, 1, 3, 1, 2, 3}
    display_index_buffer := sg.make_buffer(
        {
            type = .INDEXBUFFER,
            data = as_range(&display_index_buffer_vertex),
            label = "display-index-buffer",
        },
    )

    display_pipeline := sg.make_pipeline(
        {
            layout = {
                attrs = {
                    shaders.ATTR_display_vertex_position = {format = .FLOAT2},
                    shaders.ATTR_display_vertex_uv = {format = .FLOAT2},
                },
            },
            index_type = .UINT16,
            shader = sg.make_shader(
                shaders.display_shader_desc(sg.query_backend()),
            ),
            depth = {compare = .LESS_EQUAL, write_enabled = true},
            label = "display-pipeline",
        },
    )

    display_sampler := sg.make_sampler(
        {
            min_filter = .NEAREST,
            mag_filter = .NEAREST,
            label = "display-sampler",
        },
    )

    display_bindings := sg.Bindings {
        vertex_buffers = {0 = display_vertex_buffer},
        index_buffer = display_index_buffer,
        samplers = {shaders.IMG_tex = display_sampler},
        // Notice how the refer to the `render_target` here!
        // This is the thing we rendered everything to in the offscreen pass.
        images = {shaders.SMP_smp = render_target},
    }

    ////////////////////////////////////////////////////////////////////////////

    // Store all the things we need in our global struct.
    renderer.display = {
        pass_action = display_pass_action,
        pipeline    = display_pipeline,
        bindings    = display_bindings,
    }
}

// Frame update function
frame_cb :: proc "c" () {
    context = runtime.default_context()

    ////////////////////////////////////////////////////////////////////////////
    // Timers & Input
    // see `non_renderer_code.odin`
    update_coroutines()
    tick()
    handle_input()

    // Setup resolution scale depending on current display size
    dpi_scale := sapp.dpi_scale()
    display_width := sapp.widthf()
    display_height := sapp.heightf()
    resolution_scale := gfx_get_resolution_scaling(
        display_width,
        display_height,
        dpi_scale,
    )

    ////////////////////////////////////////////////////////////////////////////
    // Update Camera Projection (orthographic, correct)
    UpdateCameraView()
    ////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////
    // Sprite batch
    // A "sprite batch" is a big slice of `Sprite_Instance`s which we send to
    // our vertex buffer with index 1 (offscreen_instance_buffer).
    // This way we can send ALL sprites to the shaders at once.
    // This allows to draw several sprites with only one draw call.
    // People told me draw calls can be a bottleneck in rendering so only doing
    // one sounds good!

    // Don't forget to reset the batch every frame!
    renderer.sprite_batch.len = 0

    // A little helper to animate our sprites with the `frames` we defined.
    for &sprite, idx in sprites_to_render {
        frames := len(sprite.sprite.frames)
        location := sprite.sprite.frames[int(timer.animation) % frames]

        // This is where the sprite is added to the batch, navigate to this function.
        // On could easily do this manually.
        gfx_draw_sprite(
            position = {sprite.position.x, sprite.position.y},
            scale = sprite.scale,
            color = sprite.color,
            location = location,
            size = sprite.sprite.size,
            sprite_batch = &renderer.sprite_batch,
        )
    }

    //Render the player
    frames := len(player.sprite.frames)
    location := player.sprite.frames[int(timer.animation) % frames]
    gfx_draw_sprite(
        position = player.position,
        scale = player.scale,
        color = player.color,
        location = location,
        size = player.sprite.size,
        sprite_batch = &renderer.sprite_batch,
    )

    // Upload the sprite batch to the GPU!
    if renderer.sprite_batch.len > 0 {
        sprite_batch := renderer.sprite_batch.instances[:renderer.sprite_batch.len]

        sg.update_buffer(
            renderer.offscreen.bindings.vertex_buffers[1],
            as_range(sprite_batch),
        )
    }

    ////////////////////////////////////////////////////////////////////////////
    // Offscreen rendering pass

    // Pass a single uniform struct to the shaders.
    // These are the values that will be reused by _all_ our sprites.
    // Meaning, they are the same for all sprites, we only need to upload them once.
    vertex_shader_uniforms := shaders.Vs_Params {
        pixel_to_viewport_multiplier = renderer.offscreen.pixel_to_viewport_multiplier,
        sprite_atlas_size            = {
            f32(renderer.offscreen.sprite_atlas_size.x),
            f32(renderer.offscreen.sprite_atlas_size.y),
        },
        camera_mvp = g.camera.mvp,
    }

    // Begin the pass.
    sg.begin_pass(renderer.offscreen.pass)

    // Apply the pipelines.
    sg.apply_pipeline(renderer.offscreen.pipeline)
    sg.apply_bindings(renderer.offscreen.bindings)
    // Apply the uniforms we declared above.
    sg.apply_uniforms(
        shaders.UB_vs_params,
        {
            ptr = &vertex_shader_uniforms,
            size = size_of(vertex_shader_uniforms),
        },
    )
    // Do the drawing.
    sg.draw(0, QUAD_INDEX_SIZE, renderer.sprite_batch.len)

    // The offscreen pass is over, we have now drawn all of our sprites on the `render_target`.
    sg.end_pass()

    ////////////////////////////////////////////////////////////////////////////
    // Display rendering pass

    sg.begin_pass(
        {
            action    = renderer.display.pass_action,
            swapchain = sglue.swapchain(),
            label     = "display-pass",
        },
    )
    sg.apply_pipeline(renderer.display.pipeline)
    sg.apply_bindings(renderer.display.bindings)

    // Calculate the aspect ratios
    game_aspect := f32(GAME_WIDTH) / f32(GAME_HEIGHT)
    display_aspect := display_width / display_height

    // Calculate the viewport size
    viewport_width := display_width
    viewport_height := display_height

    if game_aspect > display_aspect {
        viewport_height = display_width / game_aspect
    } else {
        viewport_width = display_height * game_aspect
    }

    // Calculate the viewport position to center the game
    viewport_x := (display_width - viewport_width) / 2
    viewport_y := (display_height - viewport_height) / 2

    // Adjust the viewport to maintain pixel-perfect scaling
    sg.apply_viewport(i32(viewport_x), i32(viewport_y), i32(viewport_width), i32(viewport_height), false)

    // Draw the image from the offscreen renderer to the newly scaled viewport.
    sg.draw(0, QUAD_INDEX_SIZE, 1)
    sg.end_pass()
    sg.commit()
    mouse_move = {}
    key_down_last = key_down
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
    if key_down[.E] && !key_down_last[.E] {
        fmt.printf("Generating New World\n")
        w = initWorld(WORLD_WIDTH, WORLD_HEIGHT)
        generateWorld(&w)
    }
    if key_down[.RIGHT] {
        player.position.x += 1
        if !player.facingRight {
            FlipPlayer(&player)
            player.facingRight = true
        }
        fmt.printf("Player Position: %f %f\n", player.position.x, player.position.y)
        //g.cameraPosition.x += .01
    }
    if key_down[.LEFT] {
        player.position.x -= 1
        if player.facingRight {
            FlipPlayer(&player)
            player.facingRight = false
        }
        fmt.printf("Player Position: %f %f\n", player.position.x, player.position.y)
        //g.cameraPosition.x -= .01
    }
    if key_down[.UP] {
        player.position.y += 1
        //g.cameraPosition.y -= .01
    }
    if key_down[.DOWN] {
        player.position.y -= 1
        //g.cameraPosition.y += .01
    }
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
    if ev.type == .MOUSE_DOWN && ev.mouse_button == .LEFT {
        x: f32 = player.position.x
        y: f32 = player.position.y
        fmt.printf("Player Position (world): %f %f\n", x, y)
        
        // Remove worldToCamera conversion; use the player's world position directly.
        targetPos := Vec2f{x / -GAME_WIDTH, y / -GAME_HEIGHT}
        fmt.printf("Target Camera Position (world): %f %f\n", targetPos.x, targetPos.y)
        fmt.printf("Current Camera Position (world): %f %f\n", g.cameraPosition.x, g.cameraPosition.y)
        
        // Smoothly move the camera (in world units) to the target position.
        move_camera(
            from = g.cameraPosition,
            to = cameraDeltaToWorld(targetPos),
            duration = f32(1.0),
            easing = easeInSine,
            camera_position = &g.cameraPosition,
        )
    }
    
    

    // Update the viewport multiplier and camera projection when the window is resized.
    if ev.type == .RESIZED {
        renderer.offscreen.pixel_to_viewport_multiplier =
        gfx_get_pixel_to_viewport_multiplier(GAME_WIDTH, GAME_HEIGHT)
        UpdateOrtho()
    }
}

main :: proc() {
    context.logger = log.create_console_logger()
	default_context = context
    UpdateOrtho()

    fmt.println("MVP Matrix:");
    for row in 0..<4 {
        fmt.printf("%f %f %f %f\n",
        g.camera.mvp[row*4 + 0],
        g.camera.mvp[row*4 + 1],
        g.camera.mvp[row*4 + 2],
        g.camera.mvp[row*4 + 3]);
    }

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
