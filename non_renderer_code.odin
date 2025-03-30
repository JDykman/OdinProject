package main

import "base:runtime"

import "core:time"

import sapp "shared:sokol/app"

// A timer for idle animations to showcase it sprite animations
TICK_ANIMATION :: 1 / 60.0 * 6
TICK_MAX :: 0.25

// [Enumarated array] to neatly store our sprite atlas lookup data.
// https://odin-lang.org/docs/overview/#enumerated-array


Key :: enum {
    UP,
    DOWN,
    LEFT,
    RIGHT,
}

Input :: struct {
    // Store our currently held down buttons in a [Bit set]. Fits neatly!
    // https://odin-lang.org/docs/overview/#bit-sets
    keys: bit_set[Key],
}



// // Some sprites to render
// // `[?]` to infer the fixed array length.
// // https://odin-lang.org/docs/overview/#fixed-arrays
// sprites_to_render := [?]Sprite_To_Render {
//     {
//         // Player
//         position = {29 * 0 + 8, 120},
//         sprite   = SPRITES[.PINK_MONSTER],
//         color    = {255, 255, 255, 1},
//         scale    = {1, 1},
//     },
//     {
//         // Red
//         position = {29 * 0 + 8, 8},
//         sprite   = SPRITES[.PINK_MONSTER],
//         color    = {200, 20, 0, 1},
//         scale    = {1, 1},
//     },
//     {
//         // Orange
//         position = {29 * 1 + 8, 8},
//         sprite   = SPRITES[.PINK_MONSTER],
//         color    = {220, 150, 0, 1},
//         scale    = {1, 1},
//     },
//     {
//         // Yellow
//         position = {29 * 2 + 8, 8},
//         sprite   = SPRITES[.PINK_MONSTER],
//         color    = {200, 220, 0, 1},
//         scale    = {1, 1},
//     },
//     {
//         // Green
//         position = {29 * 3 + 8, 8},
//         sprite   = SPRITES[.PINK_MONSTER],
//         color    = {0, 200, 0, 1},
//         scale    = {1, 1},
//     },
//     {
//         // "Blue"
//         position = {29 * 4 + 8, 8},
//         sprite   = SPRITES[.PINK_MONSTER],
//         color    = {20, 60, 200, 1},
//         scale    = {1, 1},
//     },
//     {
//         // Original
//         position = {29 * 5 + 8, 8},
//         sprite   = SPRITES[.PINK_MONSTER],
//         color    = {255, 255, 255, 1},
//         scale    = {1, 1},
//     },
//     {
//         // Overlap 1
//         position = {29 * 6 + 8, 8},
//         sprite   = SPRITES[.PINK_MONSTER],
//         color    = {90, 90, 90, 1},
//         scale    = {1, 1},
//     },
//     {
//         // Overlap 2
//         position = {29 * 6 + 16, 8},
//         sprite   = SPRITES[.PINK_MONSTER],
//         color    = {145, 145, 145, 1},
//         scale    = {1, 1},
//     },
//     {
//         // Overlap 3
//         position = {29 * 6 + 24, 8},
//         sprite   = SPRITES[.PINK_MONSTER],
//         color    = {200, 200, 200, 1},
//         scale    = {1, 1},
//     },
//     {
//         // Wide boii
//         position = {29 * 0 + 8, 40},
//         sprite   = SPRITES[.PINK_MONSTER],
//         color    = {255, 255, 255, 1},
//         scale    = {2, 1},
//     },
//     {
//         // Upsidedown!?
//         // This "turns around the axis", not optimal (notice the Y-coordinate is 69, not 40)
//         position = {29 * 2 + 8, 69},
//         sprite   = SPRITES[.PINK_MONSTER],
//         color    = {255, 255, 255, 1},
//         scale    = {-1, -1},
//     },
//     {
//         // Skewed af
//         position = {29 * 2 + 8, 98},
//         sprite   = SPRITES[.PINK_MONSTER],
//         color    = {255, 255, 255, 0.5},
//         scale    = {-3, -1},
//     },
//     {
//         // Tall boii
//         position = {29 * 2 + 8, 40},
//         sprite   = SPRITES[.PINK_MONSTER],
//         color    = {255, 255, 255, 1},
//         scale    = {1, 2},
//     },
//     {
//         // Original - ghost
//         position = {29 * 5 + 8, 8},
//         sprite   = SPRITES[.PINK_MONSTER],
//         color    = {255, 255, 255, 0.5},
//         scale    = {1, 1},
//     },
// }

// Convert sokol_app event keycodes to our own keycodes
sapp_keycode_to_key :: proc(keycode: sapp.Keycode) -> Maybe(Key) {
    #partial switch keycode {
    case .W, .UP:
        return .UP
    case .S, .DOWN:
        return .DOWN
    case .A, .LEFT:
        return .LEFT
    case .D, .RIGHT:
        return .RIGHT

    case:
        return nil
    }
}

