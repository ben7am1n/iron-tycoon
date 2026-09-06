#!/usr/bin/env python3
"""
Procedural Audio Asset Generator for Iron Tycoon (Gym Manager).
Synthesizes clean, high-quality 16-bit 44.1kHz PCM WAV audio assets
based on design/assets/entity-inventory.md and game design requirements.
Uses only Python standard library (wave, struct, math, random).
"""

import os
import math
import struct
import wave
import random

SAMPLE_RATE = 44100

def clamp(val, min_val, max_val):
    return max(min_val, min(max_val, val))

def write_wav(path: str, samples, sample_rate: int = SAMPLE_RATE, channels: int = 1):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    num_frames = len(samples) if channels == 1 else len(samples) // channels
    with wave.open(path, 'wb') as f:
        f.setnchannels(channels)
        f.setsampwidth(2)  # 16-bit
        f.setframerate(sample_rate)
        # Pack samples into signed 16-bit little-endian
        packed_data = bytearray()
        for s in samples:
            sample_val = int(clamp(s, -1.0, 1.0) * 32767.0)
            packed_data.extend(struct.pack('<h', sample_val))
        f.writeframes(packed_data)
    print(f"Generated: {path} ({num_frames} frames, {channels} ch, {len(packed_data)} bytes)")

def adsr(t, duration, attack=0.01, decay=0.05, sustain_level=0.5, release=0.05):
    """ADSR envelope generator."""
    if t < 0 or t > duration:
        return 0.0
    if t < attack:
        return t / max(attack, 1e-6)
    t_after_attack = t - attack
    if t_after_attack < decay:
        ratio = t_after_attack / max(decay, 1e-6)
        return 1.0 - ratio * (1.0 - sustain_level)
    sustain_time = max(0.0, duration - attack - decay - release)
    t_after_decay = t_after_attack - decay
    if t_after_decay < sustain_time:
        return sustain_level
    t_after_sustain = t_after_decay - sustain_time
    if t_after_sustain < release:
        ratio = t_after_sustain / max(release, 1e-6)
        return sustain_level * (1.0 - ratio)
    return 0.0

def generate_placement_snap() -> list:
    """Soft, satisfying solid click/snap on placement commit."""
    duration = 0.09
    num_samples = int(SAMPLE_RATE * duration)
    samples = []
    rng = random.Random(42)
    for i in range(num_samples):
        t = i / SAMPLE_RATE
        # Initial transient pop/click (3ms)
        click = rng.uniform(-1, 1) * math.exp(-t * 200) * 0.4
        # Pitch-dropping body (260 Hz down to 80 Hz)
        freq = 80 + 180 * math.exp(-t * 40)
        phase = 2 * math.pi * freq * t
        tone = math.sin(phase) * math.exp(-t * 35) * 0.7
        # Low wooden thump (120 Hz)
        thump = math.sin(2 * math.pi * 120 * t) * math.exp(-t * 28) * 0.3
        sample = (click + tone + thump) * 0.9
        samples.append(sample)
    return samples

def generate_pickup() -> list:
    """Gentle, subtle upward glide when picking up/dragging equipment."""
    duration = 0.08
    num_samples = int(SAMPLE_RATE * duration)
    samples = []
    for i in range(num_samples):
        t = i / SAMPLE_RATE
        # Glide from 240 Hz to 480 Hz
        freq = 240 + 240 * (t / duration)
        env = adsr(t, duration, attack=0.015, decay=0.03, sustain_level=0.4, release=0.035)
        tone = math.sin(2 * math.pi * freq * t)
        sample = tone * env * 0.65
        samples.append(sample)
    return samples

