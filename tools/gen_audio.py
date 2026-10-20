#!/usr/bin/env python3
"""Rocket Squadron audio: every sound effect, music loop and ambience, synthesized
from scratch with the Python 3 standard library only (no numpy, no samples).

    python3 tools/gen_audio.py              # render everything (parallel)
    python3 tools/gen_audio.py laser ring   # render only these
    python3 tools/gen_audio.py --list       # ids, names, kinds, shipped format
    python3 tools/gen_audio.py --stats      # analyze the shipped files (format, peak, rms, loop seam)
    python3 tools/gen_audio.py --meta       # only rewrite the sfx.as block

Output: <name>.mp3|flac|wav at the project root, mono (see "Shipping": MP3 for music,
jingles, stings and the wind/jet ambience, FLAC at a content-picked rate for the rest; afconvert/lame, else
ffmpeg, else WAV). Deterministic: every sound seeds its own RNG from its name.
Also rewrites the GENERATED block in src/game/sfx.as: META (exact loop periods,
tempo and MP3 decoder lead, used for gapless scheduling and beat-quantized music
switches) and PEAK / DENS (each file's peak envelope and rms / peak, for the sfx bus limiter).

Toolkit: band-limited wavetables (built by inverse FFT), FM operators,
Karplus-Strong plucks, TPT state-variable filters, RBJ biquads, a block-
vectorized Freeverb, feedback echo, chorus, bus compression and soft clipping.
Music is sequenced from a tiny score language (see `seq`). Loops are rendered
with a tail that is folded back onto the head, and every stateful effect runs
"periodically" (pre-rolled with the loop's own end) so the seam is sample-
continuous.
"""

import array
import cmath
import math
import os
import random
import re
import sys
import wave
import zlib
from itertools import accumulate, repeat
from operator import add, mul

SR = 44100
TAU = 2.0 * math.pi
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
AUDIO_DIR = ROOT  # the audio files sit at the project root, where scene.rml's AudioAssets point

# -----------------------------------------------------------------------------
# Basics
# -----------------------------------------------------------------------------


def N(sec):
    return max(0, int(round(sec * SR)))


def zeros(n):
    return [0.0] * n


def hz(m):
    return 440.0 * 2.0 ** ((m - 69) / 12.0)


def db(x):
    return 10.0 ** (x / 20.0)


def rng_for(name):
    return random.Random(zlib.crc32(name.encode('utf-8')))


SN = 4096
SMASK = SN - 1
SINE = [math.sin(TAU * i / SN) for i in range(SN + 1)]
SIN_SCALE = SN / TAU

_NOISE = []


def white(n, rng):
    """White noise in [-1, 1]; slices of a large cached buffer at random offsets."""
    global _NOISE
    if not _NOISE:
        r = random.Random(12345)
        _NOISE = [r.uniform(-1.0, 1.0) for _ in range(1 << 20)]
    if n >= len(_NOISE) // 2:
        return [rng.uniform(-1.0, 1.0) for _ in range(n)]
    o = rng.randrange(0, len(_NOISE) - n)
    return _NOISE[o:o + n]


def scale(x, g):
    return [v * g for v in x]


def vmul(a, b):
    return list(map(mul, a, b))


def vadd(a, b):
    if len(a) < len(b):
        a, b = b, a
    out = list(a)
    out[:len(b)] = map(add, a[:len(b)], b)
    return out


def mix(dst, src, pos, g=1.0):
    """Add src*g into dst at sample offset pos (clipped to dst)."""
    if pos < 0:
        src = src[-pos:]
        pos = 0
    end = min(len(dst), pos + len(src))
    if end <= pos:
        return
    if g == 1.0:
        dst[pos:end] = map(add, dst[pos:end], src)
    else:
        dst[pos:end] = [a + b * g for a, b in zip(dst[pos:end], src)]


def peak(x):
    return max(max(x), -min(x)) if x else 0.0


def normalize(x, peak_db=-1.0):
    p = peak(x)
    if p <= 0:
        return x
    return scale(x, db(peak_db) / p)


def fade_edges(x, fin=0.002, fout=0.01):
    x = list(x)
    a = min(len(x), N(fin))
    for i in range(a):
        x[i] *= i / a
    b = min(len(x), N(fout))
    n = len(x)
    for i in range(b):
        x[n - 1 - i] *= i / b
    return x


def trim_silence(x, thresh_db=-70.0, pad=0.02):
    t = db(thresh_db)
    end = len(x)
    while end > 0 and abs(x[end - 1]) < t:
        end -= 1
    end = min(len(x), end + N(pad))
    return x[:end]


def sat(x, drive=1.5):
    k = 1.0 / math.tanh(drive)
    th = math.tanh
    return [th(v * drive) * k for v in x]


# -----------------------------------------------------------------------------
# Envelopes
# -----------------------------------------------------------------------------


def env_exp(n, tau):
    """exp(-t/tau), n samples, starting at 1."""
    if n <= 0:
        return []
    k = math.exp(-1.0 / max(1e-6, tau * SR))
    return list(accumulate(repeat(k, n - 1), mul, initial=1.0))


def env_lin(n, a, b):
    if n <= 0:
        return []
    if n == 1:
        return [a]
    d = (b - a) / (n - 1)
    return list(accumulate(repeat(d, n - 1), initial=a))


def env_adsr(n_on, a, d, s, r, curve=2.0):
    """Held n_on samples then released over r seconds. Returns n_on + N(r) samples."""
    na = max(1, N(a))
    nr = max(1, N(r))
    att = [1.0 - (1.0 - i / na) ** curve for i in range(min(na, n_on))]
    rest = n_on - len(att)
    body = att
    if rest > 0:
        body = att + [s + (1.0 - s) * v for v in env_exp(rest, max(0.001, d / 3.0))]
    last = body[-1] if body else 0.0
    rel = [last * v for v in env_exp(nr, max(0.001, r / 4.0))]
    k = min(64, nr)
    for i in range(k):
        rel[nr - 1 - i] *= i / k
    return body + rel


def env_ar(n, a, tau):
    """Fast attack (a sec) then exponential decay tau; total n samples."""
    na = max(1, min(n, N(a)))
    return [i / na for i in range(na)] + env_exp(n - na, tau)


def env_points(n, pts):
    """Piecewise linear envelope from [(t_sec, value), ...]."""
    out = []
    for (t0, v0), (t1, v1) in zip(pts, pts[1:]):
        k = N(t1) - N(t0)
        out += env_lin(k, v0, v1) if k > 0 else []
    if len(out) < n:
        out += [pts[-1][1]] * (n - len(out))
    return out[:n]


# -----------------------------------------------------------------------------
# Oscillators
# -----------------------------------------------------------------------------


def fft(a, inverse=False):
    a = list(a)
    n = len(a)
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j |= bit
        if i < j:
            a[i], a[j] = a[j], a[i]
    sign = 1.0 if inverse else -1.0
    length = 2
    while length <= n:
        half = length >> 1
        ws = [cmath.exp(sign * 2j * math.pi * k / length) for k in range(half)]
        for i in range(0, n, length):
            for k in range(half):
                u = a[i + k]
                v = a[i + k + half] * ws[k]
                a[i + k] = u + v
                a[i + k + half] = u - v
        length <<= 1
    return a


_TABS = {}


