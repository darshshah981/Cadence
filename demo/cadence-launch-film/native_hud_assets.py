"""Prepare fictional voice envelopes, then pack native RGBA captures into atlases."""
from pathlib import Path
import json, sys
import numpy as np
import soundfile as sf
from PIL import Image

ROOT=Path(__file__).resolve().parent
ASSETS=ROOT/'assets'
if '--pack' not in sys.argv:
    speech=np.zeros(52*48000)
    for clip in json.loads((ASSETS/'audio-timing.json').read_text()):
        audio,sr=sf.read(ASSETS/clip['file'])
        assert sr==48000
        offset=round(clip['start']*sr)
        speech[offset:offset+len(audio)]=audio
    levels=[]
    history=[0.0]*16
    for f in range(52*60):
        end=round(f/60*48000)
        window=np.abs(speech[max(0,end-800):end])
        # DictationCoordinator.waveformLevel's average/peak envelope and gain;
        # replay one generated-audio chunk per frame at the default sensitivity.
        envelope=(np.sqrt(np.mean(window))*.82+np.sqrt(np.max(window))*.18) if len(window) else 0
        level=min(1,float(envelope)*4.0)
        history=history[1:]+[level]
        levels.append([round(v,5) for v in history])
    (ASSETS/'voice-levels.json').write_text(json.dumps(levels))
    print('Prepared voice-only envelopes, 3120 frames')
else:
    frames=sorted((ROOT/'.native-hud/frames').glob('*.png'))
    mapping={}
    for batch in range(0,len(frames),64):
        atlas=Image.new('RGBA',(900*8,180*8))
        filename=f'native-hud-{batch//64:02}.webp'
        for i,p in enumerate(frames[batch:batch+64]):
            x,y=(i%8)*900,(i//8)*180
            im=Image.open(p)
            assert im.size==(900,180)
            atlas.paste(im,(x,y))
            mapping[int(p.stem)]={'asset':filename,'x':x,'y':y}
        atlas.save(ASSETS/filename,lossless=True,method=4)
    (ASSETS/'native-hud-frames.js').write_text('window.CADENCE_NATIVE_HUD='+json.dumps(mapping)+';\n')
    print('Packed',len(frames),'native frames into',(len(frames)+63)//64,'atlases')