def generate_purchase_confirm() -> list:
    """Positive warm major triad arpeggio (C5 -> E5 -> G5 -> C6) for purchase confirm."""
    duration = 0.28
    num_samples = int(SAMPLE_RATE * duration)
    samples = []
    notes = [523.25, 659.25, 783.99, 1046.50]  # C5, E5, G5, C6
    note_times = [0.0, 0.05, 0.10, 0.15]
    for i in range(num_samples):
        t = i / SAMPLE_RATE
        val = 0.0
        for freq, start in zip(notes, note_times):
            if t >= start:
                dt = t - start
                env = math.exp(-dt * 14.0)
                tone = math.sin(2 * math.pi * freq * dt) + 0.25 * math.sin(4 * math.pi * freq * dt)
                val += tone * env * 0.28
        samples.append(val)
    return samples

def generate_sold_cue() -> list:
    """Gentle descending chime with shimmer for selling equipment."""
    duration = 0.22
    num_samples = int(SAMPLE_RATE * duration)
    samples = []
    notes = [783.99, 659.25, 523.25]  # G5, E5, C5
    note_times = [0.0, 0.06, 0.12]
    for i in range(num_samples):
        t = i / SAMPLE_RATE
        val = 0.0
        for freq, start in zip(notes, note_times):
            if t >= start:
                dt = t - start
                env = math.exp(-dt * 15.0)
                tone = math.sin(2 * math.pi * freq * dt)
                val += tone * env * 0.32
        samples.append(val)
    return samples

def generate_income_coin() -> list:
    """Cozy, delightful bell/coin chime on member finish (never stressful)."""
    duration = 0.25
    num_samples = int(SAMPLE_RATE * duration)
    samples = []
    f1, f2 = 1318.51, 1567.98  # E6, G6 ringing bell harmonics
    for i in range(num_samples):
        t = i / SAMPLE_RATE
        env1 = math.exp(-t * 11.0)
        env2 = math.exp(-t * 9.0)
        tone = 0.5 * math.sin(2 * math.pi * f1 * t) * env1 + 0.4 * math.sin(2 * math.pi * f2 * t) * env2
        shimmer = 0.1 * math.sin(2 * math.pi * (f1 * 2) * t) * math.exp(-t * 18.0)
        samples.append((tone + shimmer) * 0.75)
    return samples

def generate_satisfaction_chime() -> list:
    """Warm rising dual-tone chime when satisfaction increases."""
    duration = 0.35
    num_samples = int(SAMPLE_RATE * duration)
    samples = []
    chord1 = [440.0, 554.37]       # A4, C#5
    chord2 = [554.37, 659.25, 880.0]  # C#5, E5, A5
    for i in range(num_samples):
        t = i / SAMPLE_RATE
        val = 0.0
        dt1 = t
        env1 = math.exp(-dt1 * 12.0)
        for f in chord1:
            val += 0.25 * math.sin(2 * math.pi * f * dt1) * env1
        if t >= 0.11:
            dt2 = t - 0.11
            env2 = math.exp(-dt2 * 8.0)
            for f in chord2:
                val += 0.22 * math.sin(2 * math.pi * f * dt2) * env2
        samples.append(val * 0.8)
    return samples

def generate_save_chime() -> list:
    """Peaceful soft chime on game save."""
    duration = 0.28
    num_samples = int(SAMPLE_RATE * duration)
    samples = []
    notes = [659.25, 880.0]  # E5, A5
    times = [0.0, 0.09]
    for i in range(num_samples):
        t = i / SAMPLE_RATE
        val = 0.0
        for f, st in zip(notes, times):
            if t >= st:
                dt = t - st
                env = math.exp(-dt * 10.0)
                val += 0.35 * math.sin(2 * math.pi * f * dt) * env
        samples.append(val * 0.75)
    return samples

def generate_ui_click() -> list:
    """Light, crisp mechanical micro-click for pause & speed buttons."""
    duration = 0.035
    num_samples = int(SAMPLE_RATE * duration)
    samples = []
    rng = random.Random(101)
    for i in range(num_samples):
        t = i / SAMPLE_RATE
        click = rng.uniform(-1, 1) * math.exp(-t * 220.0) * 0.4
        transient = math.sin(2 * math.pi * 950.0 * t) * math.exp(-t * 160.0) * 0.6
        samples.append((click + transient) * 0.6)
    return samples

