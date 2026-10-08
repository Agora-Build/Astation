#pragma once
#include <stddef.h>
#include <stdint.h>

// Returns the decoded byte count, or zero for malformed/oversized gzip input.
size_t astation_caption_inflate(const uint8_t *input, size_t input_size, uint8_t *output, size_t output_size);
