#include "astation_transcription.h"
#include <limits.h>
#include <string.h>
#include <zlib.h>

size_t astation_caption_inflate(const uint8_t *input, size_t input_size, uint8_t *output, size_t output_size) {
    if (!input || !output || input_size > UINT_MAX || output_size > UINT_MAX) return 0;
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    stream.next_in = (Bytef *)input;
    stream.avail_in = (uInt)input_size;
    stream.next_out = output;
    stream.avail_out = (uInt)output_size;
    if (inflateInit2(&stream, 16 + MAX_WBITS) != Z_OK) return 0;
    int result = inflate(&stream, Z_FINISH);
    size_t count = result == Z_STREAM_END && stream.avail_in == 0 ? stream.total_out : 0;
    inflateEnd(&stream);
    return count;
}
