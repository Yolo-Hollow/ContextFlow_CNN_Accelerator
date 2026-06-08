import struct


ROWS = 18
COUT_TILE = 16
IFM_BANKS = 2


def pass_needs_channel(cin, k_base, channel):
    return (
        channel < cin
        and k_base < (channel + 1) * 9
        and k_base + ROWS > channel * 9
    )


def channel_for_bank(cin, k_base, bank):
    for channel in range(cin):
        if pass_needs_channel(cin, k_base, channel) and channel % IFM_BANKS == bank:
            return channel
    return None


def pack_bias_packet(bias, cout_base):
    values = [
        bias[cout_base + lane] if cout_base + lane < len(bias) else 0
        for lane in range(COUT_TILE)
    ]
    return b"".join(struct.pack("<i", value) for value in values)


def pack_weight_packet(weight, k_total, cout, k_base, cout_base):
    packet = bytearray()
    for kk in range(ROWS):
        for lane in range(COUT_TILE):
            gk = k_base + kk
            co = cout_base + lane
            value = weight[gk * cout + co] if gk < k_total and co < cout else 0
            packet.append(value & 0xFF)
    return bytes(packet)


def pack_ifm_packet(ifm, fm_w, cin, fy, k_base):
    packet = bytearray()
    channels = [channel_for_bank(cin, k_base, bank) for bank in range(IFM_BANKS)]
    for x in range(fm_w):
        for channel in channels:
            packet.append(ifm[(fy * fm_w + x) * cin + channel] if channel is not None else 0)
        packet.extend(b"\0" * (8 - IFM_BANKS))
    return bytes(packet)


def pack_optimized_3x3_ifm_stream(
    ifm, fm_w, fm_h, cin, k_passes, cout_blocks, tile_oy, tile_h
):
    first_fy = max(tile_oy - 1, 0)
    last_fy = min(tile_oy + tile_h, fm_h - 1)
    one_cout_block = b"".join(
        pack_ifm_packet(ifm, fm_w, cin, fy, kpass * ROWS)
        for kpass in range(k_passes)
        for fy in range(first_fy, last_fy + 1)
    )
    return one_cout_block * cout_blocks


def pack_native_1x1_ifm_packet(
    ifm, fm_w, cin, tile_oy, tile_h, k_base, input_zero_point
):
    packet = bytearray()
    for y in range(tile_oy, tile_oy + tile_h):
        for x in range(fm_w):
            pixel = (y * fm_w + x) * cin
            lanes = [
                ifm[pixel + k_base + lane]
                if k_base + lane < cin
                else input_zero_point
                for lane in range(ROWS)
            ]
            packet.extend(lanes[:8])
            packet.extend(lanes[8:16])
            packet.extend(lanes[16:18])
            packet.extend(bytes([input_zero_point]) * 6)
    return bytes(packet)


def pack_optimized_native_1x1_ifm_stream(
    ifm, fm_w, cin, k_passes, cout_blocks, tile_oy, tile_h, input_zero_point
):
    one_cout_block = b"".join(
        pack_native_1x1_ifm_packet(
            ifm, fm_w, cin, tile_oy, tile_h, kpass * ROWS, input_zero_point
        )
        for kpass in range(k_passes)
    )
    return one_cout_block * cout_blocks


def pack_raw_hwc_ifm_tile(ifm, fm_w, cin, tile_oy, tile_h):
    start = tile_oy * fm_w * cin
    byte_count = tile_h * fm_w * cin
    return ifm[start : start + byte_count]


