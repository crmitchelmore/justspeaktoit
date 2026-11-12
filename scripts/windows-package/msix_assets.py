"""The package logos, rendered from the canonical app icon by a
dependency-free PNG decoder, an exact integer resampler and encoder, so every
host produces identical bytes."""
import functools
import pathlib
import struct
import zlib

from msix_identity import REPOSITORY, PackageError, sha256

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def _png_chunks(data):
    if data[:8] != PNG_SIGNATURE:
        raise PackageError("not a PNG image")
    position = 8
    while position + 12 <= len(data):
        length, kind = struct.unpack(">I4s", data[position:position + 8])
        end = position + 12 + length
        if end > len(data):
            break
        body = data[position + 8:end - 4]
        if zlib.crc32(kind + body) & 0xffffffff != struct.unpack(">I", data[end - 4:end])[0]:
            raise PackageError("PNG chunk checksum mismatch in " + kind.decode("latin-1"))
        yield kind, body
        if kind == b"IEND":
            return
        position = end
    raise PackageError("truncated PNG image")


def decode_png(data):
    """Decode 8-bit RGB/RGBA non-interlaced PNG, the canonical icon exports, to RGBA."""
    header, idat = None, []
    for kind, body in _png_chunks(data):
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat.append(body)
    if header is None or not idat:
        raise PackageError("PNG image lacks IHDR or IDAT")
    width, height, depth, colour, compression, method, interlace = header
    if depth != 8 or colour not in (2, 6) or compression or method or interlace or not width or not height:
        raise PackageError("unsupported PNG format: depth %d colour type %d interlace %d" % (depth, colour, interlace))
    channels = 4 if colour == 6 else 3
    stride = width * channels
    raw = zlib.decompress(b"".join(idat))
    if len(raw) != height * (stride + 1):
        raise PackageError("PNG image data has the wrong length")
    pixels = bytearray(width * height * 4)
    previous = bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        kind = raw[start]
        row = bytearray(raw[start + 1:start + 1 + stride])
        if kind == 1:
            for i in range(channels, stride):
                row[i] = (row[i] + row[i - channels]) & 255
        elif kind == 2:
            for i in range(stride):
                row[i] = (row[i] + previous[i]) & 255
        elif kind == 3:
            for i in range(stride):
                left = row[i - channels] if i >= channels else 0
                row[i] = (row[i] + ((left + previous[i]) >> 1)) & 255
        elif kind == 4:
            for i in range(stride):
                a = row[i - channels] if i >= channels else 0
                b = previous[i]
                c = previous[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                row[i] = (row[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        elif kind != 0:
            raise PackageError("invalid PNG filter type %d" % kind)
        if channels == 4:
            pixels[y * width * 4:(y + 1) * width * 4] = row
        else:
            for x in range(width):
                offset = (y * width + x) * 4
                pixels[offset:offset + 3] = row[x * 3:x * 3 + 3]
                pixels[offset + 3] = 255
        previous = row
    return width, height, bytes(pixels)


def _png_chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff)


def encode_png(width, height, rgba):
    if len(rgba) != width * height * 4:
        raise PackageError("RGBA buffer does not match the image size")
    stride = width * 4
    raw = b"".join(b"\x00" + rgba[y * stride:(y + 1) * stride] for y in range(height))
    return (PNG_SIGNATURE + _png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + _png_chunk(b"sRGB", b"\x00") + _png_chunk(b"IDAT", zlib.compress(raw, 9)) + _png_chunk(b"IEND", b""))


def _area_weights(source, target):
    # Integer overlap of each source pixel with each target pixel, measured in
    # 1/target of a source pixel. Every target's weights sum to ``source``.
    weights = []
    for index in range(target):
        start, end = index * source, (index + 1) * source
        row = []
        for pixel in range(start // target, min(source, -(-end // target))):
            overlap = min(end, (pixel + 1) * target) - max(start, pixel * target)
            if overlap > 0:
                row.append((pixel, overlap))
        weights.append(row)
    return weights


def _rounded_quotient(numerator, denominator):
    return (2 * numerator + denominator) // (2 * denominator)


def resample_rgba(width, height, rgba, target_width, target_height):
    """Exact area average of premultiplied RGBA using integers only.

    Transparent pixels contribute no colour, so rounded corners do not darken,
    and every host produces identical pixels regardless of its zlib or libm.
    """
    columns, rows = _area_weights(width, target_width), _area_weights(height, target_height)
    total = width * height
    output = bytearray(target_width * target_height * 4)
    for ty, row_weights in enumerate(rows):
        for tx, column_weights in enumerate(columns):
            alpha = red = green = blue = 0
            for sy, wy in row_weights:
                base = sy * width
                for sx, wx in column_weights:
                    offset = (base + sx) * 4
                    weight = wx * wy * rgba[offset + 3]
                    alpha += weight
                    red += weight * rgba[offset]
                    green += weight * rgba[offset + 1]
                    blue += weight * rgba[offset + 2]
            out = (ty * target_width + tx) * 4
            if alpha:
                output[out] = _rounded_quotient(red, alpha)
                output[out + 1] = _rounded_quotient(green, alpha)
                output[out + 2] = _rounded_quotient(blue, alpha)
            output[out + 3] = _rounded_quotient(alpha, total)
    return bytes(output)


@functools.lru_cache(maxsize=64)
def _render_asset(data, size):
    width, height, rgba = _decode_asset(data)
    return encode_png(size, size, resample_rgba(width, height, rgba, size, size))


@functools.lru_cache(maxsize=4)
def _decode_asset(data):
    return decode_png(data)


def render_assets(identity, source_root=REPOSITORY):
    """Derive the package logos from the canonical app icon export."""
    source = identity["assets"]["source"]
    data = (pathlib.Path(source_root) / source).read_bytes()
    width, height, _ = _decode_asset(data)
    if width != height:
        raise PackageError("the icon source must be square")
    assets = {}
    for path, size in sorted(identity["assets"]["images"].items()):
        if size > width:
            raise PackageError("the icon source is smaller than " + path)
        assets[path] = _render_asset(data, size)
    record = {"source": source, "sourceSHA256": sha256(data), "sourceSize": [width, height],
              "method": "exact integer area average of premultiplied RGBA; unfiltered 8-bit RGBA PNG output",
              "images": dict(sorted(identity["assets"]["images"].items()))}
    return assets, record