def generate_dialogue_blip() -> list:
    """Retro friendly text blip for dialog character speech."""
    duration = 0.045
    num_samples = int(SAMPLE_RATE * duration)
    samples = []
    freq = 466.16  # Bb4
    for i in range(num_samples):
        t = i / SAMPLE_RATE
        env = adsr(t, duration, attack=0.005, decay=0.02, sustain_level=0.4, release=0.02)
        phase = (t * freq) % 1.0
        tri = 2.0 * abs(2.0 * (phase - math.floor(phase + 0.5))) - 1.0
        sine = math.sin(2 * math.pi * freq * t)
        sample = (tri * 0.6 + sine * 0.4) * env * 0.55
        samples.append(sample)
    return samples

def generate_gym_ambient() -> list:
    """
    Subtle soothing ambient room presence: low ventilation hum (60Hz + 120Hz)
    with soft warm room acoustic resonance, 3.0s seamless loop stereo.
    """
    duration = 3.0
    num_samples = int(SAMPLE_RATE * duration)
    left_samples = []
    right_samples = []
    rng = random.Random(777)
    
    noise_buffer = [rng.uniform(-1, 1) for _ in range(num_samples)]
    filtered_noise = [0.0] * num_samples
    alpha = 0.04
    current_val = 0.0
    for i in range(num_samples):
        current_val += alpha * (noise_buffer[i] - current_val)
        filtered_noise[i] = current_val

    for i in range(num_samples):
        t = i / SAMPLE_RATE
        hum60 = math.sin(2 * math.pi * 60.0 * t) * 0.18
        hum120 = math.sin(2 * math.pi * 120.0 * t) * 0.10
        hum90 = math.sin(2 * math.pi * 90.0 * t + 0.5) * 0.06
        
        noise_l = filtered_noise[i] * 0.12
        noise_r = filtered_noise[(i + 4410) % num_samples] * 0.12
        
        l = (hum60 + hum120 + hum90 + noise_l) * 0.4
        r = (hum60 + hum120 + hum90 + noise_r) * 0.4
        left_samples.append(l)
        right_samples.append(r)

    interleaved = []
    for l, r in zip(left_samples, right_samples):
        interleaved.append(l)
        interleaved.append(r)
    return interleaved

