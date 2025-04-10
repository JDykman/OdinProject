#pragma sokol @header package shaders
#pragma sokol @header import sg "shared:sokol/gfx"

#pragma sokol @vs vs_offscreen
#pragma sokol @glsl_options flip_vert_y

layout(binding = 0) uniform vs_params {
    vec2 pixel_to_viewport_multiplier;  // Converts pixel coordinates to viewport space
    vec2 sprite_atlas_size;             // Size of atlas texture in pixels
};

// Per-vertex inputs with explicit locations
layout(location = 0) in vec2 vertex_position;  // Vertex position within sprite quad (0,0 to 1,1)

// Per-instance inputs with explicit locations
layout(location = 1) in vec2 location;         // Position in sprite atlas (pixels)
layout(location = 2) in vec2 size;             // Size of sprite in atlas (pixels)
layout(location = 3) in vec2 position;         // Position on screen (already camera-transformed)
layout(location = 4) in vec2 scale;            // Scale factor for sprite
layout(location = 5) in vec4 color;            // RGBA color multiplier

// Outputs to fragment shader
out vec2 uv;              // Texture coordinates
out vec4 rgba;            // Vertex color

void main() {
    // Step 1: Calculate the final position in screen space
    // Note: position is already transformed by camera in CPU code
    vec2 pixel_position = (vertex_position - 0.5) * size * scale + position;
    
    // Step 2: Convert from screen space to normalized device coordinates (NDC)
    // This maps (0,0) to (-1,1) and (screen_width, screen_height) to (1,-1)
    vec2 ndc_position = pixel_position * pixel_to_viewport_multiplier + vec2(-1.0, 1.0);
    gl_Position = vec4(ndc_position, 0.0, 1.0);

    // Step 3: Calculate texture coordinates for sprite atlas lookup
    // Calculate size of this sprite in UV coordinates (0-1)
    vec2 uv_size = size / sprite_atlas_size;
    
    // Calculate location of this sprite in UV coordinates
    vec2 uv_location = location / sprite_atlas_size;
    
    // Map vertex_position (0-1) to UV coordinates within this sprite
    // Y is flipped because texture coordinates start at bottom-left, not top-left
    uv = vec2(
        uv_location.x + vertex_position.x * uv_size.x, 
        1.0 - uv_location.y - vertex_position.y * uv_size.y
    );
    
    // Step 4: Convert color from 0-255 range to 0-1 range, preserving alpha
    rgba = vec4(color.rgb / 255.0, color.a);
}
#pragma sokol @end

#pragma sokol @fs fs_offscreen

// Use Sokol's texture sampling system with explicit binding points
layout(binding = 1) uniform texture2D atlas_texture;
layout(binding = 2) uniform sampler atlas_sampler;

in vec2 uv;      // Texture coordinates from vertex shader
in vec4 rgba;    // Color from vertex shader

out vec4 frag_color;

void main() {
    // Sample the texture at the provided UV coordinates using separate texture and sampler
    vec4 tex_color = texture(sampler2D(atlas_texture, atlas_sampler), uv);
    
    // Multiply by the instance color (supports transparency and tinting)
    frag_color = tex_color * rgba;
    
    // More robust transparency check using the source alpha values directly
    if (tex_color.a * rgba.a < 0.01) discard;
}
#pragma sokol @end

// Define the pipeline that combines the vertex and fragment shaders
#pragma sokol @program offscreen_program vs_offscreen fs_offscreen

#pragma sokol @vs display_vs
#pragma sokol @glsl_options flip_vert_y

// Inputs match the quad_vertices array in sprite_renderer.odin
in vec2 vertex_position;  // Position coordinates (-1 to 1)
in vec2 vertex_uv;        // Texture coordinates (0 to 1)

// Output to fragment shader
out vec2 uv;

void main() {
    // Pass position directly (already in normalized device coordinates)
    gl_Position = vec4(vertex_position, 0.0, 1.0);
    
    // Pass UV coordinates to fragment shader
    uv = vertex_uv;
}
#pragma sokol @end

#pragma sokol @fs display_fs

// Use display_program prefix in the uniform names
layout(binding = 1) uniform texture2D display_program_atlas_texture;
layout(binding = 2) uniform sampler display_program_atlas_sampler;

in vec2 uv;
out vec4 frag_color;

void main() {
    // Sample the offscreen render target
    frag_color = texture(sampler2D(display_program_atlas_texture, display_program_atlas_sampler), uv);
}
#pragma sokol @end

// Define the display program
#pragma sokol @program display_program display_vs display_fs
