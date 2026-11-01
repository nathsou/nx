// BC1-BC7 textures decoded on the CPU, for GPUs that don't sample them (the iOS Simulator's; a real iPhone / iPad from
// the A14 on does): BC1/2/3/7 to RGBA8, BC4 to R8, BC5 to RG8, BC6H to RGBA16F (third_party/bcdec).
#pragma once
#include <stdbool.h>
#include <stdint.h>

enum { BC_NONE, BC1, BC2, BC3, BC4, BC5, BC6H, BC7 };

int bc_soft_texel_bytes(int kind);  // of the decoded texels
// wb x hb x d blocks -> (wb * 4) x (hb * 4) x d texels, out_row bytes a row
void bc_soft_decode(int kind, bool is_signed, const uint8_t *blocks, uint32_t wb, uint32_t hb, uint32_t d, uint8_t *out,
                    uint32_t out_row);