def check_shape(fm_w, fm_h, cin, cout, k_passes, cout_blocks, tile_oy, tile_h):
    k_total = cin * 9
    bias = [index * 17 - 91 for index in range(cout)]
    weight = [((index * 13 + 7) % 255) - 128 for index in range(k_total * cout)]
    ifm = bytes((index * 29 + 3) & 0xFF for index in range(fm_w * fm_h * cin))

    bias_packets = [
        pack_bias_packet(bias, block * COUT_TILE) for block in range(cout_blocks)
    ]
    weight_packets = [
        pack_weight_packet(weight, k_total, cout, kpass * ROWS, block * COUT_TILE)
        for block in range(cout_blocks)
        for kpass in range(k_passes)
    ]
    first_fy = max(tile_oy - 1, 0)
    last_fy = min(tile_oy + tile_h, fm_h - 1)
    ifm_packets = [
        pack_ifm_packet(ifm, fm_w, cin, fy, kpass * ROWS)
        for block in range(cout_blocks)
        for kpass in range(k_passes)
        for fy in range(first_fy, last_fy + 1)
    ]

    bias_stream = b"".join(bias_packets)
    weight_stream = b"".join(weight_packets)
    ifm_stream = b"".join(ifm_packets)
    optimized_ifm_stream = pack_optimized_3x3_ifm_stream(
        ifm, fm_w, fm_h, cin, k_passes, cout_blocks, tile_oy, tile_h
    )

    assert len(bias_stream) == cout_blocks * COUT_TILE * 4
    assert len(weight_stream) == cout_blocks * k_passes * ROWS * COUT_TILE
    assert len(ifm_stream) == len(ifm_packets) * fm_w * 8
    assert len(bias_stream) <= 64 * 1024
    assert len(weight_stream) <= 8 * 1024 * 1024
    assert len(ifm_stream) <= 20 * 1024 * 1024
    assert optimized_ifm_stream == ifm_stream

    for index, packet in enumerate(bias_packets):
        start = index * len(packet)
        assert bias_stream[start : start + len(packet)] == packet
    for index, packet in enumerate(weight_packets):
        start = index * len(packet)
        assert weight_stream[start : start + len(packet)] == packet
    for index, packet in enumerate(ifm_packets):
        start = index * len(packet)
        assert ifm_stream[start : start + len(packet)] == packet


def check_native_1x1_shape(
    fm_w, fm_h, cin, cout, cout_blocks, tile_oy, tile_h, input_zero_point
):
    k_passes = (cin + ROWS - 1) // ROWS
    ifm = bytes((index * 29 + 3) & 0xFF for index in range(fm_w * fm_h * cin))
    packets = [
        pack_native_1x1_ifm_packet(
            ifm, fm_w, cin, tile_oy, tile_h, kpass * ROWS, input_zero_point
        )
        for _block in range(cout_blocks)
        for kpass in range(k_passes)
    ]
    stream = b"".join(packets)
    optimized_stream = pack_optimized_native_1x1_ifm_stream(
        ifm,
        fm_w,
        cin,
        k_passes,
        cout_blocks,
        tile_oy,
        tile_h,
        input_zero_point,
    )
    packet_bytes = fm_w * tile_h * 3 * 8

    assert len(packets) == cout_blocks * k_passes
    assert all(len(packet) == packet_bytes for packet in packets)
    assert len(stream) == cout_blocks * k_passes * packet_bytes
    assert len(stream) <= 20 * 1024 * 1024
    assert optimized_stream == stream

    tail = packets[k_passes - 1]
    first_pixel_tail = tail[:24]
    valid_tail_lanes = cin - (k_passes - 1) * ROWS
    assert first_pixel_tail[valid_tail_lanes:18] == bytes(
        [input_zero_point] * (18 - valid_tail_lanes)
    )
    assert first_pixel_tail[18:24] == bytes([input_zero_point] * 6)


def check_raw_hwc_1x1_shape(fm_w, fm_h, cin, tile_oy, tile_h):
    ifm = bytes((index * 29 + 3) & 0xFF for index in range(fm_w * fm_h * cin))
    raw_tile = pack_raw_hwc_ifm_tile(ifm, fm_w, cin, tile_oy, tile_h)
    expected = b"".join(
        ifm[(y * fm_w + x) * cin : (y * fm_w + x + 1) * cin]
        for y in range(tile_oy, tile_oy + tile_h)
        for x in range(fm_w)
    )
    assert raw_tile == expected
    assert len(raw_tile) == tile_h * fm_w * cin


def main():
    check_shape(416, 416, 3, 16, 2, 1, 0, 2)
    check_shape(13, 13, 1024, 256, 512, 16, 0, 4)
    check_native_1x1_shape(13, 13, 1024, 256, 16, 0, 4, 21)
    check_native_1x1_shape(13, 13, 512, 24, 2, 12, 1, 11)
    check_raw_hwc_1x1_shape(13, 13, 1024, 0, 4)
    check_raw_hwc_1x1_shape(13, 13, 512, 12, 1)
    print("PASS: batch stream packing matches legacy and native 1x1 order")


if __name__ == "__main__":
    main()