def generate_cozy_bgm_groove() -> list:
    """
    Cozy lo-fi electric piano & synth pulse loop (4.0s seamless loop at 120 BPM, 2 bars = 8 beats).
    Chords: Cmaj9 -> Am9 -> Fmaj7 -> G9sus4.
    Mellow electric piano tone + warm sub-bass + gentle hi-hat shaker.
    """
    duration = 4.0
    bpm = 120.0
    beat_duration = 60.0 / bpm  # 0.5s per beat, 8 beats total
    num_samples = int(SAMPLE_RATE * duration)
    
    chords = [
        (0.0 * beat_duration, [130.81, 196.00, 246.94, 293.66, 329.63], 65.41),   # C2 bass
        (2.0 * beat_duration, [110.00, 164.81, 196.00, 246.94, 261.63], 55.00),   # A1 bass
        (4.0 * beat_duration, [87.31, 130.81, 164.81, 220.00, 261.63], 43.65),    # F1 bass
        (6.0 * beat_duration, [98.00, 146.83, 174.61, 220.00, 293.66], 49.00),    # G1 bass
    ]
    
    left = [0.0] * num_samples
    right = [0.0] * num_samples
    rng = random.Random(999)
    
    chord_len = 2.0 * beat_duration  # 1.0s
    for start_t, freqs, bass_freq in chords:
        start_idx = int(start_t * SAMPLE_RATE)
        chord_samples = int((chord_len + 0.2) * SAMPLE_RATE)
        for i in range(chord_samples):
            idx = (start_idx + i) % num_samples
            dt = i / SAMPLE_RATE
            env = math.exp(-dt * 2.8) * min(1.0, dt * 50.0)
            
            chord_sum_l = 0.0
            chord_sum_r = 0.0
            for idx_f, f in enumerate(freqs):
                pan = -0.3 + 0.6 * (idx_f / max(1, len(freqs) - 1))
                tone = math.sin(2 * math.pi * f * dt) + 0.3 * math.sin(4 * math.pi * f * dt)
                chord_sum_l += tone * (0.5 - 0.5 * pan)
                chord_sum_r += tone * (0.5 + 0.5 * pan)
            
            bass_env = math.exp(-dt * 2.0) * min(1.0, dt * 60.0)
            bass_tone = math.sin(2 * math.pi * bass_freq * dt) * 0.8
            
            left[idx] += (chord_sum_l * 0.07 + bass_tone * 0.16) * env
            right[idx] += (chord_sum_r * 0.07 + bass_tone * 0.16) * env
            
    for hit in range(16):
        hit_t = hit * (beat_duration / 2.0)
        start_idx = int(hit_t * SAMPLE_RATE)
        hit_len = int(0.04 * SAMPLE_RATE)
        pan = 0.2 if hit % 2 == 1 else -0.2
        volume = 0.035 if hit % 2 == 1 else 0.02
        for i in range(hit_len):
            idx = (start_idx + i) % num_samples
            dt = i / SAMPLE_RATE
            shaker = rng.uniform(-1, 1) * math.exp(-dt * 90.0) * volume
            left[idx] += shaker * (0.5 - 0.5 * pan)
            right[idx] += shaker * (0.5 + 0.5 * pan)

    max_amp = max(max(abs(l) for l in left), max(abs(r) for r in right), 0.001)
    scale = 0.70 / max_amp if max_amp > 0.70 else 1.0
    
    interleaved = []
    for l, r in zip(left, right):
        interleaved.append(l * scale)
        interleaved.append(r * scale)
    return interleaved

def main():
    base_dir = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    audio_dir = os.path.join(base_dir, "assets", "audio")
    sfx_dir = os.path.join(audio_dir, "sfx")
    amb_dir = os.path.join(audio_dir, "ambient")
    bgm_dir = os.path.join(audio_dir, "bgm")

    os.makedirs(sfx_dir, exist_ok=True)
    os.makedirs(amb_dir, exist_ok=True)
    os.makedirs(bgm_dir, exist_ok=True)

    print("Generating SFX assets...")
    write_wav(os.path.join(sfx_dir, "placement_snap.wav"), generate_placement_snap(), channels=1)
    write_wav(os.path.join(sfx_dir, "pickup.wav"), generate_pickup(), channels=1)
    write_wav(os.path.join(sfx_dir, "purchase_confirm.wav"), generate_purchase_confirm(), channels=1)
    write_wav(os.path.join(sfx_dir, "sold_cue.wav"), generate_sold_cue(), channels=1)
    write_wav(os.path.join(sfx_dir, "income_coin.wav"), generate_income_coin(), channels=1)
    write_wav(os.path.join(sfx_dir, "satisfaction_chime.wav"), generate_satisfaction_chime(), channels=1)
    write_wav(os.path.join(sfx_dir, "save_chime.wav"), generate_save_chime(), channels=1)
    write_wav(os.path.join(sfx_dir, "ui_click.wav"), generate_ui_click(), channels=1)
    write_wav(os.path.join(sfx_dir, "dialogue_blip.wav"), generate_dialogue_blip(), channels=1)

    print("Generating Ambient assets...")
    write_wav(os.path.join(amb_dir, "gym_ambient.wav"), generate_gym_ambient(), channels=2)

    print("Generating BGM assets...")
    write_wav(os.path.join(bgm_dir, "cozy_gym_groove.wav"), generate_cozy_bgm_groove(), channels=2)

    print("All audio assets generated successfully!")

if __name__ == "__main__":
    main()
