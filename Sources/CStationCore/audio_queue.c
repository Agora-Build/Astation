#include "astation_audio_queue.h"
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct AstationAudioQueue {
    uint32_t channels, frames_per_slot, slot_count;
    float *samples;
    uint32_t *frames;
    uint64_t *times;
    double ticks_per_second;
    _Atomic uint64_t read_index, write_index, dropped_frames;
};

AstationAudioQueue *astation_audio_queue_create(uint32_t channels, uint32_t frames_per_slot,
                                               uint32_t slot_count) {
    if (!channels || channels > 32 || !frames_per_slot || frames_per_slot > 16384 ||
        slot_count < 2 || slot_count > 256) return NULL;
    AstationAudioQueue *queue = calloc(1, sizeof(*queue));
    if (!queue) return NULL;
    queue->channels = channels;
    queue->frames_per_slot = frames_per_slot;
    queue->slot_count = slot_count;
    queue->samples = calloc((size_t)channels * frames_per_slot * slot_count, sizeof(float));
    queue->frames = calloc(slot_count, sizeof(uint32_t));
    queue->times = calloc(slot_count, sizeof(uint64_t));
    if (!queue->samples || !queue->frames || !queue->times) {
        astation_audio_queue_destroy(queue);
        return NULL;
    }
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    queue->ticks_per_second = 1e9 * timebase.denom / timebase.numer;
    atomic_init(&queue->read_index, 0);
    atomic_init(&queue->write_index, 0);
    atomic_init(&queue->dropped_frames, 0);
    return queue;
}

void astation_audio_queue_destroy(AstationAudioQueue *queue) {
    if (!queue) return;
    free(queue->samples);
    free(queue->frames);
    free(queue->times);
    free(queue);
}

void astation_audio_queue_push(AstationAudioQueue *queue, const AudioBufferList *buffers,
                              uint32_t frames, uint64_t host_time, double sample_rate) {
    if (!queue || !buffers || !frames || sample_rate <= 0) return;
    uint32_t channels = 0;
    for (uint32_t b = 0; b < buffers->mNumberBuffers; b++) {
        const AudioBuffer *buffer = &buffers->mBuffers[b];
        channels += buffer->mNumberChannels;
        if (!buffer->mData || (uint64_t)frames * buffer->mNumberChannels * sizeof(float) >
            buffer->mDataByteSize) {
            atomic_fetch_add_explicit(&queue->dropped_frames, frames, memory_order_relaxed);
            return;
        }
    }
    if (channels != queue->channels) {
        atomic_fetch_add_explicit(&queue->dropped_frames, frames, memory_order_relaxed);
        return;
    }
    for (uint32_t offset = 0; offset < frames;) {
        uint64_t write = atomic_load_explicit(&queue->write_index, memory_order_relaxed);
        uint64_t read = atomic_load_explicit(&queue->read_index, memory_order_acquire);
        if (write - read >= queue->slot_count) {
            atomic_fetch_add_explicit(&queue->dropped_frames, frames - offset, memory_order_relaxed);
            return;
        }
        uint32_t count = frames - offset;
        if (count > queue->frames_per_slot) count = queue->frames_per_slot;
        size_t slot = write % queue->slot_count;
        float *dest = queue->samples + slot * queue->frames_per_slot * queue->channels;
        uint32_t channel_offset = 0;
        for (uint32_t b = 0; b < buffers->mNumberBuffers; b++) {
            const AudioBuffer *buffer = &buffers->mBuffers[b];
            const float *src = buffer->mData;
            for (uint32_t f = 0; f < count; f++) {
                for (uint32_t c = 0; c < buffer->mNumberChannels; c++) {
                    dest[f * channels + channel_offset + c] =
                        src[(offset + f) * buffer->mNumberChannels + c];
                }
            }
            channel_offset += buffer->mNumberChannels;
        }
        queue->frames[slot] = count;
        queue->times[slot] = host_time + (uint64_t)(offset * queue->ticks_per_second / sample_rate);
        atomic_store_explicit(&queue->write_index, write + 1, memory_order_release);
        offset += count;
    }
}

uint32_t astation_audio_queue_pop(AstationAudioQueue *queue, float *interleaved,
                                 uint32_t capacity_frames, uint64_t *host_time) {
    if (!queue || !interleaved || !host_time) return 0;
    uint64_t read = atomic_load_explicit(&queue->read_index, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&queue->write_index, memory_order_acquire);
    if (read == write) return 0;
    size_t slot = read % queue->slot_count;
    uint32_t frames = queue->frames[slot];
    if (capacity_frames < frames) return 0;
    memcpy(interleaved, queue->samples + slot * queue->frames_per_slot * queue->channels,
           (size_t)frames * queue->channels * sizeof(float));
    *host_time = queue->times[slot];
    atomic_store_explicit(&queue->read_index, read + 1, memory_order_release);
    return frames;
}

uint64_t astation_audio_queue_dropped_frames(const AstationAudioQueue *queue) {
    return queue ? atomic_load_explicit(&queue->dropped_frames, memory_order_relaxed) : 0;
}

int32_t astation_audio_parent_pid(int32_t pid) {
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 0;
    return (int32_t)info.pbi_ppid;
}
