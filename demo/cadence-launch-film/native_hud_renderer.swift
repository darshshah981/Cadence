// Offline capture harness; the build script compiles the actual Cadence HUDView.
@MainActor enum DemoClock {
    static var time: Double = 0
    static var hue: Double { max(0,time-19.15).truncatingRemainder(dividingBy:2.4)/2.4*360 }
}

@main struct NativeHUDRenderer {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let out = root.appendingPathComponent(".native-hud/frames")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories:true)
        let levels = try JSONDecoder().decode([[Double]].self, from:Data(contentsOf: root.appendingPathComponent("assets/voice-levels.json")))
        let model = HUDViewModel()
        model.reduceMotionProvider = { false }
        model.position = .bottomCenter
        model.apply(.logoIdle)
        model.applyApplicationPresentation(HUDApplicationPresentation(identity:nil, displayName:"Drafts", icon:NSImage(systemSymbolName:"doc.text.fill",accessibilityDescription:nil), iconSource:nil, kind:.knownApplication, presentationRevision:1,pinID:nil))
        var changedAt = 0.0
        let frames = args.contains("--sample") ? 2050 : 2760
        for f in 0..<frames {
            let t=Double(f)/60
            DemoClock.time=t
            let visual: HUDVisualState
            if t < 6.55 { visual = .idle }
            else if t < 11.15 { visual = .recording(triggerMode:.holdToTalk,showsHint:false) }
            else if t < 19.15 { visual = .recording(triggerMode:.tapToStartStop,showsHint:false) }
            else if t < 30.9 { visual = .scribeRecording }
            else if t < 34.0 { visual = .scribeTranscribing }
            else if t < 39.75 { visual = .scribed }
            else if t < 40.5 { visual = .inserting }
            else if t < 43 { visual = .success }
            else { visual = .idle }
            if visual != model.state.visualState {
                let prior=model.presentation, width=model.renderedWidth
                model.apply(HUDState(visualState:visual,subtitle:"",level:0,waveformLevels:levels[f],isVisible:true,showsSubtitle:false))
                model.beginMorph(from:prior,startWidth:width)
                changedAt=t
            } else {
                model.apply(HUDState(visualState:visual,subtitle:"",level:0,waveformLevels:levels[f],isVisible:true,showsSubtitle:false))
            }
            _ = model.advanceWaveform(deltaTime:1/60)
            let elapsed=t-changedAt
            if elapsed < model.motionTuning.pillResponse {
                model.setMorphProgress(HUDMotion.smoothProgress(elapsed:elapsed,duration:model.motionTuning.pillResponse),elapsed:elapsed)
            } else { model.finishMorph() }
            RunLoop.current.run(until:Date(timeIntervalSinceNow:0.001))
            guard (t >= 5.5 && t < 35.2) || (t >= 40 && t < 44) else { continue }
            if args.contains("--sample") && ![390,420,660,1200,1500,1890,2010,2040].contains(f) { continue }
            try autoreleasepool {
                let locked=t >= 11.15 && t < 30.9
                let content = ZStack {
                    HUDView(model:model)
                        .frame(width:model.renderedWidth,height:44)
                    HUDLockIndicatorView()
                        .opacity(locked ? HUDMotion.smoothProgress(elapsed:t-11.15,duration:0.2) : 0)
                        .offset(x:model.renderedWidth/2+5+16)
                }
                .frame(width:300,height:60)
                .environment(\.colorScheme,.light)
                .id(f)
                .transaction { $0.animation=nil; $0.disablesAnimations=true }
                let renderer=ImageRenderer(content:content)
                renderer.scale=3
                _ = renderer.cgImage
                RunLoop.current.run(until:Date(timeIntervalSinceNow:0.002))
                guard let image=renderer.cgImage else { fatalError("Native HUD frame unavailable") }
                let rep=NSBitmapImageRep(cgImage:image)
                guard let png=rep.representation(using:.png,properties:[:]) else { fatalError("PNG unavailable") }
                try png.write(to:out.appendingPathComponent(String(format:"%04d.png",f)))
            }
            if f % 300 == 0 { print("Native HUD frame \(f)") }
        }
    }
}
