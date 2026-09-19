"""Generate original sound design and mix local synthetic demo speech.

Run with --music-only while the optional Kokoro model downloads, then without
the flag for the final voice mix. No microphone, personal audio, or API calls.
"""
from pathlib import Path
import json
import sys
import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parent
ASSETS = ROOT / "assets"
SR = 48000
DURATION = 52
mix = np.zeros((SR * DURATION, 2), dtype=np.float64)

def add(audio, start, gain=1, pan=0):
    offset = round(start * SR)
    n = min(len(audio), len(mix) - offset)
    if n <= 0:
        return
    if audio.ndim == 1:
        stereo = np.column_stack((audio * np.sqrt((1-pan)/2), audio * np.sqrt((1+pan)/2)))
    else:
        stereo = audio
    mix[offset:offset+n] += stereo[:n] * gain

def note(freq, length=2.7, softness=1):
    t = np.arange(int(SR * length)) / SR
    env = (1-np.exp(-t*75))*np.exp(-t*2.6/softness)
    return env*(np.sin(2*np.pi*freq*t)+.22*np.sin(2*np.pi*freq*2*t)+.06*np.sin(2*np.pi*freq*3*t))

# Original, restrained major-ninth arpeggio; no stock music.
chords = [[48,55,59,62,64], [45,52,55,59,60], [41,48,52,55,57], [43,50,53,57,60]]
for beat in range(78):
    start = beat * 2/3
    chord = chords[(beat//12) % 4]
    midi = chord[[0,2,3,1,4,2][beat%6]] + 12
    freq = 440*2**((midi-69)/12)
    add(note(freq), start, .038, .22 if beat%2 else -.22)
    if beat%6 == 0:
        add(note(freq/2,4,2), start, .034)

# Soft interface ticks and a completion chord.
for start in [6.55,11.15,19.0,39.75]:
    add(note(920,.11,.18),start,.045)
for midi in [72,76,79]:
    add(note(440*2**((midi-69)/12),1.8,1.3),41.3+(midi-72)*.018,.039)

speech = [
    (0.65,4.05,"A thought becomes words. Words become a draft.","bf_emma","intro"),
    (7.05,1.15,"Quick update.","af_heart","dictation-a"),
    (8.25,1.85,"The new website is ready.","af_heart","dictation-b"),
    (10.15,1.7,"Let's launch on Friday,","af_heart","dictation-c"),
    (11.90,3.65,"and share a preview with the team tomorrow.","af_heart","dictation-d"),
    (17.45,4.2,"Keep talking. Press Command to compose.","bf_emma","switch"),
    (24.05,2.55,"Make that a short team update.","af_heart","instruction-a"),
    (26.65,1.18,"Keep it warm,","af_heart","instruction-b"),
    (27.90,2.65,"and finish with a clear next step.","af_heart","instruction-c"),
    (33.2,4.8,"The direction shapes the draft. Only the message goes in.","bf_emma","result"),
    (41.5,3.0,"Review it. Insert it. Keep moving.","bf_emma","insert"),
    (47.05,3.75,"Cadence. Your next draft starts with your voice.","bf_emma","outro"),
]
timings=[]
if "--music-only" not in sys.argv:
    from kokoro_onnx import Kokoro
    cache = Path.home()/".cache/hyperframes/tts"
    kokoro = Kokoro(str(cache/"models/kokoro-v1.0.onnx"),str(cache/"voices/voices-v1.0.bin"))
    for start,budget,text,voice,name in speech:
        target = ASSETS/(name+".wav")
        if target.exists():
            audio,sr=sf.read(target)
        else:
            audio,sr=kokoro.create(text,voice=voice,speed=1.04,lang="en-gb" if voice.startswith('b') else 'en-us')
            duration=len(audio)/sr
            if duration>budget:
                audio,sr=kokoro.create(text,voice=voice,speed=1.04*duration/budget*1.02,lang="en-gb" if voice.startswith('b') else 'en-us')
            sf.write(target,audio,sr)
        resampled=np.interp(np.arange(round(len(audio)*SR/sr))*sr/SR,np.arange(len(audio)),audio)
        # Duck the original music around each spoken phrase.
        offset=round(start*SR);n=min(len(resampled),len(mix)-offset)
        mix[offset:offset+n]*=.40
        peak=max(.01,float(np.max(np.abs(resampled))))
        add(resampled,start,.60/peak)
        timings.append({"start":start,"duration":round(len(audio)/sr,3),"text":text,"voice":voice,"file":target.name})
        print(name,round(len(audio)/sr,2),flush=True)

envelope=np.minimum(1,np.arange(len(mix))/SR/.8)*np.minimum(1,(len(mix)-1-np.arange(len(mix)))/SR/1.1)
mix*=envelope[:,None]
mix=np.tanh(mix*1.03)
sf.write(ASSETS/"soundtrack.wav",mix,SR,subtype="PCM_24")
(ASSETS/"audio-timing.json").write_text(json.dumps(timings,indent=2)+"\n")
(ASSETS/"speech-timing.js").write_text("window.CADENCE_SPEECH_TIMING="+json.dumps(timings)+";\n")
def stamp(seconds):
    ms=round(seconds*1000)
    return f"{ms//3600000:02}:{ms//60000%60:02}:{ms//1000%60:02},{ms%1000:03}"
captions=[]
for i,clip in enumerate(timings,1):
    captions.append(f"{i}\n{stamp(clip['start'])} --> {stamp(clip['start']+clip['duration'])}\n{clip['text']}\n")
(ROOT/"captions.srt").write_text("\n".join(captions))
print("soundtrack.wav",DURATION,"seconds",flush=True)
