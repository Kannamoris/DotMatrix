// Thin C interface over the vendored mGBA core.
//
// Swift talks to this rather than to mGBA's headers directly: the core's own
// API is macro-heavy and awkward to import, and keeping the surface small
// means the Swift side stays readable and the coupling stays obvious.
//
// This file is original work and is not part of the MPL-licensed core.

#ifndef DOTMATRIX_CORE_H
#define DOTMATRIX_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Native GBA screen.
#define DM_SCREEN_WIDTH 240
#define DM_SCREEN_HEIGHT 160

/// Capacity of the audio ring buffer, in stereo frames. Sized for the fastest
/// rate SOUNDBIAS can actually select (262144Hz) to hold comfortably more
/// than one video frame's worth (~4390 at that rate) on top of the pacer's
/// ~30ms target — mGBA has no fixed output rate (see dm_core_audio_rate), so
/// this can't be sized against any one Hz figure. Swift-visible so
/// EmulatorSession can keep its pacing target safely under it.
#define DM_AUDIO_BUFFER 16384

/// Buttons, in the hardware's KEYINPUT bit order.
typedef enum {
    DM_KEY_A      = 1 << 0,
    DM_KEY_B      = 1 << 1,
    DM_KEY_SELECT = 1 << 2,
    DM_KEY_START  = 1 << 3,
    DM_KEY_RIGHT  = 1 << 4,
    DM_KEY_LEFT   = 1 << 5,
    DM_KEY_UP     = 1 << 6,
    DM_KEY_DOWN   = 1 << 7,
    DM_KEY_R      = 1 << 8,
    DM_KEY_L      = 1 << 9,
} DMKey;

typedef struct DMCore DMCore;

/// Create a core from a cartridge image held in memory.
/// The bytes are copied, so the caller may release them.
/// Returns NULL if the image is not a usable ROM.
DMCore* dm_core_create(const uint8_t* rom, size_t romSize);

void dm_core_destroy(DMCore* core);

/// Run until the next complete frame.
void dm_core_run_frame(DMCore* core);

/// Finished frame, row-major, 240x160. mGBA's 32-bit software renderer's
/// native format (mCOLOR_XBGR8): byte order R,G,B,X per pixel — read it as
/// RGBA8, not ARGB8. Valid until the next call to `dm_core_run_frame`.
const uint32_t* dm_core_framebuffer(DMCore* core);

/// Replace the held buttons; a bitwise OR of DMKey.
void dm_core_set_keys(DMCore* core, uint32_t keys);

/// Drain rendered audio into two planar float buffers.
/// Returns the number of stereo frames written.
size_t dm_core_read_audio(DMCore* core, float* left, float* right, size_t frames);

/// Discard buffered audio, after a pause or a state load.
void dm_core_flush_audio(DMCore* core);

/// Stereo frames currently queued, so emulation can be paced against it.
size_t dm_core_queued_audio(DMCore* core);

/// The rate audio is actually being produced at, in Hz. Not fixed: it comes
/// from the emulated SOUNDBIAS register, which the game's own boot code sets
/// (commonly 32768, 65536 or 131072), so it is only meaningful after a few
/// frames have run and can change again later. 0 if unavailable.
unsigned dm_core_audio_rate(DMCore* core);

/// Read emulated memory. Used by the battle overlay; safe at any address.
void dm_core_read_memory(DMCore* core, uint32_t address, uint8_t* out, size_t count);

/// Battery-backed cartridge save. Returns the size, or 0 if there is none.
size_t dm_core_save_size(DMCore* core);
size_t dm_core_save_read(DMCore* core, uint8_t* out, size_t capacity);
void dm_core_save_write(DMCore* core, const uint8_t* bytes, size_t count);

/// True when the save has changed since the flag was last cleared.
bool dm_core_save_is_dirty(DMCore* core);
void dm_core_save_clear_dirty(DMCore* core);

/// Whole-machine snapshots. `dm_core_state_size` gives the buffer size needed.
size_t dm_core_state_size(DMCore* core);
bool dm_core_state_save(DMCore* core, uint8_t* out, size_t capacity);
bool dm_core_state_load(DMCore* core, const uint8_t* bytes, size_t count);

/// Cartridge header fields, for identifying what was loaded.
void dm_core_game_title(DMCore* core, char* out, size_t capacity);
void dm_core_game_code(DMCore* core, char* out, size_t capacity);

#ifdef __cplusplus
}
#endif

#endif
