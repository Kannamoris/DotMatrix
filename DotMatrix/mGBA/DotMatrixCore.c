// Implementation of the thin C interface over the vendored mGBA core.
//
// Original work; not part of the MPL-licensed core beneath it.

#include "DotMatrixCore.h"

#include <mgba/core/core.h>
#include <mgba-util/audio-buffer.h>
#include <mgba/gba/core.h>
#include <mgba/internal/gba/gba.h>
#include <mgba-util/vfs.h>

#include <stdlib.h>
#include <string.h>

#define DM_AUDIO_RATE 48000
/// Room for well over a frame of audio, so a late drain never loses samples.
#define DM_AUDIO_BUFFER 4096

struct DMCore {
    struct mCore* core;
    struct VFile* romFile;
    uint8_t* romCopy;

    /// mGBA renders into a buffer we own.
    uint32_t* video;

    /// Interleaved scratch for pulling samples out of the resampler.
    int16_t* audioScratch;

    /// mGBA reports save writes through the same memory it exposes, so
    /// dirtiness is tracked by comparing against the last flushed copy.
    uint8_t* savedShadow;
    size_t savedShadowSize;
    bool saveDirty;
};

DMCore* dm_core_create(const uint8_t* rom, size_t romSize) {
    if (!rom || romSize < 0xC0) {
        return NULL;
    }

    DMCore* wrapper = calloc(1, sizeof(DMCore));
    if (!wrapper) {
        return NULL;
    }

    // The caller may free its copy, so keep our own for the lifetime of the
    // VFile the core reads through.
    wrapper->romCopy = malloc(romSize);
    if (!wrapper->romCopy) {
        free(wrapper);
        return NULL;
    }
    memcpy(wrapper->romCopy, rom, romSize);

    wrapper->core = GBACoreCreate();
    if (!wrapper->core) {
        free(wrapper->romCopy);
        free(wrapper);
        return NULL;
    }

    wrapper->core->init(wrapper->core);
    mCoreInitConfig(wrapper->core, NULL);

    unsigned width, height;
    wrapper->core->baseVideoSize(wrapper->core, &width, &height);
    wrapper->video = calloc((size_t)width * height, sizeof(uint32_t));
    wrapper->core->setVideoBuffer(wrapper->core, wrapper->video, width);

    wrapper->core->setAudioBufferSize(wrapper->core, DM_AUDIO_BUFFER);

    wrapper->audioScratch = calloc(DM_AUDIO_BUFFER * 2, sizeof(int16_t));

    wrapper->romFile = VFileFromConstMemory(wrapper->romCopy, romSize);
    if (!wrapper->romFile || !wrapper->core->loadROM(wrapper->core, wrapper->romFile)) {
        dm_core_destroy(wrapper);
        return NULL;
    }

    wrapper->core->reset(wrapper->core);
    return wrapper;
}

void dm_core_destroy(DMCore* wrapper) {
    if (!wrapper) {
        return;
    }
    if (wrapper->core) {
        mCoreConfigDeinit(&wrapper->core->config);
        wrapper->core->deinit(wrapper->core);
    }
    // loadROM takes ownership of the VFile, so it must not be closed here.
    free(wrapper->video);
    free(wrapper->audioScratch);
    free(wrapper->savedShadow);
    free(wrapper->romCopy);
    free(wrapper);
}

void dm_core_run_frame(DMCore* wrapper) {
    if (wrapper && wrapper->core) {
        wrapper->core->runFrame(wrapper->core);
    }
}

const uint32_t* dm_core_framebuffer(DMCore* wrapper) {
    return wrapper ? wrapper->video : NULL;
}

void dm_core_set_keys(DMCore* wrapper, uint32_t keys) {
    if (wrapper && wrapper->core) {
        wrapper->core->setKeys(wrapper->core, keys);
    }
}

size_t dm_core_read_audio(DMCore* wrapper, float* left, float* right, size_t frames) {
    if (!wrapper || !wrapper->core || frames == 0) {
        return 0;
    }

    struct mAudioBuffer* buffer = wrapper->core->getAudioBuffer(wrapper->core);
    if (!buffer) {
        return 0;
    }

    size_t available = mAudioBufferAvailable(buffer);
    size_t wanted = available < frames ? available : frames;
    if (wanted > DM_AUDIO_BUFFER) {
        wanted = DM_AUDIO_BUFFER;
    }
    if (wanted == 0) {
        return 0;
    }

    // The buffer hands back interleaved stereo; the caller wants planar.
    size_t got = mAudioBufferRead(buffer, wrapper->audioScratch, wanted);
    for (size_t i = 0; i < got; ++i) {
        left[i] = wrapper->audioScratch[i * 2] / 32768.0f;
        right[i] = wrapper->audioScratch[i * 2 + 1] / 32768.0f;
    }
    return got;
}

