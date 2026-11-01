// BC textures decoded on the CPU (bc_soft.h).
#include "bc_soft.h"

#include <string.h>

#define BCDEC_IMPLEMENTATION
#define BCDEC_STATIC
#define BCDEC_BC4BC5_PRECISE  // (signed BC4 / BC5: the normal maps)
#include "../../third_party/bcdec/bcdec.h"

int bc_soft_texel_bytes(int kind) { return kind == BC4 ? 1 : kind == BC5 ? 2 : kind == BC6H ? 8 : 4; }

void bc_soft_decode(int kind, bool is_signed, const uint8_t *blocks, uint32_t wb, uint32_t hb, uint32_t d, uint8_t *out,
                    uint32_t out_row) {
    int bs = kind == BC1 || kind == BC4 ? 8 : 16, tb = bc_soft_texel_bytes(kind);
    for (uint32_t z = 0; z < d; z++)
        for (uint32_t by = 0; by < hb; by++)
            for (uint32_t bx = 0; bx < wb; bx++) {
                uint8_t *dst = out + ((uint64_t)z * hb * 4 + by * 4) * out_row + (uint64_t)bx * 4 * tb;
                switch (kind) {
                case BC1: bcdec_bc1(blocks, dst, (int)out_row); break;
                case BC2: bcdec_bc2(blocks, dst, (int)out_row); break;
                case BC3: bcdec_bc3(blocks, dst, (int)out_row); break;
                case BC4: bcdec_bc4(blocks, dst, (int)out_row, is_signed); break;
                case BC5: bcdec_bc5(blocks, dst, (int)out_row, is_signed); break;
                case BC7: bcdec_bc7(blocks, dst, (int)out_row); break;
                case BC6H: {  // (RGB halves; Metal has no 3-channel half format: alpha 1.0)
                    uint16_t rgb[16 * 3];
                    bcdec_bc6h_half(blocks, rgb, 4 * 3, is_signed);
                    for (int y = 0; y < 4; y++)
                        for (int x = 0; x < 4; x++) {
                            uint16_t px[4] = {rgb[(y * 4 + x) * 3], rgb[(y * 4 + x) * 3 + 1], rgb[(y * 4 + x) * 3 + 2], 0x3C00};
                            memcpy(dst + (uint64_t)y * out_row + x * 8, px, 8);
                        }
                    break;
                }
                }
                blocks += bs;
            }
}
