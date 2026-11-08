"""Minimal QR Code generator (byte mode, error-correction level L), standard library only.

Produces a boolean module matrix; :func:`render_ansi` turns it into terminal
text using Unicode half-block characters. Supports versions 1-40.
"""

from __future__ import annotations

# Per-version tables for error-correction level L (index 0 unused).
_ECC_PER_BLOCK = [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28,
                  28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30]
_NUM_BLOCKS = [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7,
               8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25]
_FORMAT_BITS_L = 1


class QRTooLong(ValueError):
    pass


def _raw_modules(ver: int) -> int:
    n = (16 * ver + 128) * ver + 64
    if ver >= 2:
        a = ver // 7 + 2
        n -= (25 * a - 10) * a - 55
        if ver >= 7:
            n -= 36
    return n


def _data_codewords(ver: int) -> int:
    return _raw_modules(ver) // 8 - _ECC_PER_BLOCK[ver] * _NUM_BLOCKS[ver]


def _gf_mul(x: int, y: int) -> int:
    z = 0
    for i in reversed(range(8)):
        z = (z << 1) ^ ((z >> 7) * 0x11D)
        z ^= ((y >> i) & 1) * x
    return z


def _rs_divisor(degree: int) -> list[int]:
    result = [0] * (degree - 1) + [1]
    root = 1
    for _ in range(degree):
        for j in range(degree):
            result[j] = _gf_mul(result[j], root)
            if j + 1 < degree:
                result[j] ^= result[j + 1]
        root = _gf_mul(root, 2)
    return result


def _rs_remainder(data: list[int], divisor: list[int]) -> list[int]:
    result = [0] * len(divisor)
    for b in data:
        factor = b ^ result.pop(0)
        result.append(0)
        for i, coef in enumerate(divisor):
            result[i] ^= _gf_mul(coef, factor)
    return result


def _bit(x: int, i: int) -> bool:
    return (x >> i) & 1 != 0


def _encode_codewords(payload: bytes, ver: int) -> list[int]:
    bits: list[int] = []

    def put(value: int, count: int) -> None:
        for i in reversed(range(count)):
            bits.append((value >> i) & 1)

    put(0b0100, 4)
    put(len(payload), 8 if ver <= 9 else 16)
    for b in payload:
        put(b, 8)
    capacity = _data_codewords(ver) * 8
    put(0, min(4, capacity - len(bits)))
    put(0, -len(bits) % 8)
    data = [int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8)]
    pad = 0xEC
    while len(data) < _data_codewords(ver):
        data.append(pad)
        pad ^= 0xEC ^ 0x11
    return data


def _add_ecc_and_interleave(data: list[int], ver: int) -> list[int]:
    nblocks, ecc_len = _NUM_BLOCKS[ver], _ECC_PER_BLOCK[ver]
    raw = _raw_modules(ver) // 8
    nshort = nblocks - raw % nblocks
    short_len = raw // nblocks
    div = _rs_divisor(ecc_len)
    blocks, k = [], 0
    for i in range(nblocks):
        dat = data[k:k + short_len - ecc_len + (0 if i < nshort else 1)]
        k += len(dat)
        ecc = _rs_remainder(dat, div)
        if i < nshort:
            dat = dat + [0]
        blocks.append(dat + ecc)
    out = []
    for i in range(len(blocks[0])):
        for j, blk in enumerate(blocks):
            if i != short_len - ecc_len or j >= nshort:
                out.append(blk[i])
    return out