def bltab(kind, f):
    """Band-limited single-cycle table (with guard point) safe for pitch f."""
    band = int(math.floor(math.log2(max(f, 16.0) / 16.0) * 4.0))
    key = (kind, band)
    t = _TABS.get(key)
    if t is not None:
        return t
    ftop = 16.0 * 2.0 ** ((band + 1) / 4.0) * 1.04
    H = max(1, int(18000.0 / ftop))
    L = 4096 if H > 400 else 2048
    H = min(H, L // 2 - 1)
    X = [0j] * L
    for k in range(1, H + 1):
        if kind == 'saw':
            a = 1.0 / k
        elif kind == 'square':
            a = 1.0 / k if k & 1 else 0.0
        elif kind == 'tri':
            a = ((-1.0) ** ((k - 1) // 2)) / (k * k) if k & 1 else 0.0
        elif kind == 'pulse25':
            a = math.sin(math.pi * k * 0.25) / k
        elif kind == 'reed':  # hollow-ish: strong odd, weaker even
            a = (1.0 if k & 1 else 0.45) / k
        else:
            raise ValueError(kind)
        top = 0.75 * H
        if k > top and H > 4:
            a *= 0.5 * (1.0 + math.cos(math.pi * (k - top) / (H - top)))
        X[k] = a
    y = fft(X, inverse=True)
    t = [v.imag for v in y]
    p = max(abs(v) for v in t) or 1.0
    t = [v / p for v in t]
    t.append(t[0])
    _TABS[key] = t
    return t


SINTAB = SINE  # sine table with guard, len SN+1


def osc(tab, f, n, ph=0.0):
    """Wavetable oscillator with linear interpolation. f: Hz or per-sample list."""
    L = len(tab) - 1
    out = [0.0] * n
    p = (ph % 1.0) * L
    if isinstance(f, list):
        k = L / SR
        for i in range(n):
            ip = int(p)
            a = tab[ip]
            out[i] = a + (tab[ip + 1] - a) * (p - ip)
            p += f[i] * k
            if p >= L:
                p -= L
    else:
        inc = f * L / SR
        for i in range(n):
            ip = int(p)
            a = tab[ip]
            out[i] = a + (tab[ip + 1] - a) * (p - ip)
            p += inc
            if p >= L:
                p -= L
    return out


def sine(f, n, ph=0.0):
    return osc(SINTAB, f, n, ph)


def sweep_exp(n, f0, f1, tau=None):
    """Per-sample frequency list: exponential glide from f0 toward f1."""
    if tau is None:
        if n <= 1:
            return [f0] * n
        r = (f1 / f0) ** (1.0 / (n - 1))
        return list(accumulate(repeat(r, n - 1), mul, initial=f0))
    e = env_exp(n, tau)
    return [f1 + (f0 - f1) * v for v in e]


def vibrato(n, f, rate=5.5, cents=10.0, delay=0.2, ramp=0.3, ph=0.0):
    """Per-sample frequency with delayed vibrato."""
    out = [f] * n
    d0 = N(delay)
    rr = N(ramp) or 1
    w = TAU * rate / SR
    k = cents * math.log(2.0) / 1200.0
    for i in range(d0, n):
        depth = min(1.0, (i - d0) / rr) * k
        out[i] = f * (1.0 + depth * math.sin(w * i + ph))
    return out


def fm_op(fc, n, ratio, index, ph=0.0, fb=0.0):
    """2-operator FM. fc: Hz or list; index: float or per-sample list."""
    out = [0.0] * n
    pc = ph * SN
    pm = 0.0
    const_f = not isinstance(fc, list)
    const_i = not isinstance(index, list)
    S = SINE
    M = SMASK
    kk = SN / SR
    I = index * SIN_SCALE if const_i else 0.0
    inc = fc * kk if const_f else 0.0
    last = 0.0
    fbk = fb * SIN_SCALE
    for i in range(n):
        if not const_f:
            inc = fc[i] * kk
        if not const_i:
            I = index[i] * SIN_SCALE
        m = S[int(pm + last * fbk) & M]
        last = m
        out[i] = S[int(pc + I * m) & M]
        pc += inc
        pm += inc * ratio
    return out


# -----------------------------------------------------------------------------
# Filters and effects
# -----------------------------------------------------------------------------


def lp1(x, fc, y0=0.0):
    a = math.exp(-TAU * fc / SR)
    b = 1.0 - a
    y = y0
    out = [0.0] * len(x)
    for i, v in enumerate(x):
        y = b * v + a * y
        out[i] = y
    return out


def hp1(x, fc):
    lo = lp1(x, fc)
    return [a - b for a, b in zip(x, lo)]


def svf(x, fc, q=0.707, mode='lp'):
    """TPT state variable filter. fc: Hz or per-sample list (updated every 16)."""
    n = len(x)
    out = [0.0] * n
    k = 1.0 / q
    ic1 = ic2 = 0.0
    varying = isinstance(fc, list)
    nyq = 0.45 * SR

    def coefs(f):
        g = math.tan(math.pi * min(max(f, 10.0), nyq) / SR)
        a1 = 1.0 / (1.0 + g * (g + k))
        return a1, g * a1, g * g * a1

    a1, a2, a3 = coefs(fc[0] if varying else fc)
    lp = mode == 'lp'
    bp = mode == 'bp'
    for i in range(n):
        if varying and (i & 15) == 0:
            a1, a2, a3 = coefs(fc[i])
        v0 = x[i]
        v3 = v0 - ic2
        v1 = a1 * ic1 + a2 * v3
        v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2.0 * v1 - ic1
        ic2 = 2.0 * v2 - ic2
        if lp:
            out[i] = v2
        elif bp:
            out[i] = v1 * k
        else:
            out[i] = v0 - k * v1 - v2
    return out


def biquad(x, kind, f, q=0.707, gain_db=0.0):
    A = 10.0 ** (gain_db / 40.0)
    w0 = TAU * min(f, 0.45 * SR) / SR
    cw, sw = math.cos(w0), math.sin(w0)
    al = sw / (2.0 * q)
    if kind == 'lp':
        b0, b1, b2 = (1 - cw) / 2, 1 - cw, (1 - cw) / 2
        a0, a1, a2 = 1 + al, -2 * cw, 1 - al
    elif kind == 'hp':
        b0, b1, b2 = (1 + cw) / 2, -(1 + cw), (1 + cw) / 2
        a0, a1, a2 = 1 + al, -2 * cw, 1 - al
    elif kind == 'bp':
        b0, b1, b2 = al, 0.0, -al
        a0, a1, a2 = 1 + al, -2 * cw, 1 - al
    elif kind == 'peak':
        b0, b1, b2 = 1 + al * A, -2 * cw, 1 - al * A
        a0, a1, a2 = 1 + al / A, -2 * cw, 1 - al / A
    elif kind == 'lowshelf':
        sq = 2 * math.sqrt(A) * al
        b0 = A * ((A + 1) - (A - 1) * cw + sq)
        b1 = 2 * A * ((A - 1) - (A + 1) * cw)
        b2 = A * ((A + 1) - (A - 1) * cw - sq)
        a0 = (A + 1) + (A - 1) * cw + sq
        a1 = -2 * ((A - 1) + (A + 1) * cw)
        a2 = (A + 1) + (A - 1) * cw - sq
    elif kind == 'highshelf':
        sq = 2 * math.sqrt(A) * al
        b0 = A * ((A + 1) + (A - 1) * cw + sq)
        b1 = -2 * A * ((A - 1) + (A + 1) * cw)
        b2 = A * ((A + 1) + (A - 1) * cw - sq)
        a0 = (A + 1) - (A - 1) * cw + sq
        a1 = 2 * ((A - 1) - (A + 1) * cw)
        a2 = (A + 1) - (A - 1) * cw - sq
    else:
        raise ValueError(kind)
    b0, b1, b2, a1, a2 = b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0
    x1 = x2 = y1 = y2 = 0.0
    out = [0.0] * len(x)
    for i, v in enumerate(x):
        y = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1 = x1, v
        y2, y1 = y1, y
        out[i] = y
    return out


def comb_fb(x, D, fb, damp):
    """y[n] = x[n] + fb * damped(y[n-D]); vectorized in blocks of D."""
    n = len(x)
    y = [0.0] * (n + D + 1)
    a = 1.0 - damp
    b = damp
    for s in range(0, n, D):
        e = min(n, s + D)
        o = s + D + 1  # y offset
        prev = y[o - D:o - D + (e - s)]
        prev1 = y[o - D - 1:o - D - 1 + (e - s)]
        y[o:o + (e - s)] = [xi + fb * (a * p + b * q) for xi, p, q in zip(x[s:e], prev, prev1)]
    return y[D + 1:]


def allpass(x, D, g=0.5):
    """Freeverb allpass: v[n] = x[n] + g v[n-D]; y[n] = v[n-D] - x[n]."""
    n = len(x)
    v = [0.0] * (n + D)
    for s in range(0, n, D):
        e = min(n, s + D)
        prev = v[s:s + (e - s)]
        v[s + D:e + D] = [xi + g * p for xi, p in zip(x[s:e], prev)]
    return [p - xi for p, xi in zip(v[:n], x)]


def reverb(x, room=0.82, damp=0.25, pre=0.0, width=1.0):
    """Mono Freeverb (block vectorized). Returns wet only."""
    combs = [1557, 1617, 1491, 1422, 1277, 1356, 1188, 1116]
    aps = [556, 441, 341, 225]
    s = width
    combs = [max(32, int(c * s)) for c in combs]
    xin = [v * 0.12 for v in x]
    if pre > 0:
        xin = [0.0] * N(pre) + xin[:len(xin) - N(pre)]
    acc = [0.0] * len(x)
    for D in combs:
        c = comb_fb(xin, D, room, damp)
        acc = list(map(add, acc, c))
    for D in aps:
        acc = allpass(acc, D, 0.5)
    return acc


def echo(x, delay, fb=0.35, damp=0.4):
    D = max(1, N(delay))
    y = comb_fb(x, D, fb, damp)
    # wet only: y - x
    return [a - b for a, b in zip(y, x)]


def chorus(x, rate=0.6, depth=0.0035, base=0.012, voices=2, ph=0.0):
    """Modulated delay chorus (wet+dry mixed)."""
    n = len(x)
    out = list(x)
    for v in range(voices):
        w = TAU * rate * (1.0 + 0.23 * v) / SR
        p0 = ph + v * 2.1
        bd = base * SR
        dd = depth * SR
        for i in range(n):
            d = bd + dd * math.sin(w * i + p0)
            j = i - d
            ij = int(j)
            if ij < 1:
                continue
            fr = j - ij
            out[i] += 0.5 * (x[ij] + (x[ij + 1] - x[ij]) * fr) if ij + 1 < n else 0.0
    return out


def compress(x, thresh_db=-14.0, ratio=3.0, attack=0.01, release=0.15, makeup_db=0.0, block=128):
    """Block RMS compressor with smooth per-sample gain."""
    n = len(x)
    th = db(thresh_db)
    gains = []
    env = 0.0
    ka = math.exp(-block / (attack * SR))
    kr = math.exp(-block / (release * SR))
    for s in range(0, n, block):
        seg = x[s:s + block]
        r = math.sqrt(sum(v * v for v in seg) / max(1, len(seg)))
        k = ka if r > env else kr
        env = k * env + (1 - k) * r
        if env > th:
            over = 20 * math.log10(env / th)
            g = db(-over * (1 - 1 / ratio))
        else:
            g = 1.0
        gains.append(g)
    mk = db(makeup_db)
    out = [0.0] * n
    nb = len(gains)
    for bi in range(nb):
        g0 = gains[bi]
        g1 = gains[bi + 1] if bi + 1 < nb else g0
        s = bi * block
        e = min(n, s + block)
        m = e - s
        d = (g1 - g0) / m
        out[s:e] = [v * (g0 + d * j) * mk for j, v in enumerate(x[s:e])]
    return out


def periodic(fn, x, pre):
    """Process x as a loop: pre-roll with its own last `pre` samples."""
    P = min(pre, len(x))
    y = fn(x[len(x) - P:] + x)
    return y[P:P + len(x)]


def fold_tail(x, L):
    """Fold everything after L back onto the head (loop the tail)."""
    out = list(x[:L])
    tail = x[L:]
    pos = 0
    while tail:
        seg = tail[:L]
        out[:len(seg)] = map(add, out[:len(seg)], seg)
        tail = tail[L:]
        pos += 1
    return out


def bitcrush(x, bits=6, hold=4):
    q = 2 ** (bits - 1)
    out = [0.0] * len(x)
    v = 0.0
    for i in range(len(x)):
        if i % hold == 0:
            v = round(x[i] * q) / q
        out[i] = v
    return out


# -----------------------------------------------------------------------------
# Instruments (cached by parameters; returned lists are shared, never mutate)
# -----------------------------------------------------------------------------

_CACHE = {}


def cached(fn):
    def w(*a, **k):
        key = (fn.__name__, a, tuple(sorted(k.items())))
        v = _CACHE.get(key)
        if v is None:
            v = fn(*a, **k)
            _CACHE[key] = v
        return v
    w.__name__ = fn.__name__
    return w


def _cents(c):
    return 2.0 ** (c / 1200.0)


@cached
def brass(m, dur, vel=0.8, bright=1.0, vib=1.0, voices=3, det=8.0, att=0.025, rel=0.14,
          scoop=40.0, sus=0.82, dark=1.0, seed=0):
    """Subtractive brass section: detuned saws, scoop, delayed vibrato, filter blat."""
    f = hz(m)
    r = random.Random(seed * 7919 + m)
    n_on = N(dur)
    amp = env_adsr(n_on, att, 0.3, sus, rel)
    n = len(amp)
    vb = vibrato(n, f, rate=5.4 + r.random() * 0.4, cents=11.0 * vib, delay=0.18, ramp=0.35, ph=r.random() * TAU)
    sc = env_exp(n, 0.035)
    k = scoop * math.log(2.0) / 1200.0
    freqs = [a * (1.0 - k * b) for a, b in zip(vb, sc)]
    tab = bltab('saw', f * 1.05)
    sig = zeros(n)
    for v in range(voices):
        d = 0.0 if voices == 1 else det * (2.0 * v / (voices - 1) - 1.0)
        mm = _cents(d)
        o = osc(tab, [q * mm for q in freqs], n, r.random())
        sig = list(map(add, sig, o))
    sig = scale(sig, 1.0 / voices)
    fe = env_adsr(n_on, 0.03, 0.35, 0.5, rel * 0.8)
    fe += [0.0] * (n - len(fe))
    top = f * (1.0 + bright * vel * 9.0)
    cut = [min(15000.0, (f * 1.4 + (top - f * 1.4) * e) / dark) for e in fe]
    y = svf(sig, cut, 0.85, 'lp')
    y = vmul(y, amp)
    br = svf(white(n, r), 1700.0, 1.2, 'bp')
    bre = env_ar(n, 0.01, 0.05)
    y = [a + 0.06 * b * c for a, b, c in zip(y, br, bre)]
    return sat(scale(y, vel), 1.3)


@cached
def fmbrass(m, dur, vel=0.85, vib=1.0, idx=3.2, rel=0.12, att=0.02, seed=0):
    """Arcade FM trumpet: index envelope for the bright attack, delayed vibrato."""
    f = hz(m)
    r = random.Random(seed * 131 + m)
    n_on = N(dur)
    amp = env_adsr(n_on, att, 0.25, 0.85, rel)
    n = len(amp)
    fr = vibrato(n, f, rate=5.8, cents=14.0 * vib, delay=0.16, ramp=0.3, ph=r.random() * TAU)
    sc = env_exp(n, 0.03)
    fr = [a * (1.0 - 0.02 * b) for a, b in zip(fr, sc)]
    ie = env_adsr(n_on, 0.03, 0.3, 0.55, rel)
    ie += [0.0] * (n - len(ie))
    index = [0.4 + idx * vel * e for e in ie]
    y = fm_op(fr, n, 1.0, index, r.random(), fb=0.15)
    # a little saw body under it
    body = osc(bltab('saw', f * 1.05), fr, n, r.random())
    body = lp1(body, min(9000, f * 5))
    y = [a * 0.8 + b * 0.35 for a, b in zip(y, body)]
    y = vmul(y, amp)
    return sat(scale(y, vel * 0.9), 1.2)


@cached
def strings(m, dur, vel=0.7, att=0.18, rel=0.45, bright=1.0, trem=0.0, bpm=140.0, seed=0):
    f = hz(m)
    r = random.Random(seed * 17 + m)
    n_on = N(dur)
    amp = env_adsr(n_on, att, 0.4, 0.9, rel, curve=1.5)
    n = len(amp)
    tab = bltab('saw', f * 1.05)
    sig = zeros(n)
    for d in (-9.0, 8.0):
        fr = vibrato(n, f * _cents(d + r.uniform(-2, 2)), rate=4.8 + r.random(), cents=7.0, delay=0.1, ramp=0.4, ph=r.random() * TAU)
        sig = list(map(add, sig, osc(tab, fr, n, r.random())))
    cut = min(12000.0, f * 5.0 * bright + 900.0)
    y = svf(sig, cut, 0.6, 'lp')
    y = lp1(y, min(14000, cut * 1.8))
    if trem > 0:
        rate = bpm / 60.0 * 4.0  # 16ths
        w = TAU * rate / SR
        y = [v * (1.0 - trem * 0.5 * (1.0 - math.cos(w * i))) for i, v in enumerate(y)]
    return scale(vmul(y, amp), vel * 0.5)


@cached
def fmbass(m, dur, vel=0.85, idx=3.0, ratio=1.0, decay=0.08, seed=0):
    f = hz(m)
    n_on = N(dur)
    amp = env_adsr(n_on, 0.003, 0.25, 0.6, 0.05)
    n = len(amp)
    ie = [0.3 + idx * vel * e for e in env_exp(n, decay)]
    y = fm_op(f, n, ratio, ie, 0.0, fb=0.25)
    sub = sine(f, n)
    y = [a * 0.8 + b * 0.4 for a, b in zip(y, sub)]
    return sat(vmul(y, scale(amp, vel)), 1.4)


@cached
def sawbass(m, dur, vel=0.85, cutoff=900.0, envamt=2400.0, drive=2.2, seed=0):
    f = hz(m)
    n_on = N(dur)
    amp = env_adsr(n_on, 0.003, 0.2, 0.75, 0.04)
    n = len(amp)
    tab = bltab('saw', f * 1.05)
    a = osc(tab, f * _cents(-7), n, 0.1)
    b = osc(tab, f * _cents(7), n, 0.6)
    c = osc(bltab('square', f * 0.55), f * 0.5, n, 0.3)
    sig = [x + y + 0.8 * z for x, y, z in zip(a, b, c)]
    fe = env_exp(n, 0.07)
    cut = [cutoff + envamt * vel * e for e in fe]
    y = svf(sig, cut, 1.6, 'lp')
    y = sat(vmul(y, amp), drive)
    return scale(y, vel * 0.6)


@cached
def square_pluck(m, dur, vel=0.6, decay=0.12, cut=6.0, kind='square', seed=0):
    f = hz(m)
    n = N(dur + 0.08)
    y = osc(bltab(kind, f * 1.05), f, n, 0.0)
    y = lp1(y, min(12000, f * cut))
    e = env_ar(n, 0.002, decay)
    k = min(n, N(0.01))
    for i in range(k):
        e[n - 1 - i] *= i / k
    return scale(vmul(y, e), vel)


@cached
def bell(m, dur=1.2, vel=0.6, ratio=3.5, idx=2.2, decay=0.5, seed=0):
    """FM bell/glass."""
    f = hz(m)
    n = N(dur)
    # keep the significant sidebands under ~18 kHz (no FM aliasing on high bells)
    idx = max(0.0, min(idx, (18000.0 / f - 1.0) / ratio - 1.0))
    ie = [idx * e for e in env_exp(n, decay * 0.5)]
    y = fm_op(f, n, ratio, ie, 0.0)
    y2 = sine(f * 2.0, n, 0.25)
    e = env_ar(n, 0.002, decay)
    e2 = env_exp(n, decay * 0.3)
    y = [(a + 0.25 * b * c) * d for a, b, c, d in zip(y, y2, e2, e)]
    return fade_edges(scale(y, vel), 0.001, 0.02)


@cached
def glock(m, dur=1.4, vel=0.6, seed=0):
    f = hz(m)
    n = N(dur)
    parts = [(1.0, 1.0, 1.1), (2.756, 0.32, 0.35), (5.404, 0.14, 0.14), (8.933, 0.06, 0.07)]
    y = zeros(n)
    for ratio, a, d in parts:
        if f * ratio > 12000:
            continue
        s = sine(f * ratio, n)
        e = env_exp(n, d)
        y = [p + a * q * r for p, q, r in zip(y, s, e)]
    k = N(0.0015)
    for i in range(k):
        y[i] *= i / k
    return fade_edges(scale(y, vel * 0.8), 0.0005, 0.03)


@cached
def pluck(m, dur=1.0, vel=0.6, bright=0.6, decay=0.996, seed=0):
    """Karplus-Strong (block vectorized)."""
    f = hz(m)
    r = random.Random(seed * 31 + m)
    P = max(2, int(round(SR / f)))
    n = N(dur)
    exc = [r.uniform(-1, 1) for _ in range(P)]
    exc = lp1(exc, 800 + 12000 * bright)
    y = exc + [0.0] * n
    g = 0.5 * decay
    for s in range(P, P + n, P):
        e = min(P + n, s + P)
        a = y[s - P:e - P]
        b = y[s - P + 1:e - P + 1]
        y[s:e] = [(p + q) * g for p, q in zip(a, b)]
    y = y[:n]
    return fade_edges(scale(y, vel), 0.0005, 0.03)


@cached
def choir(m, dur, vel=0.6, att=0.25, rel=0.6, vowel='ah', seed=0):
    f = hz(m)
    r = random.Random(seed * 3 + m)
    n_on = N(dur)
    amp = env_adsr(n_on, att, 0.5, 0.9, rel, curve=1.5)
    n = len(amp)
    tab = bltab('saw', f * 1.05)
    sig = zeros(n)
    for d in (-6.0, 5.0):
        fr = vibrato(n, f * _cents(d), rate=5.0, cents=12.0, delay=0.25, ramp=0.5, ph=r.random() * TAU)
        sig = list(map(add, sig, osc(tab, fr, n, r.random())))
    forms = {'ah': [(800, 1.0, 6), (1150, 0.6, 8), (2800, 0.25, 10)],
             'oo': [(350, 1.0, 5), (800, 0.3, 7), (2400, 0.08, 9)],
             'ee': [(300, 0.8, 5), (2300, 0.5, 10), (3000, 0.3, 10)]}[vowel]
    y = zeros(n)
    for ff, g, q in forms:
        y = list(map(add, y, scale(biquad(sig, 'bp', ff, q), g)))
    br = svf(white(n, r), 3000.0, 0.8, 'bp')
    y = [a + 0.04 * b for a, b in zip(y, br)]
    return scale(vmul(y, amp), vel * 1.6)


@cached
def pad(m, dur, vel=0.5, att=0.6, rel=1.2, cut=1800.0, seed=0):
    f = hz(m)
    r = random.Random(seed * 5 + m)
    n_on = N(dur)
    amp = env_adsr(n_on, att, 0.8, 0.85, rel, curve=1.2)
    n = len(amp)
    tab = bltab('saw', f * 1.05)
    sig = zeros(n)
    for d in (-12.0, -4.0, 5.0, 11.0):
        sig = list(map(add, sig, osc(tab, f * _cents(d), n, r.random())))
    y = lp1(lp1(sig, min(cut, f * 8)), min(cut * 1.5, 16000))
    return scale(vmul(y, amp), vel * 0.3)


def theremin_line(song, notes, transpose=0, glide=0.07, vib_cents=28.0, vib_rate=6.2, gap=0.12):
    """One continuous theremin voice over a note list [(beat, dur, midi)]: sine with
    tube warmth, portamento between notes, wide delayed vibrato, breathy swells."""
    if not notes:
        return 0.0, []
    t0 = notes[0][0]
    t_end = notes[-1][0] + notes[-1][1]
    n = N((t_end - t0) * song.spb + 1.2)
    target = [0.0] * n
    gate = [0.0] * n
    for (bt, d, m) in notes:
        a = N((bt - t0) * song.spb)
        b = min(n, N((bt - t0 + d) * song.spb))
        f = hz(m + transpose)
        target[a:b] = [f] * (b - a)
        g0 = a + N(0.01)
        g1 = max(g0, b - N(gap * min(1.0, d)))
        gate[g0:g1] = [1.0] * (g1 - g0)
    # hold pitch through rests so the glide starts from the last note
    last = hz(notes[0][2] + transpose)
    for i in range(n):
        if target[i] == 0.0:
            target[i] = last
        else:
            last = target[i]
    fr = lp1(target, 1.0 / (TAU * glide), target[0] * 0.84)  # small swoop into the first note
    amp = lp1(lp1(gate, 9.0), 14.0)
    w = TAU * vib_rate / SR
    k = vib_cents * math.log(2.0) / 1200.0
    # vibrato deepens as a note is held
    held = 0.0
    out_f = [0.0] * n
    for i in range(n):
        held = held + 1.0 / SR if gate[i] > 0.5 else 0.0
        depth = k * min(1.0, 0.25 + held * 1.4)
        out_f[i] = fr[i] * (1.0 + depth * math.sin(w * i))
    y = sine(out_f, n)
    y2 = osc(SINTAB, [2.0 * f for f in out_f], n, 0.25)
    y = [math.tanh(1.6 * (a + 0.12 * b)) for a, b in zip(y, y2)]
    return t0, vmul(y, amp)


@cached
def xylo(m, vel=0.8, seed=0):
    f = hz(m)
    n = N(0.6)
    y = zeros(n)
    for ratio, a, d in ((1.0, 1.0, 0.22), (3.0, 0.35, 0.07), (6.0, 0.12, 0.03)):
        if f * ratio > 15000:
            continue
        y = [p + a * q * e for p, q, e in zip(y, sine(f * ratio, n), env_exp(n, d))]
    r = random.Random(seed + m)
    click = vmul(hp1(white(n, r), 3000.0), env_exp(n, 0.002))
    y = [a + 0.3 * c for a, c in zip(y, click)]
    return fade_edges(scale(y, vel * 0.8), 0.0003, 0.02)


# ---- drums ------------------------------------------------------------------


@cached
def kick(vel=1.0, punch=1.0, seed=0):
    n = N(0.5)
    fr = [52.0 + 125.0 * punch * e for e in env_exp(n, 0.028)]
    body = sine(fr, n)
    e = env_ar(n, 0.001, 0.14)
    r = random.Random(seed + 1)
    click = vmul(hp1(white(n, r), 2000.0), env_exp(n, 0.0015))
    y = [a * b + 0.35 * c for a, b, c in zip(body, e, click)]
    return fade_edges(sat(scale(y, vel), 1.8), 0.0, 0.02)


@cached
def snare(vel=1.0, tone=190.0, snappy=1.0, decay=0.15, seed=0):
    n = N(0.45)
    r = random.Random(seed + 2)
    b1 = vmul(sine([tone * (1 + 0.5 * e) for e in env_exp(n, 0.01)], n), env_exp(n, 0.055))
    b2 = vmul(sine(tone * 1.72, n, 0.3), env_exp(n, 0.03))
    nz = white(n, r)
    nz = biquad(nz, 'hp', 900.0, 0.7)
    nz = biquad(nz, 'peak', 4200.0, 1.0, 5.0)
    ne = env_ar(n, 0.0008, decay)
    y = [0.55 * a + 0.3 * b + 0.75 * snappy * c * d for a, b, c, d in zip(b1, b2, nz, ne)]
    return fade_edges(sat(scale(y, vel), 1.5), 0.0, 0.03)


@cached
def hat(vel=1.0, open_=False, seed=0):
    n = N(0.6 if open_ else 0.12)
    fs = [205.3, 304.4, 369.6, 522.7, 540.0, 800.0]
    y = zeros(n)
    for i, f in enumerate(fs):
        y = list(map(add, y, osc(bltab('square', f * 1.6), f * 1.6, n, i * 0.17)))
    r = random.Random(seed + 3)
    y = [a * 0.5 + 0.6 * b for a, b in zip(y, white(n, r))]
    y = biquad(biquad(y, 'hp', 7200.0, 0.7), 'peak', 10500.0, 1.2, 4.0)
    e = env_ar(n, 0.0005, 0.16 if open_ else 0.028)
    return fade_edges(scale(vmul(y, e), vel * 0.7), 0.0, 0.01)


@cached
def shaker(vel=1.0, seed=0):
    n = N(0.12)
    r = random.Random(seed + 4)
    y = biquad(white(n, r), 'bp', 6500.0, 1.2)
    e = env_points(n, [(0, 0), (0.012, 1.0), (0.03, 0.5), (0.12, 0.0)])
    return scale(vmul(y, e), vel * 1.6)


@cached
def crash(vel=1.0, dur=2.2, seed=0):
    n = N(dur)
    r = random.Random(seed + 5)
    fs = [245.0, 347.0, 461.0, 587.0, 734.0, 891.0, 1033.0]
    met = zeros(n)
    for i, f in enumerate(fs):
        met = list(map(add, met, osc(bltab('square', f * 2.3), f * 2.3, n, i * 0.31)))
    y = [0.25 * a + b for a, b in zip(met, white(n, r))]
    y = biquad(y, 'hp', 3200.0, 0.6)
    y = biquad(y, 'peak', 7500.0, 0.8, 3.0)
    e = [a * b for a, b in zip(env_ar(n, 0.001, 0.75 * dur / 2.2), env_points(n, [(0, 1.3), (0.05, 1.0), (dur, 1.0)]))]
    return fade_edges(scale(vmul(y, e), vel * 0.55), 0.0, 0.2)


@cached
def tom(m, vel=1.0, seed=0):
    f = hz(m)
    n = N(0.5)
    fr = [f * (1.0 + 0.6 * e) for e in env_exp(n, 0.04)]
    y = vmul(sine(fr, n), env_ar(n, 0.001, 0.2))
    r = random.Random(seed + 6)
    nz = vmul(lp1(white(n, r), 3000.0), env_exp(n, 0.02))
    y = [a + 0.3 * b for a, b in zip(y, nz)]
    return fade_edges(sat(scale(y, vel), 1.3), 0.0, 0.03)


@cached
def timpani(m, vel=1.0, dur=2.0, seed=0):
    f = hz(m)
    n = N(dur)
    parts = [(1.0, 1.0, 0.9), (1.504, 0.5, 0.6), (1.742, 0.32, 0.45), (2.0, 0.25, 0.4), (2.245, 0.15, 0.3), (2.494, 0.1, 0.25)]
    y = zeros(n)
    gl = env_exp(n, 0.06)
    for ratio, a, d in parts:
        fr = [f * ratio * (1.0 + 0.025 * g) for g in gl]
        s = sine(fr, n, ratio * 0.13)
        e = env_exp(n, d * dur / 2.0)
        y = [p + a * q * w for p, q, w in zip(y, s, e)]
    r = random.Random(seed + 7)
    mal = vmul(lp1(white(n, r), 1800.0), env_exp(n, 0.012))
    y = [a + 0.5 * b for a, b in zip(y, mal)]
    k = N(0.002)
    for i in range(k):
        y[i] *= i / k
    return fade_edges(sat(scale(y, vel * 0.8), 1.2), 0.0, 0.1)


@cached
def clang(vel=1.0, seed=0):
    """Metallic anvil hit (boss)."""
    n = N(1.2)
    parts = [(620.0, 1.0, 0.5), (1447.0, 0.6, 0.3), (2418.0, 0.45, 0.2), (3170.0, 0.3, 0.12), (4240.0, 0.2, 0.08)]
    y = zeros(n)
    for f, a, d in parts:
        y = [p + a * q * w for p, q, w in zip(y, sine(f, n, f * 0.001), env_exp(n, d))]
    r = random.Random(seed + 8)
    y = [a + 0.4 * b * c for a, b, c in zip(y, hp1(white(n, r), 2000), env_exp(n, 0.01))]
    return fade_edges(scale(y, vel * 0.5), 0.0, 0.05)


def ping(f, dur, decay, vel=1.0):
    n = N(dur)
    return fade_edges(vmul(sine(f, n, 0.25), env_exp(n, decay)), 0.0005, 0.01) if vel == 1.0 else \
        fade_edges(scale(vmul(sine(f, n, 0.25), env_exp(n, decay)), vel), 0.0005, 0.01)


def reverse_swell(dur, vel=1.0, seed=0):
    c = crash(1.0, dur + 0.3, seed)
    y = list(reversed(c[:N(dur)]))
    return fade_edges(scale(y, vel), 0.05, 0.004)


def riser(dur, vel=1.0, seed=0):
    n = N(dur)
    r = random.Random(seed + 9)
    fc = sweep_exp(n, 300.0, 9000.0)
    y = svf(white(n, r), fc, 2.5, 'bp')
    e = [(i / n) ** 2 for i in range(n)]
    return fade_edges(scale(vmul(y, e), vel), 0.01, 0.01)


# -----------------------------------------------------------------------------
# Score language
# -----------------------------------------------------------------------------

NOTE_PC = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11}


def note(s):
    """'C#5' -> midi."""
    pc = NOTE_PC[s[0]]
    i = 1
    while i < len(s) and s[i] in '#b':
        pc += 1 if s[i] == '#' else -1
        i += 1
    octv = int(s[i:])
    return 12 * (octv + 1) + pc


def seq(text, start=0.0, bar=4.0, default=1.0, check=True):
    """'C5:1.5 G4:.5 C5 E5 | G5:3 r:1' -> [(beat, dur, midi)].
    Bars ('|') are checked to sum to `bar` beats."""
    out = []
    t = start
    for bi, chunk in enumerate(text.split('|')):
        toks = chunk.split()
        if not toks:
            continue
        b0 = t
        for tok in toks:
            if ':' in tok:
                nm, d = tok.split(':')
                d = float(d)
            else:
                nm, d = tok, default
            if nm != 'r':
                out.append((t, d, note(nm)))
            t += d
        if check and abs((t - b0) - bar) > 1e-3:
            raise ValueError('bar %d sums to %.3f: %s' % (bi + 1, t - b0, chunk))
    return out


CHORD_Q = {
    '': [0, 4, 7], 'm': [0, 3, 7], '7': [0, 4, 7, 10], 'm7': [0, 3, 7, 10], 'maj7': [0, 4, 7, 11],
    'sus4': [0, 5, 7], 'sus2': [0, 2, 7], 'dim': [0, 3, 6], 'aug': [0, 4, 8], 'add9': [0, 4, 7, 14],
    'm9': [0, 3, 7, 10, 14], 'maj9': [0, 4, 7, 11, 14], '6': [0, 4, 7, 9], 'm7b5': [0, 3, 6, 10],
    '7sus4': [0, 5, 7, 10], 'maj7#11': [0, 4, 7, 11, 18],
}


def chord_parse(sym):
    """'Am7' / 'D/C' / 'Bb' -> (root_pc, [intervals], bass_pc)."""
    main, _, bass = sym.partition('/')
    pc = NOTE_PC[main[0]]
    i = 1
    while i < len(main) and main[i] in '#b':
        pc += 1 if main[i] == '#' else -1
        i += 1
    q = CHORD_Q[main[i:]]
    bpc = pc
    if bass:
        bpc = NOTE_PC[bass[0]] + (1 if bass[1:2] == '#' else -1 if bass[1:2] == 'b' else 0)
    return pc % 12, q, bpc % 12


def voicing(sym, center, count=4):
    """Close voicing of chord tones nearest to `center`."""
    pc, q, _ = chord_parse(sym)
    pcs = sorted(set((pc + iv) % 12 for iv in q))
    cands = [m for m in range(center - 14, center + 15) if m % 12 in pcs]
    cands.sort(key=lambda m: (abs(m - center), m))
    chosen = sorted(cands[:count])
    return chosen


def chord_tones(sym, lo, hi):
    pc, q, _ = chord_parse(sym)
    pcs = set((pc + iv) % 12 for iv in q)
    return [m for m in range(lo, hi + 1) if m % 12 in pcs]


def root_of(sym, octave_midi=36):
    _, _, bpc = chord_parse(sym)
    m = octave_midi + ((bpc - octave_midi) % 12)
    return m


def harmony_below(mel, chords_at, min_gap=3):
    """For each melody note, the nearest chord tone at least min_gap below."""
    out = []
    for (t, d, m) in mel:
        sym = chords_at(t)
        tones = chord_tones(sym, m - 12, m - min_gap)
        if tones:
            out.append((t, d, tones[-1]))
    return out


# -----------------------------------------------------------------------------
# Song: buses, placement, periodic mastering
# -----------------------------------------------------------------------------


class Song:
    def __init__(self, bpm, bars, beats=4, tail=4.0, transpose=0, seed='song', loop=True):
        self.bpm = bpm
        self.spb = 60.0 / bpm
        self.bars = bars
        self.beats = beats
        self.tr = transpose
        self.L = N(bars * beats * self.spb)
        self.loop = loop
        total = self.L + N(tail)
        self.dry = zeros(total)
        self.rev = zeros(total)
        self.echo = zeros(total)
        self.cho = zeros(total)
        self.rng = rng_for(seed)
        self.echo_time = self.spb * 0.75
        self.echo_fb = 0.38
        self.room = 0.84
        self.rev_gain = 1.0

    def pos(self, beat):
        return int(round(beat * self.spb * SR))

    def put(self, buf, beat, g=1.0, rev=0.2, echo=0.0, cho=0.0, jit=0.0):
        p = self.pos(beat)
        if jit:
            p += int(self.rng.uniform(-jit, jit) * SR)
        if cho > 0:
            mix(self.cho, buf, p, g * cho)
            g *= (1.0 - cho)
        mix(self.dry, buf, p, g)
        if rev:
            mix(self.rev, buf, p, g * rev)
        if echo:
            mix(self.echo, buf, p, g * echo)

    def beats_to_sec(self, b):
        return b * self.spb

    def master(self, peak_db=-1.0, comp=True, rev_width=1.0, hp=35.0, eq=()):
        L = self.L
        pre = N(4.0)
        if self.loop:
            dry = fold_tail(self.dry, L)
            rev = fold_tail(self.rev, L)
            ech = fold_tail(self.echo, L)
            cho = fold_tail(self.cho, L)
            P = lambda fn, x: periodic(fn, x, pre)
        else:
            dry, rev, ech, cho = self.dry, self.rev, self.echo, self.cho
            P = lambda fn, x: fn(x)
        if peak(cho) > 0:
            c = P(lambda x: chorus(x, 0.5, 0.004, 0.014, 2), cho)
            dry = list(map(add, dry, c))
            rev = [a + 0.35 * b for a, b in zip(rev, c)]
        if peak(ech) > 0:
            e = P(lambda x: echo(x, self.echo_time, self.echo_fb, 0.45), ech)
            dry = [a + 0.6 * b for a, b in zip(dry, e)]
            rev = [a + 0.3 * b for a, b in zip(rev, e)]
        w = P(lambda x: reverb(x, self.room, 0.28, 0.0, rev_width), rev)
        mixb = [a + self.rev_gain * b for a, b in zip(dry, w)]
        def tone(x):
            y = biquad(x, 'hp', hp, 0.7)
            for (kind, f, q, g) in eq:
                y = biquad(y, kind, f, q, g)
            return y
        mixb = P(tone, mixb)
        mixb = normalize(mixb, -3.0)
        if comp:
            mixb = P(lambda x: compress(x, -15.0, 2.5, 0.015, 0.2, 0.0), mixb)
        mixb = sat(normalize(mixb, -0.6), 1.15)
        out = normalize(mixb, peak_db)
        if not self.loop:
            out = fade_edges(trim_silence(out, -66.0, 0.05), 0.0005, 0.08)
        return out


def chords_fn(chart, beats=4):
    """chart: list per bar of 'C' or 'C G7' (split evenly). Returns f(beat)->sym."""
    def f(t):
        bi = int(t // beats)
        bi = max(0, min(len(chart) - 1, bi))
        parts = chart[bi].split()
        k = int((t - bi * beats) / (beats / len(parts)))
        return parts[max(0, min(len(parts) - 1, k))]
    return f


def chart_events(chart, beats=4):
    """[(beat, dur, sym)] from a bar chart."""
    ev = []
    for bi, bar in enumerate(chart):
        parts = bar.split()
        d = beats / len(parts)
        for k, sym in enumerate(parts):
            ev.append((bi * beats + k * d, d, sym))
    return ev


def drum_pattern(song, pattern, bar, fn, g=1.0, rev=0.1, jit=0.0, steps=16, vel_map=None):
    """pattern chars: X accent, x normal, o ghost, . rest."""
    vm = vel_map or {'X': 1.0, 'x': 0.72, 'o': 0.4}
    sb = song.beats / steps
    for i, ch in enumerate(pattern.replace(' ', '')):
        if ch in vm:
            song.put(fn(vm[ch]), bar * song.beats + i * sb, g, rev, jit=jit)


# -----------------------------------------------------------------------------
# MUSIC
# -----------------------------------------------------------------------------

THEME_A = ('C5:1.5 G4:.5 C5:1 E5:1 | G5:3 E5:.5 F5:.5 | G5:1.5 F5:.5 E5:1 D5:1 | E5:1.5 C5:.5 D5:2 | '
           'C5:1.5 G4:.5 C5:1 E5:1 | A5:3 G5:.5 F5:.5 | E5:1 G5:1 F5:1 D5:1')


def vq(v, step=0.05):
    return round(v / step) * step


def music_title():
    """Majestic serial-adventure overture: fanfare call, theme, heroic bVI-bVII-I."""
    s = Song(98, 16, tail=5.0, transpose=2, seed='music_title')
    T = s.tr
    s.room = 0.87
    chart = ['C', 'C', 'C', 'Am', 'F', 'G', 'C', 'F', 'C G7', 'C', 'Ab', 'Bb', 'C', 'Am', 'F Fm', 'Gsus4 G7']
    cf = chords_fn(chart)
    mel = seq('r:2 G4:.333 G4:.333 G4:.334 C5:1 | E5:1 G5:3 | ' + THEME_A + ' | C5:4 | '
              'C5:1 Eb5:1 Ab5:2 | G5:1 F5:1 D5:1 F5:1 | G5:1 C6:3 | B5:1 A5:1 E5:2 | '
              'F5:1 A5:1 C6:1 Ab5:1 | G5:4')
    # trumpet lead: FM trumpet doubled by subtractive brass for weight
    for (t, d, m) in mel:
        v = 0.8 if d < 1 else 0.92
        s.put(fmbrass(m + T, d * s.spb * 0.97, v, 1.2), t, 0.38, rev=0.32, jit=0.004)
        s.put(brass(m + T, d * s.spb * 0.97, v, 0.9, 1.0, 2), t, 0.34, rev=0.3)
    # glockenspiel doubling (sparkle) bars 7-10, 13-16
    for (t, d, m) in mel:
        b = t / 4
        if 6 <= b < 10 or 12 <= b < 15:
            s.put(glock(m + T + 12, 1.4, 0.5), t, 0.22, rev=0.35)
    # horns: sustained brass choir voicing
    for (t, d, sym) in chart_events(chart):
        vo = voicing(sym, 60 + T, 3)
        for m in vo:
            s.put(brass(m, d * s.spb * 0.98, 0.55, 0.45, 0.4, 2, 6.0, 0.09, 0.3, 10.0, 0.9, 1.6), t, 0.2, rev=0.4)
    # strings: whole-bar pads, tremolo in the climb
    for (t, d, sym) in chart_events(chart):
        b = t / 4
        tr = 0.7 if (10 <= b < 12 or b >= 15) else 0.0
        for m in voicing(sym, 67 + T, 4):
            s.put(strings(m, d * s.spb, 0.6, 0.12, 0.5, 1.0, tr, 98.0), t, 0.28, rev=0.45)
    # low brass + pizz bass
    for (t, d, sym) in chart_events(chart):
        r = root_of(sym, 36) + T
        s.put(brass(r + 12, d * s.spb * 0.9, 0.7, 0.45, 0.2, 2, 5.0, 0.03, 0.25, 15.0, 0.85, 1.6), t, 0.2, rev=0.25)
        for k in range(int(d)):
            m = r + 12 if k % 2 == 0 else r + 19
            s.put(pluck(m, 0.6, 0.7, 0.35, 0.993), t + k, 0.3, rev=0.2)
    # timpani (tuned to tonic/dominant)
    tim_hi, tim_lo = 38 + T - 2 + 7, 38 + T - 2
    for bar in (2, 4, 6, 8, 10, 12, 14):
        s.put(timpani(tim_lo + 12 if bar != 10 else tim_lo + 8, 1.0), bar * 4, 0.45, rev=0.3)
        s.put(timpani(tim_hi, 0.6), bar * 4 + 2, 0.32, rev=0.3)
    # timpani roll bar 1 (beats 0-2) and bar 16 (beats 2-4), crescendo
    s.put(timpani(tim_lo, 1.0, 2.5), 0.0, 0.5, rev=0.35)  # resolves the loop's G7
    s.put(crash(0.9, 2.6), 0.0, 0.42, rev=0.35)
    for (b0, b1) in ((0.25, 2.0), (62.0, 64.0)):
        k = 0
        t = b0
        while t < b1 - 0.01:
            v = (0.45 if b0 < 1 else 0.25) + 0.55 * (t - b0) / (b1 - b0)
            s.put(timpani(tim_lo + 12 if b0 < 1 else tim_hi, vq(v, 0.1)), t, 0.3, rev=0.3, jit=0.003)
            t += 0.125
            k += 1
    s.put(timpani(tim_lo + 12, 1.0), 2.0, 0.5, rev=0.3)
    # march snare: soft pattern in the theme, rolls into sections
    for bar in range(2, 16):
        if bar in (9, 15):
            continue
        drum_pattern(s, 'x..o x.o. x..o x.oo' if bar % 2 else 'x..o x.o. x..o xoxo', bar,
                     lambda v: snare(vq(v * 0.7), 230.0, 1.2, 0.1), 0.35, rev=0.2, jit=0.003)
    for (b0, b1) in ((36.0, 40.0), (60.0, 64.0)):
        t = b0
        while t < b1 - 0.01:
            v = 0.3 + 0.6 * (t - b0) / (b1 - b0)
            s.put(snare(vq(v, 0.1), 230.0, 1.2, 0.08), t, 0.35, rev=0.2, jit=0.002)
            t += 0.125
    # cymbals
    for b, v in ((8, 1.0), (40, 0.9), (44, 1.0), (52, 0.8)):
        s.put(crash(v, 2.6), b, 0.5, rev=0.35)
    s.put(reverse_swell(s.spb * 2.0, 0.7), 64 - 2.0, 0.5, rev=0.2)
    s.put(reverse_swell(s.spb * 2.0, 0.6), 44 - 2.0, 0.5, rev=0.2)
    # harp glissandi at the theme start and the climb
    for b0 in (8.0, 40.0):
        sym = cf(b0)
        tones = chord_tones(sym, 60 + T, 96 + T)
        for i, m in enumerate(tones):
            s.put(pluck(m, 1.2, 0.5, 0.7, 0.995), b0 - 1.0 + i * (1.0 / len(tones)), 0.25, rev=0.5)
    return s.master(eq=(('lowshelf', 120.0, 0.7, -3.0), ('peak', 2800.0, 0.8, 1.5)))


def music_level():
    """Driving 140 bpm adventure loop: FM trumpet theme, pumping FM bass, 16th arps,
    march-inflected drums, brass stabs, heroic bVI-bVII-I climb."""
    s = Song(140, 32, tail=4.0, transpose=2, seed='music_level')
    T = s.tr
    s.room = 0.8
    chart = ['C', 'Am', 'F', 'G', 'C', 'F', 'C G7', 'C',
             'C', 'Am', 'F', 'G', 'C', 'F', 'F G', 'E7',
             'Am', 'F', 'G', 'Em', 'F', 'G', 'Ab', 'Bb',
             'C', 'Am', 'F', 'G', 'Ab', 'Bb', 'Csus4 C', 'G']
    cf = chords_fn(chart)
    A = THEME_A + ' | C5:2 r:1 G4:.5 G4:.5'
    B = ('C5:1.5 G4:.5 C5:1 E5:1 | G5:3 E5:.5 F5:.5 | G5:1.5 F5:.5 E5:1 D5:1 | E5:1.5 C5:.5 D5:2 | '
         'C5:1.5 G4:.5 C5:1 E5:1 | A5:3 G5:.5 F5:.5 | A5:1 G5:1 F5:1 D5:1 | E5:1 G#5:1 B5:1 D6:1')
    C = ('A4:.5 C5:.5 E5:1 A5:1.5 G5:.5 | F5:1.5 E5:.5 C5:1 A4:1 | B4:.5 D5:.5 G5:1 B5:1.5 A5:.5 | G5:2 E5:2 | '
         'A5:.5 C6:.5 A5:.5 F5:.5 C5:1 F5:1 | B5:.5 D6:.5 B5:.5 G5:.5 D5:1 G5:1 | C6:1.5 Bb5:.5 Ab5:1 Eb5:1 | D6:2 F6:1 D6:1')
    D = ('E6:1.5 D6:.5 C6:1 G5:1 | A5:1.5 B5:.5 C6:1 E6:1 | F6:1.5 E6:.5 D6:1 C6:1 | D6:3 r:1 | '
         'Ab5:1.5 C6:.5 Eb6:2 | D6:1.5 C6:.5 Bb5:1 F6:1 | F6:2 E6:2 | D6:1 B5:1 G5:1 B4:1')
    melA = seq(A, 0)
    melB = seq(B, 32)
    melC = seq(C, 64)
    melD = seq(D, 96)
    # --- lead
    for (t, d, m) in melA + melB:
        s.put(fmbrass(m + T, d * s.spb * 0.92, 0.85, 1.0), t, 0.42, rev=0.22, echo=0.12, jit=0.003)
    for (t, d, m) in melB:  # square lead an octave up, quiet
        s.put(square_pluck(m + T + 12, d * s.spb * 0.9, 0.35, 0.25 + d * 0.15, 5.0, 'pulse25'), t, 0.2, rev=0.2, echo=0.25)
    for (t, d, m) in harmony_below(melB, cf):
        s.put(brass(m + T, d * s.spb * 0.9, 0.7, 0.8, 0.8, 2), t, 0.24, rev=0.25)
    for (t, d, m) in melC:
        s.put(brass(m + T, d * s.spb * 0.92, 0.9, 1.1, 1.0, 3), t, 0.4, rev=0.25, echo=0.08)
        s.put(strings(m + T - 12, d * s.spb * 0.95, 0.8, 0.03, 0.2, 1.2), t, 0.3, rev=0.3)
    for (t, d, m) in melD:
        s.put(fmbrass(m + T - 12, d * s.spb * 0.92, 0.9, 1.2), t, 0.34, rev=0.25, echo=0.1)
        s.put(square_pluck(m + T, d * s.spb * 0.92, 0.35, 0.2 + d * 0.2, 6.0, 'saw'), t, 0.2, rev=0.25, echo=0.3)
    for (t, d, m) in harmony_below(melD, cf):
        s.put(brass(m + T - 12, d * s.spb * 0.9, 0.7, 0.8, 0.8, 2), t, 0.22, rev=0.25)
    # --- bass
    ev = chart_events(chart)
    for i, (t, d, sym) in enumerate(ev):
        r = root_of(sym, 33) + T
        nxt = root_of(ev[(i + 1) % len(ev)][2], 33) + T
        sec = int(t // 32)
        steps = int(round(d * 2))
        if sec == 2:  # gallop: 8th + two 16ths
            for k in range(int(d)):
                for (o, du) in ((0.0, 0.5), (0.5, 0.25), (0.75, 0.25)):
                    m = r if o == 0 else r + (12 if o == 0.5 else 0)
                    s.put(fmbass(m, du * s.spb * 0.85, 0.9, 3.4), t + k + o, 0.5, rev=0.05)
        else:
            for k in range(steps):
                m = r + (12 if k % 2 else 0)
                if k == steps - 1 and nxt != r and (i % 2 == 1 or d < 4):
                    m = nxt - 1 if nxt > r else nxt + 2
                s.put(fmbass(m, 0.5 * s.spb * 0.8, 0.85 if k % 2 == 0 else 0.7, 3.0), t + k * 0.5, 0.5, rev=0.05)
    # --- arps (B and D sections): 16th chord arpeggio with dotted echo
    arp_shape = [0, 1, 2, 3, 2, 1, 2, 3]
    for (t, d, sym) in ev:
        sec = int(t // 32)
        if sec not in (1, 3):
            continue
        tones = voicing(sym, 72 + T, 4)
        for k in range(int(d * 4)):
            m = tones[arp_shape[k % 8] % len(tones)]
            s.put(square_pluck(m, 0.12, 0.45, 0.07, 4.0, 'square'), t + k * 0.25, 0.14, rev=0.15, echo=0.35)
    # --- strings pads (B, C, D) and brass stabs
    for (t, d, sym) in ev:
        sec = int(t // 32)
        if sec in (1, 2, 3):
            for m in voicing(sym, 64 + T, 4):
                s.put(strings(m, d * s.spb, 0.55, 0.2, 0.4, 0.9), t, 0.22, rev=0.35)
    stab_bars = [(1, 3.5), (3, 3.5), (5, 3.5), (9, 3.5), (11, 3.5), (13, 3.5)]
    for (bar, beat) in stab_bars:
        sym = cf((bar + 1) * 4)
        for m in voicing(sym, 67 + T, 4):
            s.put(brass(m, 0.35 * s.spb, 0.95, 1.2, 0.0, 2, 8.0, 0.005, 0.08, 20.0), bar * 4 + beat, 0.2, rev=0.3)
    for bar in range(16, 24):  # C section syncopated stabs
        sym = cf(bar * 4)
        for beat in (0.0, 1.5, 3.0):
            for m in voicing(sym, 60 + T, 3):
                s.put(brass(m, 0.3 * s.spb, 0.9, 1.0, 0.0, 2, 8.0, 0.005, 0.08, 20.0), bar * 4 + beat, 0.17, rev=0.25)
    for bar in range(24, 32):  # D: offbeat stabs
        sym = cf(bar * 4)
        for beat in (1.5, 3.5):
            for m in voicing(sym, 67 + T, 3):
                s.put(brass(m, 0.25 * s.spb, 0.9, 1.1, 0.0, 2, 8.0, 0.005, 0.07, 20.0), bar * 4 + beat, 0.15, rev=0.25)
    # --- march 'pah' horn chords on 2 and 4 under the A section
    for bar in range(0, 8):
        sym = cf(bar * 4)
        for beat in (1.0, 3.0):
            for m in voicing(sym, 62 + T, 3):
                s.put(brass(m, 0.28 * s.spb, 0.7, 0.8, 0.0, 2, 6.0, 0.006, 0.07, 10.0, 0.9, 1.3), bar * 4 + beat, 0.11, rev=0.2)
    # --- xylophone runs into each section
    for bar in (7, 15, 23):
        sym = cf((bar + 1) * 4)
        tones = chord_tones(sym, 72 + T, 91 + T)
        run = tones[-8:]
        for i, m in enumerate(run):
            s.put(xylo(m, 0.6 + 0.05 * i), bar * 4 + 4 - len(run) * 0.25 + i * 0.25, 0.28, rev=0.2, echo=0.1)
    # --- drums
    K = lambda v: kick(vq(v), 1.0)
    S = lambda v: snare(vq(v), 200.0, 1.0, 0.15)
    Hc = lambda v: hat(vq(v), False)
    Ho = lambda v: hat(vq(v), True)
    for bar in range(32):
        sec = bar // 8
        fill = bar % 8 == 7
        if sec == 2:
            drum_pattern(s, 'X.....X.X.....X.', bar, K, 0.95)
        elif sec == 3:
            drum_pattern(s, 'X.....x.X.x.....', bar, K, 0.95)
        else:
            drum_pattern(s, 'X.....x.X.......', bar, K, 0.95)
        if fill and bar == 31:
            drum_pattern(s, '....X...X.x.XxXx', bar, S, 0.55, rev=0.18)
            for i, m in enumerate([50, 50, 47, 47, 43, 43, 40, 40]):
                s.put(tom(m + T, 0.8 + 0.02 * i), bar * 4 + 2 + i * 0.25, 0.5, rev=0.2)
        elif fill:
            drum_pattern(s, '....X.......XoXx', bar, S, 0.55, rev=0.18)
        elif sec == 3:
            drum_pattern(s, '....X..o....X..o', bar, S, 0.55, rev=0.18)
        else:
            drum_pattern(s, '....X.......X...', bar, S, 0.55, rev=0.18)
        if sec == 3:
            drum_pattern(s, '..x...x...x...x.', bar, Ho, 0.2, rev=0.05)
            drum_pattern(s, 'x...x...x...x...', bar, Hc, 0.25, rev=0.05)
        else:
            drum_pattern(s, 'x.o.x.o.x.o.x.oo' if bar % 4 != 3 else 'x.o.x.o.x.o.x...', bar, Hc, 0.28, rev=0.05, jit=0.002)
            if bar % 4 == 3:
                drum_pattern(s, '..............x.', bar, Ho, 0.22, rev=0.05)
    for bar in (0, 8, 16, 24):
        s.put(crash(1.0, 2.2), bar * 4, 0.42, rev=0.25)
    for bar in (16, 20, 24, 28):
        s.put(timpani(38 + T - 2, 1.0), bar * 4, 0.6, rev=0.25)
    s.put(reverse_swell(s.spb * 2, 0.8), 64 - 2, 0.45)
    s.put(reverse_swell(s.spb * 2, 0.8), 128 - 2, 0.45)
    s.put(riser(s.spb * 8, 0.6), 120.0, 0.18, rev=0.3)
    # 8th snare build in bar 31
    for k in range(8):
        s.put(snare(vq(0.35 + 0.06 * k), 200.0, 1.0, 0.1), 30 * 4 + k * 0.5, 0.4, rev=0.18)
    return s.master(eq=(('lowshelf', 70.0, 0.7, -4.0), ('peak', 2500.0, 0.8, 2.0)))


def music_boss():
    """Tense 160 bpm battle: distorted 16th ostinato, villain low-brass motif,
    hero theme in minor, tremolo strings, anvil hits."""
    s = Song(160, 24, tail=4.0, transpose=2, seed='music_boss')
    T = s.tr
    s.room = 0.78
    chart = ['Cm', 'Cm', 'Ab', 'Ab', 'Fm', 'Fm', 'G', 'G',
             'Cm', 'Ab', 'Fm', 'G', 'Cm', 'Ab', 'Db', 'G',
             'Ab', 'Bb', 'Cm', 'Cm', 'Ab', 'Bb', 'G', 'G']
    cf = chords_fn(chart)
    villain = seq('C3:1.5 C3:.5 Db3:1 C3:1 | Gb3:3 G3:1 | Ab2:1.5 Ab2:.5 A2:1 Ab2:1 | Eb3:3 D3:1 | '
                  'F3:1.5 F3:.5 Gb3:1 F3:1 | C3:3 Db3:1 | D3:1.5 D3:.5 Eb3:1 D3:1 | G2:1 B2:1 D3:1 F3:1')
    hero = seq('C5:1.5 G4:.5 C5:1 Eb5:1 | G5:3 Eb5:.5 F5:.5 | Ab5:1.5 G5:.5 F5:1 Eb5:1 | D5:2 B4:1 D5:1 | '
               'C5:1.5 G4:.5 C5:1 Eb5:1 | C6:3 Bb5:.5 Ab5:.5 | Ab5:1 F5:1 Db5:1 F5:1 | G5:2 D5:1 B4:1', 32)
    climb = seq('C6:3 Bb5:1 | D6:3 C6:.5 Bb5:.5 | C6:2 G5:2 | Eb6:2 D6:1 C6:1 | C6:2 Ab5:1 C6:1 | D6:2 F6:2 | '
                'B5:2 D6:2 | G5:4', 64)
    for (t, d, m) in villain:
        s.put(brass(m + T, d * s.spb * 0.95, 0.95, 1.1, 0.3, 3, 10.0, 0.02, 0.15, 25.0, 0.85, 1.3), t, 0.5, rev=0.2)
        s.put(brass(m + T + 12, d * s.spb * 0.95, 0.8, 0.8, 0.3, 2, 8.0, 0.02, 0.15, 25.0, 0.85, 1.5), t, 0.2, rev=0.2)
    for (t, d, m) in hero:
        s.put(fmbrass(m + T, d * s.spb * 0.93, 0.9, 1.3), t, 0.42, rev=0.22, echo=0.1)
        s.put(brass(m + T - 12, d * s.spb * 0.93, 0.8, 0.9, 0.6, 2), t, 0.22, rev=0.2)
    for (t, d, m) in climb:
        s.put(fmbrass(m + T - 12, d * s.spb * 0.95, 0.95, 1.4), t, 0.4, rev=0.25, echo=0.1)
        s.put(strings(m + T, d * s.spb * 0.95, 0.75, 0.04, 0.3, 1.3), t, 0.3, rev=0.3)
    ev = chart_events(chart)
    # 16th ostinato bass
    pat = [0, 0, 12, 0, 0, 0, 12, 0, 0, 0, 12, 0, 1, 0, 6, 0]
    for (t, d, sym) in ev:
        r = root_of(sym, 33) + T
        for k in range(int(d * 4)):
            iv = pat[k % 16]
            v = 0.95 if k % 4 == 0 else 0.75
            s.put(sawbass(r + iv, 0.25 * s.spb * 0.8, vq(v), 700.0, 2600.0, 2.4), t + k * 0.25, 0.42, rev=0.04)
    # tremolo strings (tension), 16th runs in the climb
    for (t, d, sym) in ev:
        sec = int(t // 32)
        for m in voicing(sym, 67 + T, 3):
            s.put(strings(m, d * s.spb, 0.6, 0.05, 0.3, 1.1, 0.85, 160.0), t, 0.25, rev=0.3)
        if sec == 2:
            tones = chord_tones(sym, 72 + T, 88 + T)
            run = tones + tones[-2:0:-1]
            for k in range(int(d * 4)):
                s.put(strings(run[k % len(run)], 0.25 * s.spb, 0.6, 0.008, 0.08, 1.4), t + k * 0.25, 0.14, rev=0.25)
    # stabs + anvils
    for bar in (0, 8, 16):
        sym = cf(bar * 4)
        for m in voicing(sym, 60 + T, 4):
            s.put(brass(m, 0.5 * s.spb, 1.0, 1.4, 0.0, 3, 10.0, 0.004, 0.2, 30.0), bar * 4, 0.22, rev=0.4)
        s.put(clang(1.0), bar * 4, 0.35, rev=0.4)
        s.put(timpani(38 + T - 2, 1.0), bar * 4, 0.6, rev=0.3)
        s.put(crash(1.0, 2.0), bar * 4, 0.4, rev=0.25)
    for bar in range(24):
        if bar % 2 == 1:
            s.put(clang(0.6), bar * 4 + 3.5, 0.18, rev=0.3)
    # tritone stab fill in the last bar
    for k, beat in enumerate((0.0, 0.75, 1.5, 2.25)):
        for m in ([62, 68, 74] if k % 2 else [67, 71, 74]):
            s.put(brass(m + T, 0.3 * s.spb, 1.0, 1.4, 0.0, 2, 8.0, 0.004, 0.08, 30.0), 23 * 4 + beat, 0.2, rev=0.3)
    # drums
    K = lambda v: kick(vq(v), 1.1)
    S = lambda v: snare(vq(v), 180.0, 1.2, 0.13)
    Hc = lambda v: hat(vq(v), False)
    for bar in range(24):
        sec = bar // 8
        drum_pattern(s, 'X...X.x.X...X.x.' if sec != 2 else 'X.x.X.x.X.x.X.x.', bar, K, 0.95)
        if bar % 4 == 3:
            drum_pattern(s, '....X.......XxXX', bar, S, 0.55, rev=0.2)
        else:
            drum_pattern(s, '....X.......X...', bar, S, 0.55, rev=0.2)
        drum_pattern(s, 'x.x.x.x.x.x.x.x.' if sec == 0 else 'xoxoxoxoxoxoxoxo', bar, Hc, 0.26, rev=0.05, jit=0.002)
        if sec == 0 and bar % 2 == 0:
            for i, beat in enumerate((1.5, 2.5, 2.75)):
                s.put(tom(45 + T - 2 - i * 3, 0.8), bar * 4 + beat, 0.4, rev=0.2)
    for k in range(8):
        s.put(tom(50 + T - 2 - k * 2, 0.7 + 0.03 * k), 23 * 4 + 2 + k * 0.25, 0.45, rev=0.2)
    return s.master(eq=(('lowshelf', 70.0, 0.7, -4.0), ('peak', 2500.0, 0.8, 2.0)))


def music_violet():
    """Dreamy lydian reprise: chorused pads, FM glass arps with dotted echo,
    Karplus-Strong harp, choir lead, half-time beat."""
    s = Song(120, 24, tail=6.0, transpose=2, seed='music_violet')
    T = s.tr
    s.room = 0.9
    s.echo_time = s.spb * 0.75
    s.echo_fb = 0.45
    chart = ['Cmaj7', 'D/C', 'Em7', 'D', 'Cmaj7', 'D/C', 'Am7', 'D',
             'Cmaj7', 'D/C', 'Em7', 'Bm7', 'Am7', 'Cmaj7', 'Dsus4', 'D',
             'Am7', 'Em7', 'Cmaj7', 'D', 'Am7', 'Em7', 'Dsus2', 'D']
    ev = chart_events(chart)
    lead = seq('C5:1.5 G4:.5 C5:1 E5:1 | F#5:3 E5:.5 F#5:.5 | G5:1.5 F#5:.5 E5:1 D5:1 | D5:1.5 B4:.5 F#5:2 | '
               'C5:1.5 G4:.5 C5:1 E5:1 | B5:3 A5:.5 G5:.5 | G5:2 A5:2 | F#5:4', 32)
    counter = seq('E6:4 | D6:4 | B5:4 | A5:4 | C6:4 | B5:4 | A5:2 G5:2 | F#5:4', 64)
    t0, th = theremin_line(s, lead, T)
    s.put(th, t0, 0.3, rev=0.5, echo=0.22)
    for (t, d, m) in lead:
        s.put(choir(m + T - 12, d * s.spb * 1.0, 0.45, 0.2, 0.6, 'oo'), t, 0.18, rev=0.5)
        s.put(bell(m + T + 12, 1.6, 0.45, 2.0, 1.0, 0.7), t, 0.1, rev=0.5, echo=0.3)
    for (t, d, m) in counter:
        s.put(bell(m + T, 3.0, 0.6, 3.5, 1.6, 1.2), t, 0.22, rev=0.55, echo=0.35)
        s.put(choir(m + T - 12, d * s.spb, 0.5, 0.4, 0.8, 'oo'), t, 0.2, rev=0.5)
    # pads (chorus bus)
    for (t, d, sym) in ev:
        for m in voicing(sym, 62 + T, 4):
            s.put(pad(m, d * s.spb, 0.7, 0.35, 1.0, 2400.0), t, 0.3, rev=0.5, cho=0.6)
    # glass arp: 8ths
    shape = [0, 2, 1, 3, 2, 4, 3, 1]
    for (t, d, sym) in ev:
        tones = voicing(sym, 81 + T, 5)
        for k in range(int(d * 2)):
            m = tones[shape[k % 8] % len(tones)]
            v = 0.55 if k % 2 == 0 else 0.4
            s.put(bell(m, 0.9, v, 3.0, 1.2, 0.35), t + k * 0.5, 0.16, rev=0.35, echo=0.4)
    # harp 16ths in the second half
    for (t, d, sym) in ev:
        if t < 32:
            continue
        tones = chord_tones(sym, 55 + T, 79 + T)
        up = tones + tones[-2:0:-1]
        for k in range(int(d * 4)):
            s.put(pluck(up[k % len(up)], 0.9, 0.5, 0.45, 0.994), t + k * 0.25, 0.12, rev=0.4, echo=0.15)
    # sub bass: roots with a lift
    for i, (t, d, sym) in enumerate(ev):
        r = root_of(sym, 33) + T
        s.put(square_pluck(r, d * s.spb * 0.55, 0.9, 0.5, 3.0, 'tri'), t, 0.8, rev=0.05)
        s.put(square_pluck(r + 12, d * s.spb * 0.2, 0.6, 0.3, 3.0, 'tri'), t + 2.5, 0.45, rev=0.05)
        s.put(square_pluck(r, d * s.spb * 0.15, 0.5, 0.3, 3.0, 'tri'), t + 3.0, 0.45, rev=0.05)
    # beat (half-time)
    K = lambda v: kick(vq(v), 0.8)
    S = lambda v: snare(vq(v), 240.0, 0.8, 0.22)
    Sh = lambda v: shaker(vq(v))
    for bar in range(24):
        if bar >= 8:
            drum_pattern(s, 'X.........x.....', bar, K, 0.75, rev=0.1)
            drum_pattern(s, '........X.......', bar, S, 0.4, rev=0.45)
        drum_pattern(s, 'x.ox.oxox.ox.oxo', bar, Sh, 0.22, rev=0.2, jit=0.003)
        if bar % 4 == 3:
            drum_pattern(s, '..............x.', bar, lambda v: hat(vq(v), True), 0.18, rev=0.3)
    for b in (32, 64):
        s.put(reverse_swell(s.spb * 4, 0.7), b - 4, 0.35, rev=0.3)
        s.put(crash(0.7, 3.0), b, 0.3, rev=0.5)
    s.put(reverse_swell(s.spb * 4, 0.6), 96 - 4, 0.3, rev=0.3)
    # twinkles
    r = rng_for('violet_twinkle')
    for k in range(40):
        t = r.uniform(0, 96)
        sym = chords_fn(chart)(t)
        tones = chord_tones(sym, 88 + T, 100 + T)
        m = r.choice(tones)
        s.put(bell(m, 1.2, 0.35, 3.5, 0.8, 0.4), round(t * 4) / 4, 0.1, rev=0.6, echo=0.5)
    return s.master(eq=(('peak', 300.0, 0.8, -3.0), ('highshelf', 6000.0, 0.7, 1.5)))


def jingle_clear():
    """Mission complete fanfare (one shot)."""
    s = Song(132, 4, tail=3.5, transpose=2, seed='jingle_clear', loop=False)
    T = s.tr
    mel = seq('G4:.333 G4:.333 G4:.334 C5:1 E5:1 G5:1 | Ab5:.75 Bb5:.25 C6:3 | r:4 | r:4')
    for (t, d, m) in mel:
        s.put(fmbrass(m + T, d * s.spb * 0.95, 0.95, 1.2), t, 0.45, rev=0.3)
        s.put(brass(m + T - 12, d * s.spb * 0.95, 0.85, 1.0, 0.8, 2), t, 0.3, rev=0.3)
    for (t, d, sym) in [(0, 2, 'C'), (2, 2, 'G'), (4, 0.75, 'Ab'), (4.75, 0.25, 'Bb'), (5, 3, 'C')]:
        for m in voicing(sym, 64 + T, 4):
            s.put(strings(m, d * s.spb, 0.7, 0.05, 0.8), t, 0.3, rev=0.4)
            s.put(brass(m - 12, d * s.spb, 0.7, 0.6, 0.3, 2), t, 0.18, rev=0.4)
    for m in voicing('C', 60 + T, 4):
        s.put(brass(m, 3.0 * s.spb, 0.95, 1.2, 0.8, 3), 5.0, 0.25, rev=0.4)
    t = 5.0
    while t < 8.0:
        s.put(timpani(36 + T, vq(0.4 + 0.2 * (t - 5)), 1.5), t, 0.4, rev=0.3)
        t += 0.125
    s.put(timpani(36 + T, 1.0, 2.5), 8.0, 0.8, rev=0.4)
    s.put(crash(1.0, 3.0), 5.0, 0.5, rev=0.4)
    s.put(crash(1.0, 3.0), 8.0, 0.5, rev=0.4)
    s.put(kick(1.0), 8.0, 0.6)
    for i, m in enumerate(chord_tones('C', 72 + T, 96 + T)):
        s.put(glock(m, 1.5, 0.6), 5.0 + i * 0.125, 0.18, rev=0.5)
    for m in voicing('C', 72 + T, 4):
        s.put(fmbrass(m, 1.5, 0.95, 1.0), 8.0, 0.2, rev=0.4)
    s.put(fmbrass(84 + T, 2.2, 0.95, 1.4), 8.0, 0.3, rev=0.4)
    return s.master(-1.0, comp=False)


def jingle_over():
    """Game over: brass lament descending into D minor (one shot)."""
    s = Song(88, 2, tail=3.0, transpose=2, seed='jingle_over', loop=False)
    T = s.tr
    mel = seq('Eb5:1 D5:1 Db5:1 C5:1 | Ab4:1 G4:1 C5:2')
    for (t, d, m) in mel:
        s.put(brass(m + T, d * s.spb * 0.95, 0.75, 0.6, 1.4, 2), t, 0.45, rev=0.45)
    for (t, d, sym) in [(0, 4, 'Ab'), (4, 1, 'Fm'), (5, 1, 'G7'), (6, 2, 'Cm')]:
        for m in voicing(sym, 60 + T, 4):
            s.put(strings(m, d * s.spb, 0.6, 0.2, 1.2, 0.7), t, 0.3, rev=0.5)
        s.put(brass(root_of(sym, 36) + T, d * s.spb, 0.7, 0.4, 0.3, 2), t, 0.35, rev=0.4)
    s.put(timpani(36 + T, 0.8, 3.0), 6.0, 0.6, rev=0.5)
    s.put(timpani(43 + T, 0.5, 1.5), 0.0, 0.4, rev=0.5)
    return s.master(-1.5, comp=False)


# -----------------------------------------------------------------------------
# AMBIENCE LOOPS
# -----------------------------------------------------------------------------


def loop_noise_lfo(n, cycles, ph=0.0):
    """LFO with an integer number of cycles over n samples (seamless)."""
    w = TAU * cycles / n
    return [math.sin(w * i + ph) for i in range(n)]


def amb_wind():
    L = N(8.0)
    r = rng_for('wind')
    pre = N(1.0)
    nz = [r.uniform(-1, 1) for _ in range(L)]
    pink = periodic(lambda x: lp1(x, 900.0), nz, pre)
    g1 = loop_noise_lfo(L, 1, 0.3)
    g2 = loop_noise_lfo(L, 3, 1.7)
    g3 = loop_noise_lfo(L, 5, 4.1)
    gust = [0.55 + 0.25 * a + 0.12 * b + 0.08 * c for a, b, c in zip(g1, g2, g3)]
    fc = [500.0 + 700.0 * g for g in gust]
    body = periodic(lambda x: svf(x, fc[-pre:] + fc if len(x) > L else fc, 1.6, 'bp'), nz, pre)
    fcw = [900.0 + 500.0 * (0.5 + 0.5 * a) for a in loop_noise_lfo(L, 2, 0.9)]
    whistle = periodic(lambda x: svf(x, fcw[-pre:] + fcw, 9.0, 'bp'), nz, pre)
    y = [0.9 * a * g + 0.35 * b * g + 0.25 * c * g * g for a, b, c, g in zip(body, pink, whistle, gust)]
    return normalize(y, -3.0)


def amb_jet(boost=False):
    L = N(4.0)
    name = 'jet_boost' if boost else 'jet'
    r = rng_for(name)
    pre = N(0.5)
    nz = [r.uniform(-1, 1) for _ in range(L)]
    brown = periodic(lambda x: lp1(lp1(x, 120.0), 240.0), nz, pre)
    roar = periodic(lambda x: biquad(x, 'bp', 1400.0 if boost else 800.0, 0.8), nz, pre)
    hiss = periodic(lambda x: biquad(x, 'hp', 5000.0, 0.7), nz, pre)
    flut = loop_noise_lfo(L, 4 * 34 if boost else 4 * 27)
    slow = loop_noise_lfo(L, 3, 0.5)
    hum_f = 55.0 * (1.5 if boost else 1.0)
    hum = [0.0] * L
    for k, a in ((1, 1.0), (2, 0.5), (3, 0.3), (4, 0.15)):
        hum = list(map(add, hum, scale(sine(hum_f * k, L, 0.1 * k), a)))
    whine = sine(880.0 if boost else 660.0, L)
    whine2 = sine(1760.0 if boost else 1320.0, L, 0.3)
    crackle = [0.0] * L
    for _ in range(int((260 if boost else 140) * 4)):
        p = r.randrange(L)
        a = r.uniform(0.2, 1.0)
        for j in range(r.randrange(20, 90)):
            crackle[(p + j) % L] += a * r.uniform(-1, 1) * (1.0 - j / 90.0)
    crackle = periodic(lambda x: hp1(x, 1500.0), crackle, pre)
    y = []
    kb = 1.0 if boost else 0.0
    for i in range(L):
        f = 1.0 + 0.18 * flut[i] + 0.1 * slow[i]
        y.append(brown[i] * 5.0 * f + roar[i] * (0.5 + 0.4 * kb) * f + hiss[i] * (0.08 + 0.12 * kb)
                 + hum[i] * 0.12 + (whine[i] + 0.5 * whine2[i]) * (0.012 + 0.03 * kb) + crackle[i] * (0.25 + 0.2 * kb))
    y = periodic(lambda x: sat(x, 1.3), y, 16)
    return normalize(y, -3.0)


def charge_pair():
    """charge (rise) and charge_hold (loop) scaled together so the handoff is level."""
    a = sfx_charge()
    b = charge_hold()
    k = db(-5.0) / max(peak(a), peak(b))
    a, b = scale(a, k), scale(b, k)
    # the hold loop's head fades in: carry its fading-out twin so the handoff sums flat
    X = xfade_len('charge_hold')
    a = a + [v * (1.0 - i / X) for i, v in enumerate(b[:X])]
    return a, b


def charge_hold():
    """0.5 s seamless 'ready' shimmer that follows `charge`."""
    L = N(0.5)
    tab = bltab('saw', 1320.0)
    a = osc(tab, 1298.0, L)
    b = osc(tab, 1302.0, L, 0.5)
    sub = sine(650.0, L)
    hi = sine(2600.0, L, 0.2)
    trem = loop_noise_lfo(L, 12)
    am = loop_noise_lfo(L, 4)
    y = [(0.3 * (p + q) + 0.4 * s_ + 0.25 * h * (0.6 + 0.4 * m)) * (0.85 + 0.15 * t)
         for p, q, s_, h, t, m in zip(a, b, sub, hi, trem, am)]
    return periodic(lambda x: lp1(x, 6000.0), y, N(0.1))


# -----------------------------------------------------------------------------
# SFX
# -----------------------------------------------------------------------------


def sfx_laser(variant=0):
    r = rng_for('laser%d' % variant)
    f0, f1 = [(2300.0, 360.0), (2550.0, 420.0), (2100.0, 330.0)][variant]
    n = N(0.2)
    fr = sweep_exp(n, f0, f1, 0.04)
    a = osc(bltab('square', f0), fr, n)
    b = sine([f * 2.0 for f in fr], n)
    wob = sine(95.0 + 10 * variant, n)
    y = [0.6 * p * (0.85 + 0.15 * w) + 0.3 * q for p, q, w in zip(a, b, wob)]
    e = env_ar(n, 0.0015, 0.045)
    y = vmul(y, e)
    click = vmul(hp1(white(n, r), 3000.0), env_exp(n, 0.002))
    y = [p + 0.25 * c for p, c in zip(y, click)]
    y = biquad(y, 'hp', 250.0, 0.7)
    wet = echo(y + zeros(N(0.15)), 0.055, 0.25, 0.5)
    y = [p + 0.22 * w for p, w in zip(y + zeros(N(0.15)), wet)]
    return y


def sfx_charge():
    n = N(1.0)
    r = rng_for('charge')
    t = [i / n for i in range(n)]
    fr = [180.0 * (1300.0 / 180.0) ** (u ** 1.35) for u in t]
    tab = bltab('saw', 1350.0)
    a = osc(tab, [f * 0.997 for f in fr], n)
    b = osc(tab, [f * 1.003 for f in fr], n, 0.5)
    sub = sine([f * 0.5 for f in fr], n)
    cut = [f * (2.5 + 5.0 * u) for f, u in zip(fr, t)]
    y = svf([p + q for p, q in zip(a, b)], cut, 1.2, 'lp')
    # accelerating tremolo
    ph = list(accumulate([(6.0 + 20.0 * u * u) / SR for u in t]))
    trem = [0.8 + 0.2 * math.sin(TAU * p) for p in ph]
    wh = svf(white(n, r), [f * 2.0 for f in fr], 3.0, 'bp')
    amp = [0.35 + 0.65 * u ** 0.8 for u in t]
    y = [(0.3 * p + 0.4 * s_ + 0.25 * w) * tr * a_ for p, s_, w, tr, a_ in zip(y, sub, wh, trem, amp)]
    k = N(0.01)
    for i in range(k):
        y[i] *= i / k
    return y


def sfx_nova():
    n = N(2.2)
    r = rng_for('nova')
    crack = vmul(hp1(white(n, r), 1500.0), env_exp(n, 0.02))
    zap = vmul(sine(sweep_exp(n, 3200.0, 180.0, 0.07), n), env_exp(n, 0.12))
    fr = sweep_exp(n, 165.0, 110.0, 0.2)
    ch = zeros(n)
    for mult in (1.0, 1.5, 2.0, 1.005):
        tab = bltab('saw', 170.0 * mult)
        ch = list(map(add, ch, osc(tab, [f * mult for f in fr], n, r.random())))
    cut = sweep_exp(n, 9000.0, 300.0, 0.45)
    vw = vmul(svf(ch, cut, 1.4, 'lp'), env_ar(n, 0.01, 0.55))
    sub = vmul(sine(sweep_exp(n, 95.0, 32.0, 0.12), n), env_ar(n, 0.002, 0.35))
    sh = zeros(n)
    for k in range(18):
        m = 84 + r.choice([0, 4, 7, 12, 16, 19])
        b = bell(m, 1.0, 0.5, 3.5, 1.4, 0.3)
        mix(sh, b, N(0.03 + k * 0.04 + r.uniform(0, 0.02)), 0.2 * (1 - k / 18))
    y = [0.5 * a + 0.35 * b + 0.5 * c + 0.9 * d + 0.5 * e for a, b, c, d, e in zip(crack, zap, vw, sub, sh)]
    y = sat(y, 1.6)
    w = reverb(y, 0.86, 0.3)
    return [a + 0.6 * b for a, b in zip(y, w)]


def sfx_hit(variant=0):
    r = rng_for('hit%d' % variant)
    n = N(0.22)
    fs = [(1400.0, 2150.0, 3300.0), (1250.0, 1980.0, 3050.0)][variant]
    y = zeros(n)
    for f, a, d in zip(fs, (1.0, 0.6, 0.4), (0.07, 0.05, 0.03)):
        y = [p + a * q * e for p, q, e in zip(y, sine(f, n), env_exp(n, d))]
    nz = vmul(biquad(white(n, r), 'bp', 2600.0, 1.0), env_exp(n, 0.015))
    th = vmul(sine(sweep_exp(n, 260.0, 120.0, 0.03), n), env_exp(n, 0.045))
    y = [0.35 * p + 0.8 * q + 0.8 * t for p, q, t in zip(y, nz, th)]
    return fade_edges(sat(y, 1.4), 0.0005, 0.03)


def boom(n, r, f0=110.0, f1=38.0, dur=0.25, lp0=4000.0, lp1_=300.0, lptau=0.15, ntau=0.22, crackle=150.0, ctau=0.35):
    thump = vmul(sine(sweep_exp(n, f0, f1, 0.05), n), env_ar(n, 0.002, dur))
    br = lp1(white(n, r), 2500.0)
    body = vmul(svf(br, sweep_exp(n, lp0, lp1_, lptau), 0.9, 'lp'), env_ar(n, 0.004, ntau))
    cr = zeros(n)
    t = 0.0
    total = n / SR
    while t < total:
        dens = crackle * math.exp(-t / ctau)
        if dens < 2:
            break
        t += r.expovariate(dens)
        p = N(t)
        k = r.randrange(30, 140)
        a = r.uniform(0.3, 1.0) * math.exp(-t / ctau)
        seg = [a * r.uniform(-1, 1) * (1 - j / k) for j in range(k)]
        mix(cr, seg, p)
    cr = hp1(cr, 1800.0)
    return [1.0 * a + 1.3 * b + 0.5 * c for a, b, c in zip(thump, body, cr)]


def sfx_explode_small(variant=0):
    r = rng_for('explode_small%d' % variant)
    n = N(1.0)
    y = boom(n, r, 115.0 - 15 * variant, 38.0, 0.22, 4500.0 - 800 * variant, 280.0, 0.14, 0.2, 170.0, 0.3)
    y = sat(y, 2.0)
    w = reverb(y, 0.7, 0.35)
    return trim_silence([a + 0.35 * b for a, b in zip(y, w)], -60)


def sfx_explode_big():
    r = rng_for('explode_big')
    n = N(3.2)
    y = boom(n, r, 90.0, 28.0, 0.55, 6500.0, 150.0, 0.35, 0.5, 260.0, 0.7)
    for (t0, g) in ((0.16, 0.6), (0.42, 0.45), (0.75, 0.3)):
        m = n - N(t0)
        b = boom(m, r, 100.0, 40.0, 0.2, 3500.0, 250.0, 0.12, 0.2, 120.0, 0.25)
        mix(y, b, N(t0), g)
    rum = vmul(lp1(lp1(white(n, r), 90.0), 140.0), env_ar(n, 0.05, 0.9))
    y = [a + 9.0 * b for a, b in zip(y, rum)]
    y = sat(y, 2.2)
    w = reverb(y, 0.84, 0.3)
    return trim_silence([a + 0.45 * b for a, b in zip(y, w)], -60)


RING_STEPS = [(74, 81), (76, 83), (78, 85), (81, 88), (83, 90)]  # D major pentatonic, a fifth apart


def sfx_ring(step=0):
    r = rng_for('ring%d' % step)
    m1, m2 = RING_STEPS[step]
    n = N(0.75)
    y = zeros(n)
    mix(y, bell(m1, 0.7, 0.7, 2.0, 1.4, 0.22), 0)
    mix(y, bell(m2, 0.7, 0.8, 2.0, 1.2, 0.3), N(0.065))
    mix(y, glock(m2 + 12, 0.6, 0.35), N(0.065))
    for k in range(6):
        m = m2 + 12 + r.choice([0, 2, 4, 7, 9, 12])
        mix(y, ping(hz(m), 0.2, 0.035, 0.25), N(0.07 + k * 0.03 + r.uniform(0, 0.015)))
    sh = vmul(biquad(white(n, r), 'hp', 8000.0, 0.7), env_ar(n, 0.02, 0.08))
    y = [a + 0.08 * b for a, b in zip(y, sh)]
    w = reverb(y, 0.7, 0.3)
    return fade_edges([a + 0.25 * b for a, b in zip(y, w)], 0.0005, 0.05)


def sfx_ring_silver():
    r = rng_for('ring_silver')
    n = N(1.8)
    y = zeros(n)
    arp = [74, 78, 81, 86, 90, 93, 98]
    for i, m in enumerate(arp):
        mix(y, bell(m, 1.1, 0.6, 2.0, 1.3, 0.45), N(i * 0.04))
        mix(y, glock(m, 1.0, 0.25), N(i * 0.04))
    ch = zeros(n)
    for m in (74, 78, 81, 86):
        ch = list(map(add, ch, sine(hz(m) * 2, n, r.random())))
    trem = [0.6 + 0.4 * math.sin(TAU * 11.0 * i / SR) for i in range(n)]
    ch = [a * t * e for a, t, e in zip(ch, trem, env_points(n, [(0, 0), (0.25, 0.25), (1.8, 0.0)]))]
    sp = zeros(n)
    for k in range(24):
        m = 96 + r.choice([0, 2, 4, 7, 9, 12])
        mix(sp, bell(m, 0.3, 0.3, 3.0, 0.5, 0.07), N(0.1 + r.uniform(0, 1.0)))
    y = [a + 0.12 * b + 0.5 * c for a, b, c in zip(y, ch, sp)]
    w = reverb(y, 0.8, 0.3)
    return fade_edges([a + 0.35 * b for a, b in zip(y, w)], 0.0005, 0.1)


def sfx_boost_start():
    r = rng_for('boost_start')
    n = N(1.4)
    thump = vmul(sine(sweep_exp(n, 75.0, 40.0, 0.06), n), env_ar(n, 0.002, 0.15))
    cr = zeros(n)
    t = 0.0
    while t < 0.25:
        t += r.expovariate(600.0)
        k = r.randrange(20, 80)
        mix(cr, [r.uniform(-1, 1) * (1 - j / k) for j in range(k)], N(t), r.uniform(0.3, 1.0) * (1 - t / 0.25))
    cr = hp1(cr, 1200.0)
    fw = svf(white(n, r), sweep_exp(n, 200.0, 3000.0, None), 0.9, 'lp')
    fw = vmul(fw, env_points(n, [(0, 0), (0.05, 1.0), (0.4, 0.7), (1.4, 0.0)]))
    wh = svf(white(n, r), sweep_exp(n, 400.0, 2600.0, None), 2.5, 'bp')
    wh = vmul(wh, env_points(n, [(0, 0), (0.25, 1.0), (0.7, 0.4), (1.4, 0)]))
    roar = vmul(lp1(lp1(white(n, r), 200.0), 300.0), env_points(n, [(0, 0), (0.08, 1.0), (1.4, 0.0)]))
    fl = [1.0 + 0.25 * math.sin(TAU * 31.0 * i / SR) for i in range(n)]
    y = [1.0 * a + 0.6 * b + 0.7 * c * f + 0.6 * d + 4.0 * e * f for a, b, c, d, e, f in zip(thump, cr, fw, wh, roar, fl)]
    return fade_edges(sat(y, 1.6), 0.0005, 0.1)


def sfx_roll():
    r = rng_for('roll')
    n = N(0.6)
    t = [i / n for i in range(n)]
    fc = [600.0 + 1700.0 * math.sin(math.pi * u) ** 1.5 for u in t]
    y = svf(white(n, r), fc, 2.2, 'bp')
    e = [math.sin(math.pi * u) ** 2 for u in t]
    fl = [0.8 + 0.2 * math.sin(TAU * 18.0 * i / SR) for i in range(n)]
    y2 = svf(white(n, r), [f * 2.2 for f in fc], 4.0, 'bp')
    return [(a + 0.4 * b) * c * d for a, b, c, d in zip(y, y2, e, fl)]


def beep(f, dur, kind='square', cut=5000.0, vel=1.0):
    n = N(dur)
    y = osc(bltab(kind, f), f, n)
    y = lp1(y, cut)
    e = env_points(n, [(0, 0), (0.003, 1.0), (dur - 0.008, 0.8), (dur, 0.0)])
    return scale(vmul(y, e), vel)


def sfx_lock():
    n = N(0.2)
    y = zeros(n)
    mix(y, beep(1760.0, 0.045, 'square', 6000.0), 0)
    mix(y, beep(2349.3, 0.06, 'square', 6000.0), N(0.055))
    return y


def sfx_lock_full():
    n = N(0.6)
    y = zeros(n)
    for i, m in enumerate((81, 86, 90)):
        mix(y, beep(hz(m), 0.05, 'square', 7000.0), N(i * 0.055))
    mix(y, beep(hz(93), 0.3, 'pulse25', 7000.0, 0.8), N(0.165))
    w = reverb(y, 0.6, 0.4)
    return [a + 0.2 * b for a, b in zip(y, w)]


def sfx_warning():
    n = N(1.5)
    y = zeros(n)
    for k, (f1, f2) in enumerate(((587.3, 622.3), (440.0, 466.2))):
        m = N(0.6)
        a = osc(bltab('saw', f2), [f1 * (1 + 0.004 * math.sin(TAU * 7 * i / SR)) for i in range(m)], m)
        b = osc(bltab('square', f2), f2, m, 0.3)
        s_ = [0.6 * p + 0.4 * q for p, q in zip(a, b)]
        e = env_points(m, [(0, 0), (0.015, 1.0), (0.5, 0.9), (0.6, 0.0)])
        mix(y, vmul(s_, e), N(k * 0.7))
    y = sat(y, 2.5)
    y = biquad(biquad(y, 'hp', 350.0, 0.7), 'lp', 3200.0, 0.9)
    y = biquad(y, 'peak', 1400.0, 1.0, 5.0)
    w = reverb(y, 0.6, 0.4)
    return [a + 0.2 * b for a, b in zip(y, w)]


def sfx_damage():
    r = rng_for('damage')
    n = N(0.8)
    th = vmul(sine(sweep_exp(n, 150.0, 48.0, 0.04), n), env_ar(n, 0.001, 0.13))
    cr = vmul(sat(biquad(white(n, r), 'bp', 900.0, 0.8), 3.0), env_ar(n, 0.001, 0.09))
    cr = bitcrush(cr, 5, 6)
    st = biquad(biquad(white(n, r), 'hp', 1800.0, 0.7), 'lp', 7000.0, 0.7)
    gate = []
    g = 1.0
    for i in range(n):
        if i % 441 == 0:
            g = 1.0 if r.random() > 0.35 else 0.15
        gate.append(g)
    st = bitcrush([a * b for a, b in zip(st, gate)], 6, 3)
    st = vmul(st, env_points(n, [(0, 0), (0.03, 0.6), (0.25, 0.35), (0.8, 0.0)]))
    ping = vmul(sine(3150.0, n), env_exp(n, 0.04))
    y = [1.0 * a + 0.7 * b + 0.35 * c + 0.2 * d for a, b, c, d in zip(th, cr, st, ping)]
    return fade_edges(sat(y, 1.5), 0.0005, 0.05)


def sfx_overheat():
    r = rng_for('overheat')
    n = N(1.8)
    hs = biquad(biquad(white(n, r), 'hp', 3000.0, 0.7), 'peak', 6500.0, 1.0, 6.0)
    fl = [0.8 + 0.2 * math.sin(TAU * 23.0 * i / SR) for i in range(n)]
    hs = [a * b * e for a, b, e in zip(hs, fl, env_points(n, [(0, 0), (0.02, 1.0), (0.3, 0.6), (1.8, 0.0)]))]
    al = zeros(n)
    for k in range(3):
        mix(al, beep(1174.7, 0.08, 'square', 5000.0), N(0.04 + k * 0.13))
    pd_n = N(0.9)
    pdf = sweep_exp(pd_n, 900.0, 160.0, None)
    pdw = vmul(lp1(osc(bltab('saw', 900.0), pdf, pd_n), 3000.0), env_points(pd_n, [(0, 0.0), (0.05, 1.0), (0.9, 0.0)]))
    mix(al, pdw, N(0.45), 0.6)
    return [0.45 * a + 0.5 * b for a, b in zip(hs, al)]


def sfx_ui_move():
    n = N(0.07)
    y = sine(1480.0, n)
    y2 = sine(2960.0, n, 0.2)
    e = env_ar(n, 0.001, 0.012)
    return fade_edges([(a + 0.3 * b) * c for a, b, c in zip(y, y2, e)], 0.0005, 0.01)


def sfx_ui_select():
    n = N(0.45)
    y = zeros(n)
    mix(y, bell(81, 0.4, 0.6, 2.0, 1.0, 0.12), 0)
    mix(y, bell(88, 0.45, 0.7, 2.0, 1.0, 0.16), N(0.06))
    mix(y, glock(93, 0.4, 0.2), N(0.06))
    w = reverb(y, 0.6, 0.3)
    return fade_edges([a + 0.2 * b for a, b in zip(y, w)], 0.0005, 0.05)


def sfx_ui_back():
    n = N(0.35)
    y = zeros(n)
    mix(y, bell(86, 0.3, 0.5, 2.0, 0.8, 0.1), 0)
    mix(y, bell(79, 0.3, 0.55, 2.0, 0.8, 0.12), N(0.06))
    return fade_edges(y, 0.0005, 0.05)


def sfx_pause():
    r = rng_for('pause')
    n = N(0.5)
    wh = vmul(svf(white(n, r), sweep_exp(n, 3000.0, 300.0, None), 2.0, 'bp'), env_points(n, [(0, 0), (0.03, 1), (0.35, 0.0), (0.5, 0)]))
    y = zeros(n)
    mix(y, bell(74, 0.45, 0.5, 2.0, 0.8, 0.15), N(0.02))
    mix(y, bell(69, 0.45, 0.5, 2.0, 0.8, 0.15), N(0.08))
    return fade_edges([0.4 * a + b for a, b in zip(wh, y)], 0.001, 0.05)


def sfx_countdown():
    n = N(0.4)
    y = zeros(n)
    b = beep(880.0, 0.14, 'pulse25', 5000.0)
    mix(y, b, 0)
    mix(y, vmul(sine(1760.0, n), env_exp(n, 0.05)), 0, 0.3)
    mix(y, tom(45, 0.6), 0, 0.5)
    w = reverb(y, 0.6, 0.3)
    return fade_edges([a + 0.2 * c for a, c in zip(y, w)], 0.0005, 0.05)


def sfx_go():
    r = rng_for('go')
    n = N(1.6)
    y = zeros(n)
    mix(y, beep(1760.0, 0.35, 'pulse25', 7000.0, 0.8), 0)
    for m in (62, 66, 69, 74, 78):
        mix(y, brass(m, 0.45, 1.0, 1.4, 0.0, 3, 10.0, 0.004, 0.35, 25.0), 0, 0.3)
    mix(y, fmbrass(86, 0.5, 1.0, 0.8), 0, 0.3)
    mix(y, timpani(38, 1.0, 1.5), 0, 0.6)
    mix(y, kick(1.0), 0, 0.5)
    mix(y, crash(0.8, 1.6), 0, 0.22)
    hit = vmul(biquad(white(n, r), 'bp', 1200.0, 0.6), env_exp(n, 0.04))
    mix(y, hit, 0, 0.25)
    w = reverb(y, 0.8, 0.3)
    return fade_edges([a + 0.3 * b for a, b in zip(y, w)], 0.0005, 0.1)


def sfx_portal():
    r = rng_for('portal')
    n = N(4.5)
    t = [i / SR for i in range(n)]
    base = [55.0 * 4.0 ** min(1.0, (u / 3.6)) ** 1.6 for u in t]
    y = zeros(n)
    for mult, d in ((1.0, -8), (1.0, 7), (1.5, -3), (2.0, 4), (0.5, 0)):
        tab = bltab('saw', 232.0 * mult)
        y = list(map(add, y, osc(tab, [b * mult * _cents(d) for b in base], n, r.random())))
    ph = list(accumulate([(0.7 + 7.0 * min(1.0, u / 3.6) ** 2) / SR for u in t]))
    swirl = [900.0 + 2400.0 * (0.5 + 0.5 * math.sin(TAU * p)) * (0.4 + 0.6 * min(1.0, u / 3.6)) for p, u in zip(ph, t)]
    y = svf(y, swirl, 3.0, 'lp')
    trem = [0.75 + 0.25 * math.sin(TAU * p * 2.0) for p in ph]
    wh = svf(white(n, r), [s_ * 1.5 for s_ in swirl], 4.0, 'bp')
    env = env_points(n, [(0, 0), (0.6, 0.5), (3.5, 1.0), (3.75, 0.6), (4.5, 0.0)])
    y = [(0.18 * a * tr + 0.25 * w) * e for a, w, tr, e in zip(y, wh, trem, env)]
    sp = zeros(n)
    for k in range(60):
        u = 3.6 * (k / 60.0) ** 0.7
        m = 86 + r.choice([0, 2, 4, 7, 9, 12, 14])
        mix(sp, bell(m, 0.5, 0.3, 3.5, 0.8, 0.12), N(u + r.uniform(0, 0.05)), 0.4 * (0.3 + u / 3.6))
    wm = vmul(sine(sweep_exp(N(1.0), 90.0, 30.0, 0.15), N(1.0)), env_ar(N(1.0), 0.003, 0.3))
    mix(sp, wm, N(3.6), 1.0)
    mix(sp, reverse_swell(0.5, 0.6), N(3.1))
    y = [a + b for a, b in zip(y, sp)]
    w = reverb(y, 0.85, 0.3)
    return fade_edges([a + 0.5 * b for a, b in zip(y, w)], 0.005, 0.2)


def sfx_checkpoint():
    """Da-da-da-DAAA brass sting in D with timpani and cymbal."""
    s = Song(150, 2, tail=2.5, transpose=2, seed='checkpoint', loop=False)
    T = s.tr
    mel = seq('G4:.333 G4:.333 G4:.334 C5:2.5 r:.5 | r:4')
    for (t, d, m) in mel:
        s.put(fmbrass(m + T, d * s.spb * 0.95, 0.95, 1.4), t, 0.5, rev=0.3)
        s.put(brass(m + T, d * s.spb * 0.95, 0.9, 1.1, 1.0, 3), t, 0.35, rev=0.3)
    for m in voicing('C', 64 + T, 3):
        s.put(brass(m, 2.5 * s.spb, 0.85, 0.9, 0.8, 2), 1.0, 0.28, rev=0.35)
    for m in voicing('C', 55 + T, 3):
        s.put(strings(m, 2.5 * s.spb, 0.7, 0.03, 0.6), 1.0, 0.25, rev=0.4)
    s.put(timpani(38 + T - 2, 1.0, 2.0), 1.0, 0.6, rev=0.3)
    s.put(crash(0.9, 2.4), 1.0, 0.4, rev=0.3)
    for i, m in enumerate(chord_tones('C', 84 + T, 100 + T)):
        s.put(glock(m, 1.2, 0.5), 1.0 + i * 0.1, 0.16, rev=0.4)
    return s.master(-1.0, comp=False)


def sfx_comm():
    r = rng_for('comm')
    n = N(0.45)
    st = vmul(biquad(biquad(white(n, r), 'bp', 2400.0, 0.9), 'hp', 900.0, 0.7), env_points(n, [(0, 0), (0.005, 1), (0.07, 0.6), (0.09, 0.0), (0.45, 0.0)]))
    y = zeros(n)
    mix(y, beep(1200.0, 0.05, 'square', 3500.0), N(0.1))
    mix(y, beep(1600.0, 0.07, 'square', 3500.0), N(0.16))
    sq = vmul(biquad(white(n, r), 'bp', 3000.0, 1.5), env_points(n, [(0, 0), (0.25, 0), (0.27, 0.4), (0.4, 0.0), (0.45, 0)]))
    y = [0.6 * a + b + 0.3 * c for a, b, c in zip(st, y, sq)]
    return bitcrush(biquad(y, 'bp', 1800.0, 0.5), 8, 2)


def sfx_enemy_fire():
    r = rng_for('enemy_fire')
    n = N(0.25)
    y = zeros(n)
    for k in range(2):
        m = N(0.12)
        fr = sweep_exp(m, 700.0, 240.0, 0.05)
        a = osc(bltab('saw', 700.0), fr, m)
        a = vmul(a, env_ar(m, 0.001, 0.04))
        mix(y, a, N(k * 0.07), 0.7)
    nz = vmul(biquad(white(n, r), 'bp', 1500.0, 1.0), env_exp(n, 0.03))
    y = [a + 0.4 * b for a, b in zip(y, nz)]
    return fade_edges(sat(biquad(y, 'lp', 4000.0), 1.8), 0.0005, 0.02)


def sfx_flyby():
    r = rng_for('flyby')
    n = N(1.6)
    t = [(i / n) * 1.6 - 0.8 for i in range(n)]
    dop = [1.0 - 0.14 * math.tanh(u * 4.0) for u in t]
    fr = [95.0 * d for d in dop]
    buzz = osc(bltab('saw', 110.0), fr, n)
    pr = list(accumulate([45.0 * d / SR for d in dop]))
    am = [0.7 + 0.3 * math.sin(TAU * p) for p in pr]
    dist = [1.0 / (1.0 + (u * 5.0) ** 2) for u in t]
    cut = [500.0 + 3500.0 * d for d in dist]
    y = svf([b * a for b, a in zip(buzz, am)], cut, 1.0, 'lp')
    wh = svf(white(n, r), [1000.0 + 2000.0 * d for d in dist], 1.5, 'bp')
    y = [(a + 0.5 * w) * d for a, w, d in zip(y, wh, dist)]
    return fade_edges(y, 0.02, 0.1)


def sfx_splash():
    r = rng_for('splash')
    n = N(0.7)
    y = vmul(biquad(white(n, r), 'bp', 2200.0, 0.7), env_points(n, [(0, 0), (0.01, 1.0), (0.12, 0.5), (0.7, 0.0)]))
    bub = zeros(n)
    for k in range(14):
        m = N(0.04)
        f0 = r.uniform(500, 1400)
        b = vmul(sine(sweep_exp(m, f0, f0 * 1.8, None), m), env_ar(m, 0.002, 0.012))
        mix(bub, b, N(0.03 + r.uniform(0, 0.4)), r.uniform(0.2, 0.5))
    return fade_edges([0.6 * a + b for a, b in zip(y, bub)], 0.0005, 0.05)


def sfx_score_tick():
    n = N(0.04)
    y = vmul(sine(3520.0, n), env_ar(n, 0.0005, 0.008))
    return fade_edges(y, 0.0002, 0.005)


def sfx_rank():
    r = rng_for('rank')
    n = N(1.6)
    y = zeros(n)
    mix(y, kick(1.0, 1.3), 0, 0.8)
    mix(y, timpani(38, 1.0, 1.5), 0, 0.6)
    for m in (62, 69, 74, 78):
        mix(y, brass(m, 0.25, 1.0, 1.4, 0.0, 2, 8.0, 0.003, 0.2, 25.0), 0, 0.3)
    hit = vmul(biquad(white(n, r), 'bp', 900.0, 0.5), env_exp(n, 0.035))
    mix(y, hit, 0, 0.3)
    for i, m in enumerate((86, 90, 93, 98)):
        mix(y, glock(m, 1.2, 0.5), N(0.12 + i * 0.05))
    w = reverb(y, 0.8, 0.3)
    return fade_edges([a + 0.3 * b for a, b in zip(y, w)], 0.0005, 0.1)


def sfx_horn():
    """Airship foghorn: two detuned reeds a minor third apart, swelling."""
    r = rng_for('horn')
    n = N(2.8)
    y = zeros(n)
    for f, g in ((73.4, 1.0), (87.3, 0.7), (146.8, 0.25)):
        fr = [f * (1.0 + 0.004 * math.sin(TAU * 4.3 * i / SR)) for i in range(n)]
        a = osc(bltab('reed', f * 1.03), fr, n, r.random())
        b = osc(bltab('reed', f * 1.03), [v * 1.006 for v in fr], n, r.random())
        y = [p + g * (q + w) for p, q, w in zip(y, a, b)]
    y = svf(y, env_points(n, [(0, 300.0), (0.35, 1500.0), (2.2, 1100.0), (2.8, 400.0)]), 1.1, 'lp')
    y = vmul(sat(y, 1.8), env_points(n, [(0, 0), (0.25, 1.0), (2.2, 0.9), (2.8, 0.0)]))
    w = reverb(y, 0.88, 0.4)
    return fade_edges([a + 0.6 * b for a, b in zip(y, w)], 0.005, 0.2)


def sfx_cannon():
    r = rng_for('cannon')
    n = N(1.2)
    y = boom(n, r, 140.0, 45.0, 0.18, 7000.0, 400.0, 0.06, 0.12, 400.0, 0.12)
    crack = vmul(hp1(white(n, r), 2500.0), env_exp(n, 0.006))
    y = sat([a + 0.8 * b for a, b in zip(y, crack)], 2.2)
    w = reverb(y, 0.75, 0.3)
    return trim_silence([a + 0.3 * b for a, b in zip(y, w)], -60)


def sfx_beep():
    """Mine proximity blip."""
    n = N(0.14)
    y = beep(1318.5, 0.07, 'tri', 6000.0)
    y2 = beep(2637.0, 0.07, 'tri', 8000.0, 0.3)
    return [a + b for a, b in zip(y + zeros(n - len(y)), y2 + zeros(n - len(y2)))]


def amb_comm_static():
    """3 s seamless radio bed under an open channel: voice-band hiss with fading,
    crackle, mains buzz and a faint heterodyne whistle. Every modulator has an
    integer number of cycles per loop."""
    L = N(3.0)
    r = rng_for('comm_static')
    pre = N(0.3)
    nz = [r.uniform(-1, 1) for _ in range(L)]
    band = periodic(lambda x: biquad(biquad(biquad(x, 'hp', 380.0, 0.7), 'lp', 3200.0, 0.8), 'peak', 1800.0, 1.2, 4.0), nz, pre)
    f1, f2, f3 = loop_noise_lfo(L, 7, 0.4), loop_noise_lfo(L, 17, 2.1), loop_noise_lfo(L, 2, 1.3)
    fade = [0.62 + 0.14 * a + 0.08 * b + 0.12 * c for a, b, c in zip(f1, f2, f3)]
    cr = [0.0] * L
    for _ in range(110):
        p = r.randrange(L)
        a = r.uniform(0.25, 1.0) * (1.0 if r.random() < 0.5 else -1.0)
        for j in range(r.randrange(10, 70)):
            cr[(p + j) % L] += a * r.uniform(-1.0, 1.0) * math.exp(-j / 14.0)
    cr = periodic(lambda x: biquad(x, 'bp', 2300.0, 0.9), cr, pre)
    # heterodyne whistle: 1100 Hz (3300 cycles per loop) wobbling +-35 Hz at 2 cycles per loop
    wob = loop_noise_lfo(L, 2, 0.0)
    ph = list(accumulate([(1100.0 + 35.0 * w) / SR for w in wob]))
    whistle = [math.sin(TAU * (p - ph[0])) for p in ph]
    buzz = [0.0] * L
    for k, a in ((1, 1.0), (2, 0.6), (3, 0.45), (5, 0.25)):
        buzz = list(map(add, buzz, scale(sine(100.0 * k, L, 0.2 * k), a)))
    buzz = periodic(lambda x: biquad(x, 'hp', 180.0, 0.7), buzz, pre)
    y = [0.8 * b * f + 0.55 * c + 0.022 * w * f + 0.035 * z for b, c, w, f, z in zip(band, cr, whistle, fade, buzz)]
    # a valve radio: soft saturation, then nothing above the voice band's upper harmonics
    return periodic(lambda x: biquad(biquad(sat(x, 1.4), 'lp', 5200.0, 0.6), 'lp', 5200.0, 0.6), y, N(0.1))


def sfx_comm_out():
    """Channel close: squelch tail and a low blip (the answer to comm's rising chirp)."""
    r = rng_for('comm_out')
    n = N(0.3)
    sq = vmul(biquad(biquad(white(n, r), 'bp', 2600.0, 0.7), 'hp', 700.0, 0.7),
              env_points(n, [(0, 0), (0.004, 1.0), (0.06, 0.55), (0.2, 0.08), (0.3, 0.0)]))
    y = zeros(n)
    mix(y, beep(1000.0, 0.045, 'square', 3200.0), N(0.035))
    mix(y, beep(760.0, 0.05, 'square', 2800.0, 0.8), N(0.085))
    tk = vmul(biquad(white(N(0.006), r), 'hp', 1500.0, 0.7), env_exp(N(0.006), 0.0015))
    mix(y, tk, 0, 1.2)
    y = [0.55 * a + b for a, b in zip(sq, y)]
    y = bitcrush(biquad(y, 'bp', 1700.0, 0.5), 8, 2)
    return biquad(biquad(y, 'lp', 5500.0, 0.6), 'lp', 5500.0, 0.6)


# ---- flight school ------------------------------------------------------------


def sfx_stamp():
    """Rubber stamp on a desk: felt-damped thunk, wood knock, the handle settling. The die
    snapping onto the page (click, 2-6 kHz) and the paper / ink slap (1-8 kHz) carry it
    on a phone speaker: the thunk alone sat 96 % below 300 Hz (QA wave 2)."""
    r = rng_for('stamp')
    n = N(0.45)
    thump = vmul(sine(sweep_exp(n, 190.0, 70.0, 0.018), n), env_ar(n, 0.0015, 0.05))
    knock = zeros(n)
    for f, a, d in ((236.0, 0.6, 0.04), (517.0, 1.0, 0.03), (1130.0, 0.8, 0.018)):
        knock = [p + a * q * e for p, q, e in zip(knock, sine(f, n, 0.1), env_exp(n, d))]
    felt = vmul(svf(white(n, r), 900.0, 0.8, 'lp'), env_ar(n, 0.001, 0.012))
    click = vmul(biquad(biquad(white(n, r), 'bp', 3600.0, 1.0), 'hp', 2000.0, 0.7), env_exp(n, 0.0018))
    slap = biquad(biquad(white(n, r), 'hp', 1000.0, 0.7), 'lp', 8000.0, 0.7)
    slap = lp1(vmul(slap, env_ar(n, 0.0006, 0.02)), 2500.0)  # tilted: most of it in 1-4 kHz
    y = [0.8 * a + 0.6 * b + 0.5 * c + 3.0 * d + 5.0 * e for a, b, c, d, e in zip(thump, knock, felt, click, slap)]
    mix(y, scale(knock, 0.29), N(0.034))
    y = sat(y, 1.8)
    w = reverb(y, 0.5, 0.5)
    return fade_edges([a + 0.12 * b for a, b in zip(y, w)], 0.0003, 0.03)


def sfx_ticket():
    """Paper slapped down: a flick of air, the crisp slap, a thud, the edge fluttering."""
    r = rng_for('ticket')
    n = N(0.3)
    y = zeros(n)
    k = N(0.022)
    fl = vmul(svf(white(k, r), sweep_exp(k, 3500.0, 7000.0, None), 1.4, 'bp'), [(i / k) ** 2 for i in range(k)])
    mix(y, fl, 0, 0.35)
    m = n - k
    sl = biquad(biquad(white(m, r), 'hp', 700.0, 0.7), 'peak', 3200.0, 0.9, 6.0)
    mix(y, vmul(sl, env_ar(m, 0.0004, 0.022)), k)
    mix(y, vmul(sine(sweep_exp(m, 170.0, 95.0, 0.01), m), env_ar(m, 0.001, 0.03)), k, 0.8)
    t = 0.012
    while t < 0.09:  # flutter: grains a little further apart, a little softer
        g = N(0.004)
        a = 0.35 * (1.0 - t / 0.09)
        mix(y, vmul(biquad(white(g, r), 'bp', 4200.0, 1.1), env_exp(g, 0.0012)), k + N(t), a)
        t += r.uniform(0.008, 0.016)
    y = sat(y, 2.4)
    w = reverb(y, 0.45, 0.5)
    return fade_edges([a + 0.1 * b for a, b in zip(y, w)], 0.0003, 0.03)


def sfx_pop():
    """Practice-target pop: a bright pitched pop, then a confetti sparkle and rustle."""
    r = rng_for('pop')
    n = N(0.8)
    y = zeros(n)
    mix(y, vmul(sine(sweep_exp(n, 1500.0, 420.0, 0.006), n), env_ar(n, 0.0005, 0.03)), 0)
    mix(y, vmul(sine(sweep_exp(n, 260.0, 150.0, 0.02), n), env_ar(n, 0.001, 0.035)), 0, 0.6)
    mix(y, vmul(hp1(white(n, r), 3000.0), env_exp(n, 0.0025)), 0, 0.4)
    y = sat(y, 1.8)
    pent = (86, 88, 90, 93, 95, 98, 100)  # D major pentatonic
    t = 0.03
    for i in range(7):
        mix(y, glock(r.choice(pent), 0.6, 0.5), N(t), 0.34 * (1.0 - i / 9.0))
        t += r.uniform(0.025, 0.05)
    rs = zeros(n)
    for _ in range(40):
        u = 0.02 + 0.4 * r.random() ** 1.6
        g = N(r.uniform(0.002, 0.005))
        mix(rs, vmul(white(g, r), env_exp(g, 0.001)), N(u), r.uniform(0.3, 1.0) * math.exp(-u / 0.15))
    mix(y, biquad(rs, 'hp', 5000.0, 0.7), 0, 0.35)
    w = reverb(y, 0.65, 0.35)
    return fade_edges([a + 0.2 * b for a, b in zip(y, w)], 0.0003, 0.05)


def sting_training_complete():
    """Flight school certificate: a rising brass line, IV-V-I, snare roll into timpani and cymbal.
    The tonic lands at 1.36 s, with the certificate's stamp."""
    s = Song(132, 1, tail=0.9, transpose=2, seed='sting_training_complete', loop=False)
    T = s.tr
    mel = seq('G4:.333 C5:.333 E5:.334 G5:1 A5:.5 B5:.5 C6:1')
    for (t, d, m) in mel:
        s.put(fmbrass(m + T, d * s.spb * 0.95, 0.95, 1.2), t, 0.45, rev=0.3)
        s.put(brass(m + T - 12, d * s.spb * 0.95, 0.85, 1.0, 0.8, 2), t, 0.3, rev=0.3)
    for (t, d, sym) in [(0, 2, 'C'), (2, 0.5, 'F'), (2.5, 0.5, 'G')]:
        for m in voicing(sym, 64 + T, 4):
            s.put(strings(m, d * s.spb, 0.7, 0.05, 0.3), t, 0.28, rev=0.4)
            s.put(brass(m - 12, d * s.spb, 0.7, 0.6, 0.3, 2), t, 0.16, rev=0.4)
    for m in voicing('C', 60 + T, 4):
        s.put(brass(m, 1.5 * s.spb, 0.95, 1.2, 0.8, 3), 3.0, 0.26, rev=0.4)
    for m in voicing('C', 55 + T, 3):
        s.put(strings(m, 1.5 * s.spb, 0.7, 0.03, 0.6), 3.0, 0.22, rev=0.4)
    s.put(fmbrass(84 + T, 1.5 * s.spb, 0.95, 1.4), 3.0, 0.22, rev=0.4)
    t = 1.0
    while t < 3.0:
        s.put(snare(vq(0.35 + 0.3 * (t - 1.0)), 200.0, 0.8, 0.09), t, 0.3, rev=0.2)
        t += 0.125
    s.put(timpani(36 + T, 1.0, 2.0), 3.0, 0.7, rev=0.4)
    s.put(timpani(43 + T, 0.6, 1.0), 0.0, 0.35, rev=0.4)
    s.put(crash(1.0, 2.2), 3.0, 0.45, rev=0.4)
    s.put(kick(1.0), 3.0, 0.55)
    for i, m in enumerate(chord_tones('C', 84 + T, 100 + T)):
        s.put(glock(m, 1.2, 0.5), 3.0 + i * 0.1, 0.16, rev=0.4)
    y = s.master(-1.0, comp=False)[:N(2.4)]
    return vmul(y, env_points(len(y), [(0, 1.0), (1.9, 1.0), (2.4, 0.0)]))


# ---- set-piece stings (DIRECTION #21) -----------------------------------------
# Core plays 'sting_' .. kind through sfx.stinger when a sting card fires (else
# 'sting'). The card starts with the sound, so each hit sits on the card's own
# slam (card frame / 60 s, from tools/gen_screens/s_sting.py; the MP3 lead adds
# 25 ms). All in D: they land on any of the four loops (sfx.as ducks the music
# to 0.35, 0.25 under the boss posters). Songs run at 60 bpm: a beat is a second.


def _sting_song(name, tail=1.6):
    s = Song(60, 1, 2, tail=tail, seed=name, loop=False)
    s.room = 0.8
    return s


def _sting_end(s, keep, fade, eq=()):
    """Master, cut to `keep` seconds with a linear fade over the last `fade`."""
    y = s.master(-1.0, comp=False, eq=eq)[:N(keep)]
    return vmul(y, env_points(len(y), [(0, 1.0), (keep - fade, 1.0), (keep, 0.0)]))


def air(dur, f, pts, q=1.5, seed='air'):
    """Air rush: band-passed noise; f is (f0, f1) for an exponential sweep, or [(t, hz), ...]."""
    n = N(dur)
    r = rng_for(seed)
    fc = sweep_exp(n, f[0], f[1], None) if isinstance(f, tuple) else env_points(n, f)
    return vmul(svf(white(n, r), fc, q, 'bp'), env_points(n, pts))


@cached
def slam(size=1.0, seed=0):
    """Print slam (a slab or a big rubber stamp landing on the page): felt thunk,
    wood knock, paper smack and crack. The stamp cue, scaled up."""
    r = random.Random(seed * 97 + 11)
    n = N(0.4 + 0.3 * size)
    thump = vmul(sine(sweep_exp(n, 175.0, 48.0, 0.02 * size), n), env_ar(n, 0.0015, 0.07 * size))
    knock = zeros(n)
    for f, a, d in ((196.0, 1.0, 0.05), (431.0, 0.5, 0.03), (947.0, 0.25, 0.015)):
        knock = [p + a * q * e for p, q, e in zip(knock, sine(f, n, 0.1), env_exp(n, d * size))]
    felt = vmul(svf(white(n, r), 700.0, 0.8, 'lp'), env_ar(n, 0.001, 0.02 * size))
    smack = vmul(biquad(white(n, r), 'bp', 2200.0, 0.8), env_exp(n, 0.006))
    crack = vmul(hp1(white(n, r), 4000.0), env_exp(n, 0.0025))
    y = [a + 0.4 * b + 0.8 * c + 0.45 * d + 0.3 * e for a, b, c, d, e in zip(thump, knock, felt, smack, crack)]
    return fade_edges(sat(y, 2.0), 0.0, 0.03)


@cached
def rattle(dur=0.14, seed=0):
    """The frame shaking after a slam: a burst of tiny paper/board knocks, dying off."""
    r = random.Random(seed * 13 + 5)
    n = N(dur)
    y = zeros(n)
    t = 0.0
    while t < dur - 0.01:
        g = N(0.003)
        k = vmul(biquad(white(g, r), 'bp', r.uniform(1400.0, 2600.0), 1.2), env_exp(g, 0.001))
        mix(y, k, N(t), r.uniform(0.4, 1.0) * (1.0 - t / dur))
        t += r.uniform(0.012, 0.024)
    return y


@cached
def clack(f=2600.0, seed=0):
    """Shutter / gear clack: two metal clicks 22 ms apart over a small body knock."""
    r = random.Random(seed * 7 + 3)
    n = N(0.08)
    y = zeros(n)
    for t, g in ((0.0, 1.0), (0.022, 0.7)):
        c = vmul(biquad(white(N(0.006), r), 'bp', f, 2.5), env_exp(N(0.006), 0.0012))
        mix(y, c, N(t), g)
    body = vmul(sine(f * 0.12, n), env_ar(n, 0.0005, 0.01))
    return [a + 0.5 * b for a, b in zip(y, body)]


def roller(dur, seed='roller'):
    """The ink roller rolling the page off: a low rolling rumble with tacky ink crackle."""
    n = N(dur)
    r = rng_for(seed)
    rum = svf(white(n, r), 240.0, 1.4, 'bp')
    ph = TAU * 19.0 / SR
    y = [v * (0.55 + 0.45 * math.sin(ph * i) ** 2) for i, v in enumerate(rum)]
    tack = zeros(n)
    t = 0.0
    while t < dur:
        g = N(0.002)
        mix(tack, vmul(white(g, r), env_exp(g, 0.0006)), N(t), r.uniform(0.2, 0.7))
        t += r.expovariate(90.0)
    tack = biquad(tack, 'hp', 2500.0, 0.7)
    return [a + 0.25 * b for a, b in zip(y, tack)]


# the boss posters cover the level / violet loops, brighter than a low brass section
BOSS_EQ = (('lowshelf', 90.0, 0.7, -3.0), ('highshelf', 2000.0, 0.7, 4.0))


def sting_boss_stormcrow():
    """STORMCROW poster: the slab rushes in from the right and slams (card f10), the
    villain's semitone motif in brass octaves over a 16th D ostinato (Eb-D as the tape
    slaps on, the tritone Ab, A), and a last hit as the slab is yanked off (f100)."""
    s = _sting_song('sting_boss_stormcrow')
    q = 60.0 / 160.0  # music_boss pulse
    t0 = 0.16
    s.put(air(0.2, (450.0, 3400.0), [(0, 0), (0.15, 1.0), (0.2, 0.0)], 1.8, 'crow_in'), t0 - 0.16, 0.65, rev=0.15)
    s.put(reverse_swell(0.16, 0.8), t0 - 0.16, 0.45, rev=0.1)
    # the slam: D minor across the brass (low section dark, the top bright), timpani,
    # anvil, snare crack, a print slam
    for m in (38, 45, 50, 53):
        s.put(brass(m, 0.42, 1.0, 1.4, 0.0, 3, 10.0, 0.004, 0.25, 30.0, 0.85, 1.2), t0, 0.17, rev=0.3)
    for m in (62, 65, 69):
        s.put(brass(m, 0.36, 1.0, 1.7, 0.0, 3, 10.0, 0.003, 0.22, 30.0), t0, 0.17, rev=0.3)
    s.put(fmbrass(74, 0.34, 1.0, 0.5), t0, 0.2, rev=0.3)
    s.put(timpani(38, 1.0, 2.0), t0, 0.6, rev=0.3)
    s.put(kick(1.0, 1.2), t0, 0.5)
    s.put(snare(1.0, 180.0, 1.3, 0.12), t0, 0.35, rev=0.25)
    s.put(clang(1.0), t0, 0.32, rev=0.4)
    s.put(crash(1.0, 2.0), t0, 0.4, rev=0.3)
    s.put(slam(1.0), t0, 0.45, rev=0.2)
    # the motif in octaves (beats after the slam, in q): Eb-D as the tape slaps on,
    # the tritone Ab on an anvil, A into the yank
    for b, d, m in ((1.0, 0.5, 51), (1.5, 0.5, 50), (2.0, 1.0, 56), (3.0, 1.0, 57)):
        for o, g, br in ((12, 0.26, 1.5), (0, 0.36, 1.1), (-12, 0.22, 1.0)):
            s.put(brass(m + o, d * q * 0.9, 0.95, br, 0.3, 3, 10.0, 0.01, 0.12, 25.0, 0.85, 1.2), t0 + b * q, g, rev=0.25)
    s.put(sfx_ticket(), t0 + q, 0.35, rev=0.1)                   # tape / spec tab slap
    s.put(clang(0.8), t0 + 2 * q, 0.22, rev=0.4)
    # 16th ostinato under the motif (music_boss's pattern)
    pat = [0, 0, 12, 0]
    for k in range(12):
        v = 0.95 if k % 4 == 0 else 0.7
        s.put(sawbass(38 + pat[k % 4], 0.25 * q * 0.8, vq(v), 700.0, 2600.0, 2.4), t0 + q + k * 0.25 * q, 0.24, rev=0.04)
    for m in (62, 65, 69):
        s.put(strings(m + 12, 3.0 * q, 0.6, 0.05, 0.2, 1.2, 0.85, 160.0), t0 + q, 0.14, rev=0.3)
    k = 0
    while t0 + 3 * q + k * 0.25 * q < t0 + 4 * q - 0.01:          # snare + timpani roll into the yank
        s.put(timpani(38, vq(0.35 + 0.15 * k), 0.8), t0 + 3 * q + k * 0.25 * q, 0.3, rev=0.3)
        s.put(snare(vq(0.3 + 0.15 * k), 180.0, 1.2, 0.08), t0 + 3 * q + k * 0.25 * q, 0.2, rev=0.2)
        k += 1
    # the yank: last D minor hit, and the slab rushes off
    t1 = t0 + 4 * q
    for m in (38, 45, 50, 53):
        s.put(brass(m, 0.55, 1.0, 1.3, 0.0, 3, 10.0, 0.004, 0.3, 30.0, 0.85, 1.2), t1, 0.17, rev=0.35)
    for m in (62, 65, 69, 74):
        s.put(brass(m, 0.5, 1.0, 1.7, 0.0, 3, 10.0, 0.003, 0.3, 30.0), t1, 0.15, rev=0.35)
    s.put(timpani(38, 1.0, 1.5), t1, 0.5, rev=0.35)
    s.put(clang(1.0), t1, 0.3, rev=0.45)
    s.put(kick(1.0, 1.1), t1, 0.4)
    s.put(snare(1.0, 180.0, 1.3, 0.12), t1, 0.3, rev=0.3)
    s.put(crash(0.9, 1.6), t1, 0.3, rev=0.35)
    s.put(air(0.32, (2600.0, 500.0), [(0, 0), (0.05, 1.0), (0.32, 0.0)], 1.6, 'crow_out'), t1, 0.35, rev=0.2)
    return _sting_end(s, 2.3, 0.3, BOSS_EQ)


def sting_boss_watcher():
    """THE WATCHER poster: the slab slams (f10) on a dark D minor(b9) stab, clockwork
    ticks at 160 bpm, the lids snap open (f18-21: shutter clacks, a servo whirr, the
    iris ringing in glass), a choir cluster swells under a falling theremin, the
    second blink (f70-75), and a last hit as the slab leaves (f100)."""
    s = _sting_song('sting_boss_watcher')
    s.room = 0.86
    q = 60.0 / 160.0
    t0 = 0.16
    s.put(reverse_swell(0.16, 0.9), t0 - 0.16, 0.5, rev=0.1)
    s.put(air(0.18, (600.0, 3000.0), [(0, 0), (0.14, 1.0), (0.18, 0.0)], 1.8, 'eye_in'), t0 - 0.16, 0.45, rev=0.15)
    for m in (38, 45, 50, 51, 53):
        s.put(brass(m, 0.4, 1.0, 1.2, 0.0, 3, 12.0, 0.004, 0.3, 30.0, 0.85, 1.4), t0, 0.16, rev=0.35)
    for m in (62, 63, 65, 69):
        s.put(brass(m, 0.34, 1.0, 1.7, 0.0, 3, 12.0, 0.003, 0.25, 30.0), t0, 0.14, rev=0.35)
    s.put(timpani(38, 1.0, 2.0), t0, 0.6, rev=0.35)
    s.put(kick(1.0, 1.2), t0, 0.5)
    s.put(snare(1.0, 180.0, 1.3, 0.12), t0, 0.3, rev=0.3)
    s.put(clang(1.0), t0, 0.35, rev=0.45)
    s.put(crash(0.9, 2.0), t0, 0.35, rev=0.4)
    s.put(slam(1.0, 1), t0, 0.4, rev=0.2)
    # clockwork: tick-tock 8ths, louder toward the exit
    k = 0
    while t0 + k * 0.5 * q < 1.9:
        t = t0 + k * 0.5 * q
        s.put(clack(2900.0 if k % 2 == 0 else 2100.0, k % 2), t + 0.5 * q, 0.2 + 0.2 * (t / 1.9), rev=0.25)
        k += 1
    # the lids snap open: clacks, servo whirr up, the iris rings
    to = 0.31
    s.put(clack(3400.0, 7), to, 0.55, rev=0.3)
    n = N(0.36)
    wh = osc(bltab('saw', 520.0), sweep_exp(n, 170.0, 520.0, None), n)
    gear = [0.8 + 0.2 * math.sin(TAU * 62.0 * i / SR) for i in range(n)]
    wh = vmul(vmul(lp1(wh, 2400.0), gear), env_points(n, [(0, 0), (0.04, 1.0), (0.28, 0.8), (0.36, 0.0)]))
    s.put(wh, to, 0.16, rev=0.3)
    for m, g in ((86, 0.3), (87, 0.22), (93, 0.18)):
        s.put(bell(m, 1.6, 0.6, 3.5, 1.4, 0.8), to + 0.03, g, rev=0.5, echo=0.2)
    for m in (62, 65, 68, 75):                                   # D F Ab Eb: the eye's cluster
        s.put(choir(m, 1.45, 0.55, 0.35, 0.5, 'ah'), to, 0.1, rev=0.5)
    t0_, th = theremin_line(s, [(to + 0.05, 0.5, 81), (to + 0.55, 0.45, 80), (to + 1.0, 0.45, 74)], 0, 0.09, 34.0, 6.6, 0.1)
    s.put(th, t0_, 0.24, rev=0.5, echo=0.15)
    # the second blink
    s.put(clack(3400.0, 8), 1.19, 0.4, rev=0.3)
    s.put(clack(3100.0, 9), 1.25, 0.3, rev=0.3)
    # the exit hit
    t1 = t0 + 4 * q
    for m in (38, 45, 50, 51):
        s.put(brass(m, 0.5, 1.0, 1.2, 0.0, 3, 12.0, 0.004, 0.3, 30.0, 0.85, 1.4), t1, 0.16, rev=0.4)
    for m in (62, 63, 65, 69):
        s.put(brass(m, 0.45, 1.0, 1.7, 0.0, 3, 12.0, 0.003, 0.3, 30.0), t1, 0.13, rev=0.4)
    s.put(timpani(38, 1.0, 1.5), t1, 0.5, rev=0.4)
    s.put(snare(1.0, 180.0, 1.3, 0.12), t1, 0.25, rev=0.3)
    s.put(clang(0.9), t1, 0.35, rev=0.45)
    s.put(air(0.32, (2400.0, 450.0), [(0, 0), (0.05, 1.0), (0.32, 0.0)], 1.6, 'eye_out'), t1, 0.3, rev=0.2)
    return _sting_end(s, 2.3, 0.3, BOSS_EQ)


# the kill's explode_big (1.0, sample peak at 0.14 s: right on the stamp) owns the
# low end: the DOWNED stings stay above it so the pair does not clip
DOWN_EQ = (('hp', 150.0, 0.7, 0.0), ('hp', 150.0, 0.7, 0.0))


def _sting_down(name, watcher):
    """DOWNED: the rubber stamp drops from above the lens and cracks down (f8) with a
    bright D major stab, the frame shakes, the name tape slaps on, then the hero
    theme's head in brass (D A D F#), landing on A as the stamp lifts off (f62-78)
    and ringing over the kill cam. The kill's explode_big carries the weight of the
    slam; the sting stays above 150 Hz and light while the blast peaks."""
    s = _sting_song(name)
    t0 = 0.135
    s.put(air(0.13, (900.0, 2600.0), [(0, 0), (0.1, 1.0), (0.13, 0.0)], 1.4, name + '_drop'), t0 - 0.13, 0.35, rev=0.1)
    for m in (57, 62, 66, 69):
        s.put(brass(m, 0.22, 1.0, 1.6, 0.0, 3, 10.0, 0.003, 0.15, 30.0), t0, 0.12, rev=0.35)
    s.put(fmbrass(74, 0.22, 1.0, 0.5), t0, 0.14, rev=0.3)
    s.put(slam(0.8, 2), t0, 0.3, rev=0.25)
    s.put(snare(1.0, 220.0, 1.3, 0.1), t0, 0.26, rev=0.3)
    s.put(crash(1.0, 2.2), t0, 0.24, rev=0.3)
    s.put(rattle(0.14, 3), t0 + 0.02, 0.4, rev=0.2)
    if watcher:
        # the lens shatters in glass
        for i, m in enumerate((93, 98, 99, 102, 105)):
            s.put(bell(m, 0.9, 0.5, 3.1 + 0.2 * i, 1.8, 0.3), t0 + 0.012 * i, 0.08, rev=0.5)
        s.put(vmul(hp1(white(N(0.5), rng_for(name)), 5000.0), env_ar(N(0.5), 0.001, 0.09)), t0, 0.15, rev=0.4)
    else:
        # her hull goes down: a trombone fall under the tape
        n = N(0.9)
        f = sweep_exp(n, hz(62), hz(50), None)
        fall = osc(bltab('saw', hz(62)), f, n, 0.3)
        fall = vmul(svf(fall, sweep_exp(n, 2400.0, 500.0, None), 0.9, 'lp'), env_points(n, [(0, 0), (0.08, 1.0), (0.6, 0.6), (0.9, 0.0)]))
        s.put(sat(fall, 1.6), t0 + 0.12, 0.16, rev=0.35)
    s.put(sfx_ticket(), 0.34, 0.4, rev=0.1)                           # the name tape
    # the hero theme's head: D5 . A4 D5 F#5 | A5
    b = 0.2
    t = 0.5
    for d, m in ((1.5, 74), (0.5, 69), (1.0, 74), (1.0, 78)):
        s.put(fmbrass(m, d * b * 0.92, 0.95, 1.2), t, 0.34, rev=0.3)
        s.put(brass(m - 12, d * b * 0.92, 0.9, 1.0, 0.6, 2), t, 0.24, rev=0.3)
        t += d * b
    k = 0
    while 0.5 + k * 0.05 < t - 0.01:                                  # snare roll into the arrival
        s.put(snare(vq(0.3 + 0.5 * k * 0.05 / (t - 0.5)), 200.0, 0.8, 0.08), 0.5 + k * 0.05, 0.22, rev=0.2)
        k += 1
    ta = t                                                            # ~1.3 s: A5 on the D chord
    s.put(fmbrass(81, 0.9, 0.95, 1.4), ta, 0.34, rev=0.4)
    for m in voicing('D', 66, 4):
        s.put(brass(m, 0.9, 0.9, 1.0, 0.8, 3), ta, 0.2, rev=0.4)
        s.put(strings(m, 0.9, 0.7, 0.03, 0.6), ta, 0.2, rev=0.4)
    s.put(timpani(50, 0.9, 1.5), ta, 0.4, rev=0.35)
    s.put(crash(0.9, 2.0), ta, 0.3, rev=0.4)
    for i, m in enumerate(chord_tones('D', 86, 98)):
        s.put(glock(m, 1.0, 0.5), ta + 0.06 * i, 0.14, rev=0.4)
    return _sting_end(s, 2.45, 0.45, DOWN_EQ)


def sting_down_stormcrow():
    return _sting_down('sting_down_stormcrow', False)


def sting_down_watcher():
    return _sting_down('sting_down_watcher', True)


def sting_chapter_violet():
    """CHAPTER 2 · VIOLET REACH: out of the portal white-out the page punches in (a sub
    boom, a paper slap, a D lydian bell cluster over choir and pad), the seal stamps
    (f26), the eight route ticks ping up the lydian scale (f36-57), and the ink roller
    rolls the page off (f100-130)."""
    s = _sting_song('sting_chapter_violet')
    s.room = 0.9
    s.echo_time = 0.375
    s.echo_fb = 0.4
    n = N(0.9)
    boom_ = vmul(sine(sweep_exp(n, 80.0, 36.0, 0.08), n), env_ar(n, 0.003, 0.3))
    s.put(boom_, 0.02, 0.55, rev=0.2)
    s.put(sfx_ticket(), 0.02, 0.35, rev=0.2)
    s.put(crash(0.7, 2.4), 0.02, 0.18, rev=0.5)
    for i, m in enumerate((74, 81, 85, 92)):                          # D5 A5 C#6 G#6
        s.put(bell(m, 2.2, 0.6, 2.0, 1.4, 0.9), 0.02 + 0.03 * i, 0.18, rev=0.55, echo=0.3)
    s.put(snare(0.9, 240.0, 1.0, 0.2), 0.02, 0.25, rev=0.4)
    for m in (62, 66, 69, 73, 80):                                    # Dmaj7#11
        s.put(choir(m, 1.7, 0.5, 0.3, 0.6, 'oo'), 0.02, 0.09, rev=0.55)
        s.put(pad(m + 12, 1.7, 0.7, 0.25, 0.8, 3200.0), 0.02, 0.16, rev=0.5, cho=0.6)
    s.put(square_pluck(38, 1.2, 0.9, 0.6, 3.0, 'tri'), 0.02, 0.5, rev=0.05)
    # the seal stamps
    s.put(slam(0.7, 4), 0.435, 0.4, rev=0.3)
    s.put(glock(86, 1.2, 0.5), 0.435, 0.12, rev=0.4, echo=0.3)
    # eight route ticks up D lydian (the sixth blinks)
    for k, m in enumerate((86, 88, 90, 92, 93, 95, 97, 98)):
        s.put(glock(m, 0.9, 0.55), 0.6 + 0.05 * k, 0.17, rev=0.4, echo=0.25)
        s.put(clack(3200.0, 20 + k), 0.6 + 0.05 * k, 0.12, rev=0.2)
    s.put(glock(95, 0.8, 0.4), 0.85 + 0.2, 0.08, rev=0.4, echo=0.3)
    # the roller
    rl = roller(0.55, 'violet_roller')
    s.put(vmul(rl, env_points(len(rl), [(0, 0), (0.12, 1.0), (0.4, 0.8), (0.55, 0.0)])), 1.66, 0.45, rev=0.2)
    s.put(air(0.5, (1800.0, 600.0), [(0, 0), (0.15, 1.0), (0.5, 0.0)], 1.2, 'violet_page'), 1.7, 0.2, rev=0.3)
    return _sting_end(s, 2.25, 0.4)


def sting_arch_threaded():
    """THREADED!: the rush through the arch, the word slams (f9) on a bright D6/9 brass
    stab with a glock sparkle, the tape slaps on, and a swish as the word flies at the
    lens (f46-60)."""
    s = _sting_song('sting_arch_threaded')
    s.put(air(0.2, [(0, 700.0), (0.1, 3000.0), (0.2, 900.0)], [(0, 0), (0.09, 1.0), (0.2, 0.0)], 2.0, 'arch_thru'), 0.0, 0.45, rev=0.15)
    t0 = 0.15
    for m in (62, 66, 69, 71, 76):
        s.put(brass(m, 0.28, 1.0, 1.6, 0.0, 3, 10.0, 0.003, 0.2, 30.0), t0, 0.2, rev=0.3)
    s.put(fmbrass(86, 0.3, 1.0, 0.6), t0, 0.22, rev=0.3)
    s.put(slam(0.8, 5), t0, 0.45, rev=0.2)
    s.put(kick(1.0, 1.1), t0, 0.4)
    s.put(crash(0.9, 1.4), t0, 0.28, rev=0.3)
    for i, m in enumerate((86, 90, 93, 98, 102)):
        s.put(glock(m, 0.9, 0.55), t0 + 0.04 + 0.045 * i, 0.15, rev=0.4)
    s.put(sfx_ticket(), 0.3, 0.3, rev=0.1)
    s.put(air(0.28, (1200.0, 7000.0), [(0, 0), (0.22, 1.0), (0.28, 0.0)], 1.8, 'arch_lens'), 0.74, 0.4, rev=0.25)
    s.put(bell(98, 0.6, 0.4, 3.5, 0.8, 0.2), 1.0, 0.1, rev=0.4)
    return _sting_end(s, 1.35, 0.25)


def sting_mission_complete():
    """MISSION COMPLETE: the emblem punches up and the slab lands (f8-12) on a full
    D major hit, the wings unfold in a harp run (f12-30), the feathers fan, a rising
    brass call lands on A as the glint crosses (f40-74), held until the slab leaves
    (f104). Stays clear of jingle_clear's call, which plays on the results."""
    s = _sting_song('sting_mission_complete')
    s.room = 0.86
    t0 = 0.16
    s.put(reverse_swell(0.16, 0.9), t0 - 0.16, 0.5, rev=0.1)
    for m in (50, 57, 62, 66, 69, 74):
        s.put(brass(m, 0.5, 1.0, 1.4, 0.0, 3, 10.0, 0.004, 0.3, 30.0), t0, 0.19, rev=0.4)
    s.put(fmbrass(78, 0.5, 1.0, 0.8), t0, 0.24, rev=0.35)
    s.put(timpani(38, 1.0, 2.0), t0, 0.55, rev=0.35)
    s.put(kick(1.0, 1.2), t0, 0.45)
    s.put(snare(1.0, 200.0, 1.2, 0.12), t0, 0.28, rev=0.3)
    s.put(crash(1.0, 2.6), t0, 0.45, rev=0.4)
    s.put(slam(0.9, 6), t0 + 0.04, 0.35, rev=0.25)
    # the wings unfold: harp run up D major pentatonic; the feathers fan
    run = (62, 64, 66, 69, 71, 74, 76, 78, 81, 83, 86)
    for i, m in enumerate(run):
        s.put(pluck(m, 1.1, 0.6, 0.55, 0.995), 0.2 + i * 0.028, 0.18, rev=0.4)
    for i in range(3):
        s.put(air(0.1, (1500.0, 4200.0), [(0, 0), (0.03, 1.0), (0.1, 0.0)], 2.0, 'feather%d' % i), 0.3 + i * 0.067, 0.14, rev=0.3)
    # the call: A4 D5 F#5 | A5 held on D6/9 (strings, brass), timpani and crash
    for i, m in enumerate((69, 74, 78)):
        s.put(fmbrass(m, 0.1, 0.95, 1.0), 0.62 + i * 0.11, 0.32, rev=0.3)
        s.put(brass(m - 12, 0.1, 0.9, 1.0, 0.4, 2), 0.62 + i * 0.11, 0.2, rev=0.3)
    ta = 0.95
    s.put(fmbrass(81, 1.0, 0.95, 1.4), ta, 0.34, rev=0.4)
    s.put(brass(69, 1.0, 0.9, 1.0, 1.0, 3), ta, 0.2, rev=0.4)
    for m in (62, 66, 69, 71, 76):
        s.put(strings(m, 1.1, 0.7, 0.04, 0.7), ta, 0.2, rev=0.45)
        s.put(brass(m - 12, 1.0, 0.85, 0.7, 0.4, 2), ta, 0.12, rev=0.4)
    s.put(timpani(38, 0.9, 1.6), ta, 0.45, rev=0.4)
    s.put(crash(0.8, 2.0), ta, 0.25, rev=0.45)
    # the glint: a fast bell shimmer across the slab
    for i, m in enumerate((86, 88, 90, 93, 95, 98, 100, 102, 105)):
        s.put(bell(m, 0.7, 0.4, 3.5, 0.8, 0.25), 0.7 + i * 0.055, 0.07 + 0.01 * i, rev=0.5, echo=0.2)
    s.put(air(0.55, (3000.0, 9000.0), [(0, 0), (0.3, 1.0), (0.55, 0.0)], 3.0, 'glint'), 0.68, 0.12, rev=0.4)
    s.put(air(0.3, (2400.0, 500.0), [(0, 0), (0.06, 1.0), (0.3, 0.0)], 1.6, 'mc_out'), 1.74, 0.25, rev=0.3)
    return _sting_end(s, 2.5, 0.5, (('highshelf', 2500.0, 0.7, 2.0),))


def sting_generic():
    """Fallback for a sting kind with no sound of its own: a rush, a print slam on a
    D major brass stab, the tape slap and a glock ping."""
    s = _sting_song('sting')
    t0 = 0.14
    s.put(air(0.15, (600.0, 3000.0), [(0, 0), (0.12, 1.0), (0.15, 0.0)], 1.6, 'sting_in'), t0 - 0.14, 0.55, rev=0.15)
    for m in (50, 57, 62, 66, 69, 74):
        s.put(brass(m, 0.35, 1.0, 1.6, 0.0, 3, 10.0, 0.003, 0.25, 30.0), t0, 0.18, rev=0.35)
    s.put(fmbrass(78, 0.34, 1.0, 0.5), t0, 0.2, rev=0.3)
    s.put(slam(1.0, 7), t0, 0.45, rev=0.2)
    s.put(timpani(38, 1.0, 1.6), t0, 0.45, rev=0.3)
    s.put(kick(1.0, 1.1), t0, 0.4)
    s.put(snare(1.0, 190.0, 1.3, 0.12), t0, 0.3, rev=0.3)
    s.put(crash(1.0, 1.8), t0, 0.4, rev=0.3)
    s.put(sfx_ticket(), 0.36, 0.3, rev=0.1)
    s.put(glock(86, 1.2, 0.55), t0 + 0.05, 0.14, rev=0.4)
    s.put(glock(93, 1.2, 0.5), t0 + 0.1, 0.12, rev=0.4)
    return _sting_end(s, 1.5, 0.35)


# ---- the Stormcrow's storm ------------------------------------------------------


def _grains(n, r, dur, rate, tau, kmin, kmax):
    """Crackle: sharp noise grains at `rate` per s for `dur` s, rate and level dying off with tau."""
    y = zeros(n)
    t = 0.0
    while t < dur:
        t += r.expovariate(rate * math.exp(-t / tau) + 8.0)
        k = r.randrange(kmin, kmax)
        a = r.uniform(0.25, 1.0) * math.exp(-t / tau)
        mix(y, [a * r.uniform(-1, 1) * (1 - j / k) for j in range(k)], N(t))
    return y


def sfx_thunder():
    """Her storm's strikes: a torn crack (snaps, a crackle rip, a "kr" in the mids;
    saturated, so it reads on a phone), a thump falling 90 -> 34 Hz under a low-mid
    burst, then the roll: gritty rumbles, full for 1.2 s, then softer, darker and
    further apart, over a grumbling low bed; two far rumbles carry it to 3 s."""
    r = rng_for('thunder')
    n = N(3.8)
    snap = vmul(biquad(white(n, r), 'hp', 1800.0, 0.7), env_ar(n, 0.0003, 0.012))
    rip = biquad(_grains(n, r, 0.25, 900.0, 0.07, 8, 40), 'hp', 700.0, 0.7)
    kr = vmul(biquad(white(n, r), 'bp', 900.0, 0.8), env_points(n, [(0, 0), (0.003, 1.0), (0.05, 0.55), (0.22, 0.0)]))
    crack = [0.9 * a + 0.9 * b + 0.8 * c for a, b, c in zip(snap, rip, kr)]
    crack = sat(scale(crack, 3.0 / peak(crack)), 1.0)
    m = N(2.2)
    thump = vmul(sine(sweep_exp(m, 90.0, 34.0, 0.2), m), env_ar(m, 0.008, 0.45)) + zeros(n - m)
    burst = vmul(biquad(lp1(white(n, r), 400.0), 'peak', 180.0, 0.8, 6.0),
                 env_points(n, [(0, 0), (0.02, 1.0), (0.12, 0.7), (0.7, 0.0)]))
    # rumbles: a noise burst each (230 -> 100 Hz, its own colour). Loud in the low mids,
    # with gaps between them, so the roll reads over the props and the music
    lvl = lambda t: 1.0 if t < 1.2 else math.exp(-(t - 1.2) / 0.6)
    rum = zeros(n)
    env = zeros(n)

    def rumble(t, a, rise, dec, fc):
        k = min(n - N(t), N(rise + 5 * dec))
        na = N(rise)
        e = [0.5 - 0.5 * math.cos(math.pi * u / na) for u in range(na)] + env_exp(k - na, dec)
        v = vmul(biquad(biquad(white(k, r), 'bp', fc, 0.9), 'lp', 2.2 * fc, 0.7), e)
        mix(rum, v, N(t), a / peak(v))
        mix(env, e, N(t), a)
    t = 0.14
    while t < 3.1:
        a, rise, dec = lvl(t) * r.uniform(0.6, 1.0), r.uniform(0.02, 0.05), r.uniform(0.07, 0.2)
        rumble(t, a, rise, dec, 230.0 * (100.0 / 230.0) ** min(1.0, t / 2.5) * r.uniform(0.8, 1.25))
        t += r.uniform(0.16, 0.3) * (1.0 + 0.35 * t)
    rumble(2.25, 0.12, 0.08, 0.25, 120.0)
    rumble(2.85, 0.09, 0.1, 0.3, 100.0)
    h = rum[N(0.14):N(1.3)]
    rum = biquad(sat(scale(rum, 0.35 / math.sqrt(sum(v * v for v in h) / len(h))), 1.0), 'lp', 1200.0, 0.7)
    # a grumbling low bed under them (14 Hz noise AM), following them loosely
    gr = lp1(lp1(white(n, r), 14.0), 14.0)
    g = 0.45 / peak(gr)
    low = svf(lp1(white(n, r), 160.0), [170.0 + 500.0 * math.exp(-i / SR) for i in range(n)], 0.9, 'lp')
    kl = 1.0 / peak(low)
    bed = [kl * a * (0.2 * lvl(i / SR) + 0.8 * min(1.0, e)) * (0.55 + g * v)
           for i, (a, e, v) in enumerate(zip(low, lp1(env, 6.0), gr))]
    body = [0.5 * a + 0.8 * b + c + 0.85 * d for a, b, c, d in zip(thump, burst, rum, bed)]
    body = biquad(sat(body, 1.4), 'lp', 2200.0, 0.7)
    bw = reverb(body, 0.86, 0.5)
    cw = reverb(crack, 0.78, 0.6)
    y = [0.7 * a + 0.4 * b + c + 0.2 * d for a, b, c, d in zip(crack, cw, body, bw)]
    return vmul(y, env_points(n, [(0, 1.0), (3.2, 1.0), (3.8, 0.0)]))


# -----------------------------------------------------------------------------
# Catalogue: name -> (kind, builder, peak dB). Order fixes RML ids 5:1.. (append only).
# -----------------------------------------------------------------------------

SOUNDS = [
    ('laser', 'sfx', lambda: sfx_laser(0), -4.0),
    ('laser2', 'sfx', lambda: sfx_laser(1), -4.0),
    ('laser3', 'sfx', lambda: sfx_laser(2), -4.0),
    ('charge', 'rise', lambda: charge_pair()[0], None),
    ('charge_hold', 'loop', lambda: charge_pair()[1], None),
    ('nova', 'sfx', sfx_nova, -1.0),
    ('hit', 'sfx', lambda: sfx_hit(0), -3.0),
    ('hit2', 'sfx', lambda: sfx_hit(1), -3.0),
    ('explode_small', 'sfx', lambda: sfx_explode_small(0), -1.5),
    ('explode_small2', 'sfx', lambda: sfx_explode_small(1), -1.5),
    ('explode_big', 'sfx', sfx_explode_big, -0.5),
    ('ring', 'sfx', lambda: sfx_ring(0), -3.0),
    ('ring2', 'sfx', lambda: sfx_ring(1), -3.0),
    ('ring3', 'sfx', lambda: sfx_ring(2), -3.0),
    ('ring4', 'sfx', lambda: sfx_ring(3), -3.0),
    ('ring5', 'sfx', lambda: sfx_ring(4), -3.0),
    ('ring_silver', 'sfx', sfx_ring_silver, -2.0),
    ('boost_start', 'sfx', sfx_boost_start, -2.0),
    ('roll', 'sfx', sfx_roll, -4.0),
    ('lock', 'sfx', sfx_lock, -8.0),
    ('lock_full', 'sfx', sfx_lock_full, -6.0),
    ('warning', 'sfx', sfx_warning, -3.0),
    ('damage', 'sfx', sfx_damage, -1.0),
    ('overheat', 'sfx', sfx_overheat, -2.0),
    ('ui_move', 'ui', sfx_ui_move, -10.0),
    ('ui_select', 'ui', sfx_ui_select, -5.0),
    ('ui_back', 'ui', sfx_ui_back, -7.0),
    ('pause', 'ui', sfx_pause, -6.0),
    ('countdown', 'ui', sfx_countdown, -3.0),
    ('go', 'sfx', sfx_go, -1.0),
    ('portal', 'sfx', sfx_portal, -1.5),
    ('checkpoint', 'sfx', sfx_checkpoint, -1.0),
    ('comm', 'ui', sfx_comm, -6.0),
    ('enemy_fire', 'sfx', sfx_enemy_fire, -5.0),
    ('flyby', 'sfx', sfx_flyby, -3.0),
    ('splash', 'sfx', sfx_splash, -5.0),
    ('score_tick', 'ui', sfx_score_tick, -12.0),
    ('rank', 'sfx', sfx_rank, -1.0),
    ('jingle_clear', 'music', jingle_clear, -1.0),
    ('jingle_over', 'music', jingle_over, -1.5),
    ('music_title', 'loop', music_title, -1.0),
    ('music_level', 'loop', music_level, -1.0),
    ('music_boss', 'loop', music_boss, -1.0),
    ('music_violet', 'loop', music_violet, -1.0),
    ('wind', 'loop', amb_wind, -3.0),
    ('jet', 'loop', lambda: amb_jet(False), -3.0),
    ('jet_boost', 'loop', lambda: amb_jet(True), -3.0),
    ('horn', 'sfx', sfx_horn, -1.5),
    ('cannon', 'sfx', sfx_cannon, -1.0),
    ('beep', 'sfx', sfx_beep, -8.0),
    ('comm_static', 'loop', amb_comm_static, -6.0),
    ('comm_out', 'ui', sfx_comm_out, -6.0),
    ('stamp', 'sfx', sfx_stamp, -2.0),
    ('ticket', 'sfx', sfx_ticket, -3.0),
    ('pop', 'sfx', sfx_pop, -2.0),
    ('sting_training_complete', 'sfx', sting_training_complete, -1.0),
    ('sting_boss_stormcrow', 'sfx', sting_boss_stormcrow, -1.0),
    ('sting_boss_watcher', 'sfx', sting_boss_watcher, -1.0),
    ('sting_down_stormcrow', 'sfx', sting_down_stormcrow, -1.0),
    ('sting_down_watcher', 'sfx', sting_down_watcher, -1.0),
    ('sting_chapter_violet', 'sfx', sting_chapter_violet, -1.0),
    ('sting_arch_threaded', 'sfx', sting_arch_threaded, -1.0),
    ('sting_mission_complete', 'sfx', sting_mission_complete, -1.0),
    ('sting', 'sfx', sting_generic, -1.0),
    ('thunder', 'sfx', sfx_thunder, -1.0),
]

# tempo metadata for beat-quantized music switches
TEMPO = {'music_title': (98, 4), 'music_level': (140, 4), 'music_boss': (160, 4), 'music_violet': (120, 4)}

# -----------------------------------------------------------------------------
# Shipping. Every sound renders at 44.1 kHz in memory, is resampled when its
# content allows, then encoded. Only the shipped file lands in the project root.
# -----------------------------------------------------------------------------

# MP3 (LAME VBR, mono, no Xing/LAME tag) for the long, dense cues. Rive decodes
# MP3 with dr_mp3, which ignores gapless tags: every instance starts MP3_LEAD
# samples late (encoder 576 + decoder 529, measured through miniaudio). Loops
# stay aligned because every instance carries the same lead; META.lead lets
# sfx.beat() compensate. -t drops the tag frame, which would decode as another
# 1152 samples of silence.
# The wind/jet ambience loops are broadband noise: MP3 V0 costs a third of FLAC and the
# seam error equals the codec error elsewhere (sfx.as schedules loops sample-exact).
# The set-piece stings are short scores like the jingles: MP3 is a quarter of FLAC
# (sting_training_complete 163 -> 39 KB); the decoder lead only delays them 25 ms.
STINGS = tuple(e[0] for e in SOUNDS if e[0] == 'sting' or e[0].startswith('sting_'))
MP3 = ('music_title', 'music_level', 'music_boss', 'music_violet', 'jingle_clear', 'jingle_over',
       'wind', 'jet', 'jet_boost') + STINGS
MP3_VBR = 0  # LAME -V0 ("extreme"): measured 3-4 dB more SNR in every band than -V2 for +36% size
MP3_LEAD = 1105
# Everything else ships as FLAC: lossless, so loop seams and the charge handoff
# stay sample-exact and one-shots start with no decoder latency. The rate
# follows the content: 22.05 kHz when the band above 9 kHz sits 40 dB under the
# sound, 32 kHz when the band above 13.5 kHz does, else 44.1 kHz.
RATE_FIXED = {'wind': 32000, 'jet': SR, 'jet_boost': SR}
HF_QUIET_DB = -40.0
FLAC_MIN_FRAMES = 4608  # afconvert silently writes a broken 42-byte FLAC below one block
EXTS = ('mp3', 'flac', 'wav')


def xfade_len(name, rate=SR):
    """Loop crossfade overlap (samples): the file carries a fading copy of its own head."""
    return int(round((0.01 if name == 'charge_hold' else 0.03) * rate))


def with_xfade_tail(x, X):
    """[head fading in] + body + [head fading out]. Two copies started exactly one loop
    period apart sum back to the original; a late start overlaps instead of gapping."""
    head = x[:X]
    out = [v * (i / X) for i, v in enumerate(head)] + x[X:]
    out += [v * (1.0 - i / X) for i, v in enumerate(head)]
    return out


def trim_tail(x, thresh_db=-58.0, win=0.01, pad=0.015):
    """Cut the tail once the 10 ms RMS stays under thresh_db."""
    t = db(thresh_db)
    W = max(1, N(win))
    end = len(x)
    while end > W:
        seg = x[end - W:end]
        if math.sqrt(sum(v * v for v in seg) / W) >= t:
            break
        end -= W // 2
    return x[:min(len(x), end + N(pad))]


def band_db(x, fc):
    """Energy above fc (4th-order Butterworth high-pass) relative to the whole sound, dB."""
    y = biquad(biquad(x, 'hp', fc, 0.5412), 'hp', fc, 1.3066)
    e = sum(v * v for v in y)
    t = sum(v * v for v in x) or 1e-30
    return 10.0 * math.log10(max(e / t, 1e-30))


def content_rate(x):
    if band_db(x, 9000.0) < HF_QUIET_DB:
        return 22050
    if band_db(x, 13500.0) < HF_QUIET_DB:
        return 32000
    return SR


def ship_rate(name, kind, x):
    if name in RATE_FIXED:
        return RATE_FIXED[name]
    if name in MP3:
        return SR
    if name in ('charge', 'charge_hold'):  # the rise hands off to the loop: one rate for both
        a, b = charge_pair()
        rate = max(content_rate(a), content_rate(b))
    else:
        rate = content_rate(x)
    if kind == 'loop' and (len(x) * rate) % SR:
        return SR  # a loop period must stay a whole number of samples
    return rate


def _i0(v):
    s, term, k = 1.0, 1.0, 1
    while term > 1e-12 * s:
        term *= (v / (2.0 * k)) ** 2
        s += term
        k += 1
    return s


_RS = {}


def _resampler(rate, half=48, beta=7.0):
    """Polyphase Kaiser-windowed sinc (about -75 dB stopband, cutoff at 94% of the new Nyquist)."""
    key = (rate, half, beta)
    if key in _RS:
        return _RS[key]
    g = math.gcd(SR, rate)
    up, down = rate // g, SR // g
    fc = 0.5 * min(1.0, up / down) * 0.94  # cycles per input sample
    ib = _i0(beta)
    phases = []
    for p in range(up):
        frac = p / up
        taps = []
        for q in range(2 * half):
            d = frac + half - 1 - q
            u = d / half
            w = _i0(beta * math.sqrt(1.0 - u * u)) / ib if abs(u) < 1.0 else 0.0
            a = math.pi * 2.0 * fc * d
            taps.append(w * (2.0 * fc if d == 0 else math.sin(a) / (math.pi * d)))
        s = sum(taps)
        phases.append([v / s for v in taps])
    _RS[key] = (up, down, half, phases)
    return _RS[key]


def resample(x, rate, loop=False):
    """44.1 kHz -> rate. loop=True wraps the filter around (seamless period)."""
    if rate == SR:
        return list(x)
    up, down, half, phases = _resampler(rate)
    n = len(x)
    if loop:
        ext = list(x[-half:]) + list(x) + list(x[:half + 1])
        m = n * up // down
    else:
        ext = [0.0] * half + list(x) + [0.0] * (half + 1)
        m = -(-n * up // down)
    w = 2 * half
    out = []
    app = out.append
    for j in range(m):
        k, p = divmod(j * down, up)
        app(sum(map(mul, phases[p], ext[k + 1:k + 1 + w])))
    return out


def pcm16(x):
    a = array.array('h', [(32767 if v >= 1.0 else -32767 if v <= -1.0 else int(round(v * 32767))) for v in x])
    if sys.byteorder == 'big':
        a.byteswap()
    return a.tobytes()


def write_wav(path, x, rate=SR):
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm16(x))


def flac_info(path):
    """(rate, frames) from a FLAC STREAMINFO block, or None."""
    try:
        with open(path, 'rb') as f:
            h = f.read(42)
    except OSError:
        return None
    if len(h) < 42 or h[:4] != b'fLaC' or (h[4] & 0x7F) != 0:
        return None
    si = h[8:42]
    rate = (si[10] << 12) | (si[11] << 4) | (si[12] >> 4)
    frames = ((si[13] & 0x0F) << 32) | (si[14] << 24) | (si[15] << 16) | (si[16] << 8) | si[17]
    return rate, frames


def wav_info(path):
    with wave.open(path, 'rb') as w:
        return w.getframerate(), w.getnframes()


def _run(cmd):
    import subprocess
    try:
        return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def encode(name, x, rate, codec):
    """Write <name>.<ext> at the project root; returns the codec actually shipped (falls back to FLAC, then WAV)."""
    import shutil
    import tempfile
    tmp = tempfile.mkdtemp(prefix='gen_audio_')
    try:
        wav = os.path.join(tmp, name + '.wav')
        write_wav(wav, x, rate)
        best = (wav, 'wav')
        if codec == 'mp3':
            dst = os.path.join(tmp, name + '.mp3')
            if shutil.which('lame'):
                _run(['lame', '--quiet', '-t', '--noreplaygain', '-m', 'm', '-V', str(MP3_VBR), wav, dst])
            elif shutil.which('ffmpeg'):
                _run(['ffmpeg', '-v', 'error', '-y', '-i', wav, '-c:a', 'libmp3lame', '-q:a', str(MP3_VBR),
                      '-write_xing', '0', '-id3v2_version', '0', '-write_id3v1', '0', dst])
            if os.path.exists(dst) and os.path.getsize(dst) > 1024:
                best = (dst, 'mp3')
            else:
                codec = 'flac'
        if codec == 'flac' and len(x) >= FLAC_MIN_FRAMES:
            dst = os.path.join(tmp, name + '.flac')
            cmds = []
            if shutil.which('afconvert'):
                cmds.append(['afconvert', '-f', 'flac', '-d', 'flac', wav, dst])
            if shutil.which('ffmpeg'):
                cmds.append(['ffmpeg', '-v', 'error', '-y', '-i', wav, '-c:a', 'flac', '-compression_level', '12', dst])
            for cmd in cmds:
                if _run(cmd) and flac_info(dst) == (rate, len(x)) and os.path.getsize(dst) < os.path.getsize(wav):
                    best = (dst, 'flac')
                    break
        ext = best[1]
        for e in EXTS:
            p = os.path.join(AUDIO_DIR, name + '.' + e)
            if e != ext and os.path.exists(p):
                os.remove(p)
        shutil.move(best[0], os.path.join(AUDIO_DIR, name + '.' + ext))
        return ext
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def shipped(name):
    for e in EXTS:
        p = os.path.join(AUDIO_DIR, name + '.' + e)
        if os.path.exists(p):
            return p, e
    return None, None


def render(name):
    entry = [e for e in SOUNDS if e[0] == name][0]
    name, kind, fn, pk = entry
    random.seed(zlib.crc32(name.encode()))
    x = fn()
    if kind == 'loop':
        x = periodic(lambda v: hp1(v, 18.0), x, N(0.5))
        x = normalize(x, pk) if pk is not None else x
        dur = len(x) / SR
    elif kind == 'rise':  # hands off to a loop at full level: no trim, no tail fade
        x = fade_edges(x, 0.005, 0.0)
        dur = (len(x) - xfade_len('charge_hold')) / SR  # its fading twin overlaps the loop head
    else:
        x = hp1(x, 18.0)  # DC / infrasonic
        x = normalize(x, pk) if pk is not None else x
        if kind == 'music':
            x = fade_edges(trim_silence(x, -54.0, 0.03), 0.0003, 0.05)
        else:
            x = fade_edges(trim_tail(x, -58.0), 0.0003, 0.03)
        dur = len(x) / SR
    rate = ship_rate(name, kind, x)
    y = x
    if rate != SR:
        y = resample(x, rate, kind == 'loop')
        p0, p1 = peak(x), peak(y)
        if p1 > p0 > 0:
            y = scale(y, p0 / p1)
    if kind == 'loop':
        y = with_xfade_tail(y, xfade_len(name, rate))
    codec = encode(name, y, rate, 'mp3' if name in MP3 else 'flac')
    lead = MP3_LEAD / rate if codec == 'mp3' else 0.0
    return name, {'dur': dur, 'loop': kind == 'loop', 'lead': lead, 'rate': rate, 'codec': codec}


def read_wav(path):
    with wave.open(path, 'rb') as w:
        n = w.getnframes()
        sr = w.getframerate()
        ch = w.getnchannels()
        sw = w.getsampwidth()
        a = array.array('h')
        a.frombytes(w.readframes(n))
    if sys.byteorder == 'big':
        a.byteswap()
    return sr, ch, sw, [v / 32768.0 for v in a]


def mp3_rate(path):
    """Sample rate from the first MPEG audio frame header."""
    with open(path, 'rb') as f:
        b = f.read(8192)
    i = 0
    if b[:3] == b'ID3' and len(b) > 10:
        i = 10 + ((b[6] & 0x7F) << 21 | (b[7] & 0x7F) << 14 | (b[8] & 0x7F) << 7 | (b[9] & 0x7F))
    while i < len(b) - 3:
        if b[i] == 0xFF and (b[i + 1] & 0xE0) == 0xE0:
            ver, sri = (b[i + 1] >> 3) & 3, (b[i + 2] >> 2) & 3
            if ver != 1 and sri != 3:
                base = (44100, 48000, 32000)[sri]
                return base if ver == 3 else base // 2 if ver == 2 else base // 4
        i += 1
    return SR


def decode(path):
    """(rate, samples, lead_adjust) for any shipped file. ffmpeg decodes MP3 exactly like
    Rive's dr_mp3 (full encoder + decoder delay); afconvert removes the 529-sample decoder delay."""
    import shutil
    import subprocess
    import tempfile
    if path.endswith('.wav'):
        sr, _ch, _sw, x = read_wav(path)
        return sr, x, 0
    if shutil.which('ffmpeg'):
        rate = flac_info(path)[0] if path.endswith('.flac') else mp3_rate(path)
        cmd = ['ffmpeg', '-v', 'error', '-i', path, '-f', 's16le', '-ac', '1', '-']
        raw = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=120).stdout
        a = array.array('h')
        a.frombytes(raw)
        if sys.byteorder == 'big':
            a.byteswap()
        return rate, [v / 32768.0 for v in a], 0
    tmp = tempfile.mkdtemp(prefix='gen_audio_')
    try:
        out = os.path.join(tmp, 'd.wav')
        subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16', path, out], timeout=120)
        sr, _ch, _sw, x = read_wav(out)
        return sr, x, (-529 if path.endswith('.mp3') else 0)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


META_ROW = re.compile(r'^\s*meta\("(\w+)", ([0-9.]+), (true|false), (\d+), (\d+), ([0-9.]+)\);\s*$')
PEAK_ROW = re.compile(r'^\s*peak\("(\w+)", "([0-9A-Za-z]*)"\);\s*$')
DENS_ROW = re.compile(r'^\s*dens\("(\w+)", ([0-9.]+)\);\s*$')

# Peak envelopes for the sfx.as limiter (PEAK in the generated block), measured on
# the shipped files as the runtime decodes them (MP3 lead included). One-shot: the
# sample peak of each PK_WIN window, widened by a window each side (clock slack),
# rounded up to a PK_ALPHA step, trailing silence dropped. Loop: one step, its p99.
# DENS is each file's rms over that envelope (the limiter counts a sound that is
# not the loudest by its rms): one-shot, the 90th percentile of window rms / PEAK
# step over the windows within 14 dB of its top; loop, rms / PEAK step. Rounded up.
PK_WIN = 0.025
PK_ALPHA = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'


def _peak_env(entry):
    name, kind = entry
    path, _ext = shipped(name)
    if path is None:
        return name, None, None
    try:
        sr, x, adj = decode(path)
    except (OSError, ValueError):
        return name, None, None
    if adj < 0:
        x = [0.0] * (-adj) + x
    top = len(PK_ALPHA) - 1

    def qi(v):
        return max(0, min(top, int(math.ceil(v * top - 1e-6))))

    def up(v):
        return min(1.0, math.ceil(v * 100 - 1e-6) / 100)
    if kind == 'loop':
        s = sorted(abs(v) for v in x[::3])
        if not s:
            return name, None, None
        k = qi(s[int(len(s) * 0.99)])
        rms = math.sqrt(sum(v * v for v in x) / len(x))
        return name, PK_ALPHA[k], up(rms * top / k) if k else 1.0
    w = max(1, int(round(PK_WIN * sr)))
    pk = [max(map(abs, x[i:i + w])) for i in range(0, len(x), w)]
    wide = [qi(max(pk[max(0, i - 1):i + 2])) for i in range(len(pk))]
    rms = [math.sqrt(sum(v * v for v in x[i:i + w]) / w) for i in range(0, len(x), w)]
    loud = 0.2 * max(wide) if wide else 0
    ratios = sorted(r * top / k for r, k in zip(rms, wide) if k and k >= loud)
    dens = up(ratios[min(len(ratios) - 1, int(math.ceil(0.9 * (len(ratios) - 1))))]) if ratios else 1.0
    return name, ''.join(PK_ALPHA[k] for k in wide).rstrip('0'), dens


def peak_envs():
    import multiprocessing as mp
    todo = [(n, k) for n, k, _f, _p in SOUNDS]
    with mp.Pool(max(1, min(len(todo), (os.cpu_count() or 4) - 2))) as pool:
        res = pool.map(_peak_env, todo)
    return dict((n, e) for n, e, _d in res), dict((n, d) for n, _e, d in res)


def read_peaks():
    path = os.path.join(ROOT, 'src', 'game', 'sfx.as')
    out = {}
    dens = {}
    try:
        with open(path) as f:
            for line in f:
                m = PEAK_ROW.match(line)
                if m:
                    out[m.group(1)] = m.group(2)
                m = DENS_ROW.match(line)
                if m:
                    dens[m.group(1)] = float(m.group(2))
    except OSError:
        pass
    return out, dens


def read_meta():
    path = os.path.join(ROOT, 'src', 'game', 'sfx.as')
    out = {}
    try:
        with open(path) as f:
            for line in f:
                m = META_ROW.match(line)
                if m:
                    out[m.group(1)] = {'dur': float(m.group(2)), 'loop': m.group(3) == 'true', 'lead': float(m.group(6) or 0)}
    except OSError:
        pass
    return out


def meta_from_file(name, kind):
    """Rebuild a META entry from a lossless shipped file (MP3 lengths are not recoverable)."""
    path, ext = shipped(name)
    if path is None or ext == 'mp3':
        return None
    rate, frames = flac_info(path) if ext == 'flac' else wav_info(path)
    if kind == 'loop':
        frames -= xfade_len(name, rate)
    elif kind == 'rise':
        frames -= xfade_len('charge_hold', rate)
    return {'dur': frames / rate, 'loop': kind == 'loop', 'lead': 0.0}


def write_meta(results):
    """Rewrite the GENERATED block in src/game/sfx.as: exact loop periods, tempo and MP3 lead.
    Sounds not rendered in this run keep their existing row."""
    path = os.path.join(ROOT, 'src', 'game', 'sfx.as')
    with open(path) as f:
        src = f.read()
    old = read_meta()
    rows = []
    for name, kind, _fn, _pk in SOUNDS:
        m = results.get(name) or old.get(name) or meta_from_file(name, kind)
        if m is None:
            continue
        bpm, bpb = TEMPO.get(name, (0, 0))
        # every length is a whole number of 44.1 kHz samples: snap (old rows were
        # printed to 6 decimals) and print 9, so loop chains stay sample-exact for hours
        dur = round(m['dur'] * SR) / SR
        fpath, ext = shipped(name)
        lead = MP3_LEAD / mp3_rate(fpath) if ext == 'mp3' else 0.0
        rows.append('    meta("%s", %.9f, %s, %d, %d, %.9f);' % (
            name, dur, 'true' if m['loop'] else 'false', bpm, bpb, lead))
    old_pk, old_dn = read_peaks()
    new_pk, new_dn = peak_envs()
    pk_rows = []
    dn_rows = []
    for name, _kind, _fn, _pk in SOUNDS:
        e = new_pk.get(name)
        d = new_dn.get(name)
        if e is None:
            e = old_pk.get(name)
            d = old_dn.get(name)
        if e is not None:
            pk_rows.append('    peak("%s", "%s");' % (name, e))
        if e is not None and d is not None:
            dn_rows.append('    dens("%s", %.2f);' % (name, d))
    block = ('// BEGIN GENERATED (tools/gen_audio.py)\n'
             '// META: name, dur, loop, bpm, beats, lead\n'
             'function genMeta(): void {\n'
             + '\n'.join(rows) + '\n}\n'
             '// peak envelopes (limiter): PK_ALPHA step per 25 ms window; loops: p99\n'
             'function genPeak(): void {\n'
             + '\n'.join(pk_rows) + '\n}\n'
             "// rms / peak envelope over each file's loud windows (limiter); loops: rms / p99\n"
             'function genDens(): void {\n'
             + '\n'.join(dn_rows) + '\n}\n// END GENERATED')
    a = src.find('// BEGIN GENERATED')
    b = src.find('// END GENERATED')
    if a < 0 or b < 0:
        print('warning: no GENERATED block in sfx.as')
        return
    b += len('// END GENERATED')
    src = src[:a] + block + src[b:]
    with open(path, 'w') as f:
        f.write(src)


def mix_category(name):
    """The sound's mix category in src/game/sfx.as (`category`)."""
    if name.startswith('music_') or name.startswith('jingle_'):
        return 'music'
    if name == 'sting' or name.startswith('sting_'):
        return 'sting'
    if name in ('wind', 'jet', 'jet_boost', 'comm_static'):
        return 'amb'
    if name.startswith('ui_') or name in ('countdown', 'pause', 'comm', 'comm_out', 'score_tick'):
        return 'ui'
    return 'sfx'


def _stat_one(entry):
    name, kind, meta = entry
    path, ext = shipped(name)
    if path is None:
        return name, None
    size = os.path.getsize(path)
    sr, x, adj = decode(path)
    pk = peak(x)
    rms = math.sqrt(sum(v * v for v in x) / max(1, len(x)))
    dc = sum(x) / max(1, len(x))
    seam = xf = ''
    if kind == 'loop' and meta:
        # replay two copies one period apart (as the scheduler does) and measure the seam
        P = int(round(meta['dur'] * sr))
        lead = int(round(meta['lead'] * sr)) + adj
        X = xfade_len(name, sr)
        s = P + lead
        n = len(x)
        z = [(x[j] if j < n else 0.0) + (x[j - P] if j >= P else 0.0) for j in range(s - 64, s + 2 * X + 64)]
        steps = [abs(x[i + 1] - x[i]) for i in range(lead, len(x) - 1, 7)]
        typ = sorted(steps)[int(len(steps) * 0.99)] or 1e-9
        jump = max(abs(z[i + 1] - z[i]) for i in range(48, 80))
        seam = '%.2f' % (jump / typ)
        a = z[64:64 + X]
        b = z[64 + X:64 + 2 * X]
        ra = math.sqrt(sum(v * v for v in a) / max(1, len(a)))
        rb = math.sqrt(sum(v * v for v in b) / max(1, len(b)))
        xf = '%+.1f' % (20 * math.log10(max(ra, 1e-9) / max(rb, 1e-9)))
    dur = meta['dur'] if meta else len(x) / sr
    return name, (size, ext, sr, len(x) / sr, pk, rms, dc, seam, xf, dur, kind)


def stats():
    meta = read_meta()
    todo = [(n, k, meta.get(n)) for n, k, _f, _p in SOUNDS]
    import multiprocessing as mp
    with mp.Pool(max(1, (os.cpu_count() or 4) - 2)) as pool:
        res = dict(pool.map(_stat_one, todo))
    tot = old = 0
    print('%-15s %5s %6s %7s %7s %7s %8s %6s %6s %8s %6s  %-5s %s' % ('name', 'fmt', 'rate', 'sec', 'peak', 'rms', 'dc', 'seam', 'xfade', 'bytes', 'kbps', 'kind', 'mix'))
    for n, k, _m in todo:
        r = res.get(n)
        if r is None:
            print('%-15s MISSING' % n)
            continue
        size, ext, sr, sec, pk, rms, dc, seam, xf, dur, kind = r
        tot += size
        old += 44 + 2 * int(round(sec * 44100)) if ext != 'mp3' else 44 + 2 * int(round((dur + (0.03 if kind == 'loop' else 0)) * 44100))
        print('%-15s %5s %6d %7.3f %7.1f %7.1f %8.4f %6s %6s %8d %6.0f  %-5s %s' % (
            n, ext, sr, sec, 20 * math.log10(max(pk, 1e-9)), 20 * math.log10(max(rms, 1e-9)), dc, seam, xf, size,
            size * 8 / max(sec, 1e-3) / 1000, kind, mix_category(n)))
    print('total %.2f MB (44.1 kHz 16-bit WAV equivalent %.2f MB, -%.0f%%)' % (tot / 1e6, old / 1e6, 100 * (1 - tot / max(old, 1))))


def main(argv):
    if '--list' in argv:
        for i, (name, kind, _fn, pk) in enumerate(SOUNDS):
            path, ext = shipped(name)
            print('5:%-3d %-16s %-5s %s' % (i + 1, name, kind, ext or '-'))
        return
    if '--stats' in argv:
        stats()
        return
    os.makedirs(AUDIO_DIR, exist_ok=True)
    results = {}
    if '--meta' not in argv:
        want = [a for a in argv if not a.startswith('-')]
        todo = [e for e in SOUNDS if not want or e[0] in want]
        unknown = set(want) - set(e[0] for e in SOUNDS)
        if unknown:
            raise SystemExit('unknown sounds: %s' % ', '.join(sorted(unknown)))
        # heavy jobs first for better packing
        weight = {'music_level': 0, 'music_boss': 1, 'music_violet': 2, 'music_title': 3, 'wind': 4}
        todo.sort(key=lambda e: weight.get(e[0], 10))
        if len(todo) > 1 and '--serial' not in argv:
            import multiprocessing as mp
            with mp.Pool(min(len(todo), max(1, (os.cpu_count() or 4) - 2))) as pool:
                for name, m in pool.imap_unordered(render, [e[0] for e in todo]):
                    results[name] = m
                    print('%-16s %6.2f s  %-4s %5d Hz' % (name, m['dur'], m['codec'], m['rate']), flush=True)
        else:
            for e in todo:
                name, m = render(e[0])
                results[name] = m
                print('%-16s %6.2f s  %-4s %5d Hz' % (name, m['dur'], m['codec'], m['rate']), flush=True)
    write_meta(results)


if __name__ == '__main__':
    main(sys.argv[1:])
