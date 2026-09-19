"""Generate only fictional demo speech. Credential: ELEVENLABS_API_KEY or stdin.

Cached responses contain audio/alignment only, never credentials or headers.
"""
from pathlib import Path
import base64, json, os, re, subprocess, sys, urllib.request, urllib.error
import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parent
ASSETS = ROOT / 'assets'
VOICE = 'CwhRBWXzGAHq8TQ4Fs17'
CLIPS = [
    ('dictation-workplace', 7.05, 9.1, '[conversational] Okay, quick update. The new website is ready. Let\'s launch on Friday, and share a preview with the team tomorrow.'),
    ('instruction-workplace', 24.05, 6.65, '[matter-of-fact] Actually, make that a short team update. Keep it warm, and finish with a clear next step.'),
]
key = os.environ.get('ELEVENLABS_API_KEY') or (sys.stdin.read().strip() if not sys.stdin.isatty() else '')
timings = []
mix, sr = sf.read(ASSETS / 'music-bed.wav')
assert sr == 48000 and len(mix) == 52 * sr
for name, start, budget, tagged in CLIPS:
    cache = ASSETS / (name + '.json')
    if cache.exists():
        result = json.loads(cache.read_text())
    else:
        if not key:
            sys.exit('Provide ELEVENLABS_API_KEY or a key on stdin to generate uncached speech.')
        body = {'text': tagged, 'model_id': 'eleven_v3', 'voice_settings': {'stability': 0.5, 'similarity_boost': 0.75, 'speed': 1.0}}
        req = urllib.request.Request('https://api.elevenlabs.io/v1/text-to-speech/' + VOICE + '/with-timestamps?output_format=mp3_44100_128', data=json.dumps(body).encode(), headers={'xi-api-key': key, 'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=120) as response:
                result = json.load(response)
        except urllib.error.HTTPError as error:
            try:
                detail = json.load(error).get('detail', {})
                status = detail.get('status', 'unknown') if isinstance(detail, dict) else 'unknown'
                message = detail.get('message', '') if isinstance(detail, dict) else ''
                message = message.replace(key, '[redacted]')
            except (ValueError, AttributeError):
                status, message = 'unknown', ''
            sys.exit(f'ElevenLabs request failed: HTTP {error.code}, {status}: {message}')
        cache.write_text(json.dumps({k: result[k] for k in ('audio_base64', 'alignment', 'normalized_alignment') if k in result}))
    mp3 = ASSETS / (name + '.mp3')
    mp3.write_bytes(base64.b64decode(result['audio_base64']))
    wav = ASSETS / (name + '.wav')
    subprocess.run(['ffmpeg', '-y', '-v', 'error', '-i', str(mp3), '-ar', str(sr), '-ac', '1', str(wav)], check=True)
    audio, _ = sf.read(wav)
    speed = 1.0
    if len(audio) / sr > budget:
        sys.exit('Natural-speed speech exceeds this scene. Extend the scene; never accelerate the voice.')
    alignment = result.get('normalized_alignment') or result['alignment']
    chars = ''.join(alignment['characters'])
    starts = alignment['character_start_times_seconds']
    ends = alignment['character_end_times_seconds']
    masked = re.sub(r'\[[^\]]*\]', lambda m: ' ' * len(m[0]), chars)
    words = [{'text': m[0], 'start': round(starts[m.start()] / speed, 4), 'end': round(ends[m.end()-1] / speed, 4)} for m in re.finditer(r'\S+', masked)]
    clean = re.sub(r'\s+', ' ', re.sub(r'\[[^\]]*\]', '', tagged)).strip()
    assert len(words) == len(clean.split()), (name, 'Alignment word count mismatch')
    n = len(audio); offset = round(start * sr)
    # Smooth music duck, with a gentle lead-in and release.
    attack, release = int(.18 * sr), int(.3 * sr)
    duck = np.ones(len(mix))
    duck[offset-attack:offset] = np.linspace(1, .35, attack)
    duck[offset:offset+n] = .35
    duck[offset+n:offset+n+release] = np.linspace(.35, 1, release)
    mix *= duck[:, None]
    audio *= .46 / max(.01, float(np.max(np.abs(audio))))
    mix[offset:offset+n] += audio[:, None]
    timings.append({'start': start, 'duration': round(n/sr, 4), 'text': clean, 'taggedText': tagged, 'voice': VOICE, 'model': 'eleven_v3', 'file': wav.name, 'words': words})
    print(name, 'duration', round(n/sr, 3), 'words', len(words), flush=True)
sf.write(ASSETS / 'soundtrack.wav', mix, sr, subtype='PCM_24')
(ASSETS / 'audio-timing.json').write_text(json.dumps(timings, indent=2) + '\n')
(ASSETS / 'speech-timing.js').write_text('window.CADENCE_SPEECH_TIMING=' + json.dumps(timings) + ';\n')
def stamp(t):
    ms = round(t * 1000)
    return f'{ms//3600000:02}:{ms//60000%60:02}:{ms//1000%60:02},{ms%1000:03}'
(ROOT / 'captions.srt').write_text('\n'.join(f"{i}\n{stamp(c['start'])} --> {stamp(c['start']+c['duration'])}\n{c['text']}\n" for i,c in enumerate(timings,1)))