class _Builder:
    def __init__(self, ver: int, codewords: list[int]) -> None:
        self.ver = ver
        self.size = ver * 4 + 17
        self.m = [[False] * self.size for _ in range(self.size)]
        self.fn = [[False] * self.size for _ in range(self.size)]
        self._function_patterns()
        self._draw_codewords(codewords)

    def _set(self, x: int, y: int, dark: bool) -> None:
        self.m[y][x] = dark
        self.fn[y][x] = True

    def _function_patterns(self) -> None:
        s = self.size
        for i in range(s):
            self._set(6, i, i % 2 == 0)
            self._set(i, 6, i % 2 == 0)
        self._finder(3, 3)
        self._finder(s - 4, 3)
        self._finder(3, s - 4)
        pos = self._align_positions()
        n = len(pos)
        for i in range(n):
            for j in range(n):
                if (i, j) not in ((0, 0), (0, n - 1), (n - 1, 0)):
                    self._alignment(pos[i], pos[j])
        self.draw_format(0)
        self._version_info()

    def _align_positions(self) -> list[int]:
        if self.ver == 1:
            return []
        n = self.ver // 7 + 2
        step = 26 if self.ver == 32 else (self.ver * 4 + n * 2 + 1) // (n * 2 - 2) * 2
        return [6] + [self.size - 7 - i * step for i in reversed(range(n - 1))]

    def _finder(self, x: int, y: int) -> None:
        for dy in range(-4, 5):
            for dx in range(-4, 5):
                xx, yy = x + dx, y + dy
                if 0 <= xx < self.size and 0 <= yy < self.size:
                    self._set(xx, yy, max(abs(dx), abs(dy)) not in (2, 4))

    def _alignment(self, x: int, y: int) -> None:
        for dy in range(-2, 3):
            for dx in range(-2, 3):
                self._set(x + dx, y + dy, max(abs(dx), abs(dy)) != 1)

    def draw_format(self, mask: int) -> None:
        data = _FORMAT_BITS_L << 3 | mask
        rem = data
        for _ in range(10):
            rem = (rem << 1) ^ ((rem >> 9) * 0x537)
        bits = (data << 10 | rem) ^ 0x5412
        s = self.size
        for i in range(0, 6):
            self._set(8, i, _bit(bits, i))
        self._set(8, 7, _bit(bits, 6))
        self._set(8, 8, _bit(bits, 7))
        self._set(7, 8, _bit(bits, 8))
        for i in range(9, 15):
            self._set(14 - i, 8, _bit(bits, i))
        for i in range(0, 8):
            self._set(s - 1 - i, 8, _bit(bits, i))
        for i in range(8, 15):
            self._set(8, s - 15 + i, _bit(bits, i))
        self._set(8, s - 8, True)

    def _version_info(self) -> None:
        if self.ver < 7:
            return
        rem = self.ver
        for _ in range(12):
            rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
        bits = self.ver << 12 | rem
        for i in range(18):
            a, b = self.size - 11 + i % 3, i // 3
            self._set(a, b, _bit(bits, i))
            self._set(b, a, _bit(bits, i))

    def _draw_codewords(self, data: list[int]) -> None:
        i, s = 0, self.size
        right = s - 1
        while right >= 1:
            if right == 6:
                right = 5
            for vert in range(s):
                for j in range(2):
                    x = right - j
                    upward = (right + 1) & 2 == 0
                    y = s - 1 - vert if upward else vert
                    if not self.fn[y][x] and i < len(data) * 8:
                        self.m[y][x] = _bit(data[i >> 3], 7 - (i & 7))
                        i += 1
            right -= 2

    def apply_mask(self, mask: int) -> None:
        rules = [
            lambda x, y: (x + y) % 2 == 0,
            lambda x, y: y % 2 == 0,
            lambda x, y: x % 3 == 0,
            lambda x, y: (x + y) % 3 == 0,
            lambda x, y: (x // 3 + y // 2) % 2 == 0,
            lambda x, y: x * y % 2 + x * y % 3 == 0,
            lambda x, y: (x * y % 2 + x * y % 3) % 2 == 0,
            lambda x, y: ((x + y) % 2 + x * y % 3) % 2 == 0,
        ]
        r = rules[mask]
        for y in range(self.size):
            for x in range(self.size):
                if not self.fn[y][x] and r(x, y):
                    self.m[y][x] = not self.m[y][x]

    def penalty(self) -> int:
        s, m = self.size, self.m
        score = 0
        lines = [row[:] for row in m] + [[m[y][x] for y in range(s)] for x in range(s)]
        for line in lines:  # N1 runs, N3 finder-like patterns
            run = 1
            for i in range(1, s):
                if line[i] == line[i - 1]:
                    run += 1
                else:
                    score += 3 + (run - 5) if run >= 5 else 0
                    run = 1
            score += 3 + (run - 5) if run >= 5 else 0
            text = "".join("1" if v else "0" for v in line)
            score += 40 * (text.count("10111010000") + text.count("00001011101"))
        for y in range(s - 1):  # N2 2x2 blocks
            for x in range(s - 1):
                if m[y][x] == m[y][x + 1] == m[y + 1][x] == m[y + 1][x + 1]:
                    score += 3
        dark = sum(sum(row) for row in m)
        score += abs(dark * 20 - s * s * 10) // (s * s) * 10  # N4 balance
        return score


def make_qr(text: str) -> list[list[bool]]:
    """Return the module matrix (True = dark) for ``text`` encoded as UTF-8 bytes."""
    payload = text.encode("utf-8")
    for ver in range(1, 41):
        cap_bits = _data_codewords(ver) * 8
        if 4 + (8 if ver <= 9 else 16) + 8 * len(payload) <= cap_bits:
            break
    else:
        raise QRTooLong(f"{len(payload)} bytes do not fit in a QR code")
    codewords = _add_ecc_and_interleave(_encode_codewords(payload, ver), ver)
    best = None
    for mask in range(8):
        b = _Builder(ver, codewords)
        b.apply_mask(mask)
        b.draw_format(mask)
        p = b.penalty()
        if best is None or p < best[0]:
            best = (p, b)
    return best[1].m


def render_ansi(matrix: list[list[bool]], quiet: int = 4) -> str:
    """Two modules per character cell via half blocks. Explicit black/white colours
    make it scannable on both dark and light terminal themes.

    Dark modules are only ever drawn as cell *background*, never as a glyph.
    Terminals always fill the background across the whole cell, but some (macOS
    Terminal) draw the half-block glyph slightly below the top of the line. When
    dark was drawn as a glyph, that gap put white seams through the finder
    squares and phones could only read the code from far away."""
    n = len(matrix)
    size = n + 2 * quiet

    def dark(x: int, y: int) -> bool:
        x, y = x - quiet, y - quiet
        return 0 <= x < n and 0 <= y < n and matrix[y][x]

    lines = []
    for y in range(0, size, 2):
        row = []
        for x in range(size):
            top, bottom = dark(x, y), dark(x, y + 1)
            if top == bottom:
                row.append("\x1b[40m " if top else "\x1b[107m ")
            else:  # light half as a white glyph on a black cell
                row.append("\x1b[97;40m" + ("▄" if top else "▀"))
        lines.append("".join(row) + "\x1b[0m")
    return "\n".join(lines)
