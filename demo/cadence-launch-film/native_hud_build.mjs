// Compile the production HUD view and motion model into an offline frame renderer.
// Source files in Cadence/ are read-only. No app installation, mic, or user defaults.
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
const root=path.resolve(import.meta.dirname,'../..');
const build=path.join(import.meta.dirname,'.native-hud');
fs.mkdirSync(build,{recursive:true});
const manifest=[];
function read(relative){const s=fs.readFileSync(path.join(root,relative),'utf8');manifest.push({path:relative,sha256:createHash('sha256').update(s).digest('hex')});return s;}
function declaration(source,name){
 const re=new RegExp('(?:enum|struct|final class|extension) '+name.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+'(?:[ :<{])');
 const m=re.exec(source);if(!m)throw Error('Missing '+name);
 let i=source.indexOf('{',m.index),depth=1,j=i+1;
 for(;j<source.length&&depth;j++){if(source[j]==='{')depth++;if(source[j]==='}')depth--;}
 return source.slice(m.index,j);
}
const models=read('Cadence/Models/DictationModels.swift');
const controller=read('Cadence/Services/HUDWindowController.swift');
const theme=read('Cadence/UI/CadenceDesignSystem.swift');
const resolver=read('Cadence/Services/ApplicationIconResolver.swift');
let view=read('Cadence/UI/HUDView.swift');
// The capture clock replaces wall-clock sampling only; shapes, layout, colors,
// text, waveform Canvas, easing, status cross-fades and lock view stay native.
view=view.replace('context.date.timeIntervalSinceReferenceDate','DemoClock.time');
view=view.replaceAll('.degrees(scribeHueRotation)', '.degrees(DemoClock.hue)')
 .replaceAll('.degrees(scribeHueRotation + 360)', '.degrees(DemoClock.hue + 360)');
// ImageRenderer has no live display loop. Disable the live repeating driver;
// the same 2.4-second rotation is sampled explicitly by DemoClock above.
view=view.replace(/private func startScribeHueIfNeeded\(\) \{[\s\S]*?\n    \}\n\n    private enum StatusIcon/, 'private func startScribeHueIfNeeded() {}\n\n    private enum StatusIcon');
// NSViewRepresentable's invisible pointer hit-target has no raster equivalent.
// ImageRenderer substitutes a prohibited sign for it; exclude only that target.
view=view.replace('HUDLogoInteractionSurface(model: model)', 'Color.clear');
const parts=['import AppKit\nimport SwiftUI\nimport Foundation'];
for(const n of ['DictationTriggerMode','HUDVisualState','HUDMetrics','HUDContentSizing','HUDMotionTuning','HUDMotion','HUDActiveContentTransition','HUDApplicationCueTransition','HUDCornerRadii','HUDPosition','HUDState','HUDHideDuration'])parts.push(declaration(models,n));
for(const n of ['HUDWaveformSmoother','HUDLogoInteractionEvent','HUDLogoPointerTracker','DictionaryFeedback','HUDPresentation','HUDViewModel'])parts.push((n==='HUDViewModel'?'@MainActor\n':'')+declaration(controller,n));
for(const n of ['FlowTheme','CadenceIconography','HUDChromeStyle','Color','NSColor'])parts.push(declaration(theme,n));
parts.push('struct ApplicationProcessIdentity {}',declaration(resolver,'ApplicationIconSource'),'@MainActor\n'+declaration(resolver,'HUDApplicationPresentation'));
// The expanded tray is not used in this film. Its IO actions are not linked.
parts.push('struct IdleExpandedTray: View { let model: HUDViewModel; var body: some View { EmptyView() } }',view);
parts.push(fs.readFileSync(path.join(import.meta.dirname,'native_hud_renderer.swift'),'utf8'));
fs.writeFileSync(path.join(build,'NativeHUD.swift'),parts.join('\n\n'));
fs.writeFileSync(path.join(import.meta.dirname,'assets/native-hud-provenance.json'),JSON.stringify({sources:manifest,clock:'Deterministic 60 fps; spinner 0.9 s; Compose border 2.4 s',omitted:'Unused expanded tray and IO only'},null,2));
const r=spawnSync('swiftc',['-parse-as-library','-swift-version','5','-O','-o',path.join(build,'render'),path.join(build,'NativeHUD.swift')],{encoding:'utf8'});
process.stdout.write(r.stdout);process.stderr.write(r.stderr);process.exit(r.status||0);
