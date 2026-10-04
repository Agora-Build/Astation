#ifndef ASTATION_AUDIO_QUEUE_H
#define ASTATION_AUDIO_QUEUE_H

#include <AudioToolbox/AudioToolbox.h>
#include <stdint.h>

typedef struct AstationAudioQueue AstationAudioQueue;

// One audio producer and one worker consumer. No allocation or locks in push.
AstationAudioQueue *astation_audio_queue_create(uint32_t channels, uint32_t frames_per_slot,
                                               uint32_t slot_count);
void astation_audio_queue_destroy(AstationAudioQueue *queue);
void astation_audio_queue_push(AstationAudioQueue *queue, const AudioBufferList *buffers,
                              uint32_t frames, uint64_t host_time, double sample_rate);
// capacity_frames must be at least frames_per_slot; smaller buffers leave the slot unread.
uint32_t astation_audio_queue_pop(AstationAudioQueue *queue, float *interleaved,
                                 uint32_t capacity_frames, uint64_t *host_time);
uint64_t astation_audio_queue_dropped_frames(const AstationAudioQueue *queue);
int32_t astation_audio_parent_pid(int32_t pid);

#endif
