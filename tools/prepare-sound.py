"""Готовит звук уведомления под требования виджета.

Моно, 44.1 кГц, 16 бит; обрезает тишину, при необходимости оставляет только
первые N ударов, нормализует уровень и сохраняет WAV, который проигрывается
через SoundPlayer без кодеков.

Запуск:
    python tools/prepare-sound.py <input.mp3|wav> assets/notify.wav [--knocks 2] [--peak -8]
"""

import argparse

import numpy as np
import soundfile as sf

TARGET_SR = 44100


def to_mono(data):
    return data.mean(axis=1) if data.ndim > 1 else data


def resample(x, src_sr, dst_sr):
    if src_sr == dst_sr:
        return x
    n_out = int(round(len(x) * dst_sr / src_sr))
    return np.interp(np.linspace(0, len(x) - 1, n_out), np.arange(len(x)), x)


def env_peaks(x, sr, min_gap=0.06):
    """Возвращает границы групп (ударов) по огибающей."""
    win = max(1, int(0.005 * sr))
    env = np.convolve(np.abs(x), np.ones(win) / win, mode="same")
    if env.max() <= 0:
        return []
    idx = np.where(env > env.max() * 0.12)[0]
    if len(idx) == 0:
        return []
    gap = int(min_gap * sr)
    groups = []
    start = prev = idx[0]
    for i in idx[1:]:
        if i - prev > gap:
            groups.append((start, prev))
            start = i
        prev = i
    groups.append((start, prev))
    return groups


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--knocks", type=int, default=0, help="оставить первые N ударов (0 — все)")
    ap.add_argument("--peak", type=float, default=-7.0, help="целевой пик, dBFS")
    ap.add_argument("--trim-db", type=float, default=-45.0)
    args = ap.parse_args()

    data, sr = sf.read(args.src, always_2d=False)
    x = resample(to_mono(np.asarray(data, dtype=np.float64)), sr, TARGET_SR)

    groups = env_peaks(x, TARGET_SR)
    if args.knocks > 0 and len(groups) >= args.knocks:
        start = max(0, groups[0][0] - int(0.01 * TARGET_SR))
        end = min(len(x), groups[args.knocks - 1][1] + int(0.14 * TARGET_SR))
        x = x[start:end]
        print(f"оставлено ударов: {args.knocks} из {len(groups)}")
    else:
        thresh = 10 ** (args.trim_db / 20.0)
        loud = np.where(np.abs(x) > thresh)[0]
        if len(loud):
            pad = int(0.01 * TARGET_SR)
            x = x[max(0, loud[0] - pad):min(len(x), loud[-1] + pad)]

    peak = float(np.max(np.abs(x))) if len(x) else 0.0
    if peak > 0:
        x = x * ((10 ** (args.peak / 20.0)) / peak)

    fade = int(0.004 * TARGET_SR)
    if len(x) > 2 * fade:
        x[:fade] *= np.linspace(0.0, 1.0, fade)
        x[-fade:] *= np.linspace(1.0, 0.0, fade)

    pcm = (np.clip(x, -1.0, 1.0) * 32767.0).astype("<i2")
    sf.write(args.dst, pcm, TARGET_SR, subtype="PCM_16", format="WAV")

    peak_db = 20 * np.log10(np.max(np.abs(x)) + 1e-12)
    rms_db = 20 * np.log10(np.sqrt(np.mean(x ** 2)) + 1e-12)
    print(f"готово: {args.dst}")
    print(f"длительность {len(x) / TARGET_SR:.2f} с, пик {peak_db:.1f} dBFS, RMS {rms_db:.1f} dBFS")


if __name__ == "__main__":
    main()