void dm_core_flush_audio(DMCore* wrapper) {
    if (!wrapper || !wrapper->core) {
        return;
    }
    struct mAudioBuffer* buffer = wrapper->core->getAudioBuffer(wrapper->core);
    if (buffer) {
        mAudioBufferClear(buffer);
    }
}

size_t dm_core_queued_audio(DMCore* wrapper) {
    if (!wrapper || !wrapper->core) {
        return 0;
    }
    struct mAudioBuffer* buffer = wrapper->core->getAudioBuffer(wrapper->core);
    return buffer ? mAudioBufferAvailable(buffer) : 0;
}

void dm_core_read_memory(DMCore* wrapper, uint32_t address, uint8_t* out, size_t count) {
    if (!wrapper || !wrapper->core || !out) {
        return;
    }
    for (size_t i = 0; i < count; ++i) {
        out[i] = wrapper->core->busRead8(wrapper->core, address + (uint32_t)i);
    }
}

size_t dm_core_save_size(DMCore* wrapper) {
    if (!wrapper || !wrapper->core) {
        return 0;
    }
    void* data = NULL;
    size_t size = wrapper->core->savedataClone(wrapper->core, &data);
    free(data);
    return size;
}

size_t dm_core_save_read(DMCore* wrapper, uint8_t* out, size_t capacity) {
    if (!wrapper || !wrapper->core || !out) {
        return 0;
    }
    void* data = NULL;
    size_t size = wrapper->core->savedataClone(wrapper->core, &data);
    if (!data) {
        return 0;
    }
    size_t copied = size < capacity ? size : capacity;
    memcpy(out, data, copied);
    free(data);
    return copied;
}

void dm_core_save_write(DMCore* wrapper, const uint8_t* bytes, size_t count) {
    if (!wrapper || !wrapper->core || !bytes || count == 0) {
        return;
    }
    wrapper->core->savedataRestore(wrapper->core, bytes, count, true);
    wrapper->saveDirty = false;
}

bool dm_core_save_is_dirty(DMCore* wrapper) {
    if (!wrapper || !wrapper->core) {
        return false;
    }
    // The core does not signal writes, so detect them by comparison. The save
    // is small and this only runs about once a second.
    void* data = NULL;
    size_t size = wrapper->core->savedataClone(wrapper->core, &data);
    if (!data || size == 0) {
        free(data);
        return false;
    }
    bool changed = false;
    if (wrapper->savedShadowSize != size || !wrapper->savedShadow) {
        free(wrapper->savedShadow);
        wrapper->savedShadow = malloc(size);
        wrapper->savedShadowSize = size;
        if (wrapper->savedShadow) {
            memcpy(wrapper->savedShadow, data, size);
        }
        changed = true;
    } else if (memcmp(wrapper->savedShadow, data, size) != 0) {
        memcpy(wrapper->savedShadow, data, size);
        changed = true;
    }
    free(data);
    if (changed) {
        wrapper->saveDirty = true;
    }
    return wrapper->saveDirty;
}

void dm_core_save_clear_dirty(DMCore* wrapper) {
    if (wrapper) {
        wrapper->saveDirty = false;
    }
}

size_t dm_core_state_size(DMCore* wrapper) {
    if (!wrapper || !wrapper->core) {
        return 0;
    }
    return wrapper->core->stateSize(wrapper->core);
}

bool dm_core_state_save(DMCore* wrapper, uint8_t* out, size_t capacity) {
    if (!wrapper || !wrapper->core || !out) {
        return false;
    }
    if (capacity < wrapper->core->stateSize(wrapper->core)) {
        return false;
    }
    return wrapper->core->saveState(wrapper->core, out);
}

bool dm_core_state_load(DMCore* wrapper, const uint8_t* bytes, size_t count) {
    if (!wrapper || !wrapper->core || !bytes) {
        return false;
    }
    if (count < wrapper->core->stateSize(wrapper->core)) {
        return false;
    }
    return wrapper->core->loadState(wrapper->core, bytes);
}

void dm_core_game_title(DMCore* wrapper, char* out, size_t capacity) {
    if (!wrapper || !wrapper->core || !out || capacity == 0) {
        return;
    }
    char title[17] = {0};
    wrapper->core->getGameTitle(wrapper->core, title);
    strncpy(out, title, capacity - 1);
    out[capacity - 1] = '\0';
}

void dm_core_game_code(DMCore* wrapper, char* out, size_t capacity) {
    if (!wrapper || !wrapper->core || !out || capacity == 0) {
        return;
    }
    char code[9] = {0};
    wrapper->core->getGameCode(wrapper->core, code);
    strncpy(out, code, capacity - 1);
    out[capacity - 1] = '\0';
}
