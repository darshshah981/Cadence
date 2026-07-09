# Choose the product thesis and release shape

Type: grilling
Status: resolved
Blocked by:
Parent: ../map.md

## Question

What product thesis should govern the seven-feature effort, and what release shape should it imply?

Resolve whether the effort is best framed as one named reliability-and-trust release, a phased roadmap, or separate feature tracks. The answer should decide the ordering relationship between Crash-First Meeting Ledger, Meeting Runway, Private AI Notepad, Editable Speaker Ledger, Trust You Can Inspect, Final Pass as Challenge, and Capture Rehearsal.

## Comments

## Answer

Cadence's next product effort should be framed as a reliability-and-trust release, not as seven independent feature tracks.

The governing thesis is: **Cadence is the private native meeting recorder you can trust before you admire.** Crash-First Meeting Ledger is the core of that release because every higher-order feature depends on the user's belief that Cadence will not lose a real meeting. Meeting Runway, Trust You Can Inspect, Final Pass as Challenge, and Capture Rehearsal should support that trust spine rather than compete with it.

Release shape:

1. **Foundation:** Crash-First Meeting Ledger and Final Pass as Challenge, Not Replacement. These define the core reliability promise and make capture/finalization state legible.
2. **Operational UX:** Meeting Runway and Trust You Can Inspect. These make the reliable core usable in the moments before, during, and after meetings.
3. **Activation Proof:** Capture Rehearsal. This gives first-run users a private way to prove permissions and capture quality before trusting Cadence in a real call.
4. **Post-foundation intelligence:** Private AI Notepad and Editable Speaker Ledger. These remain part of the overall direction, but should follow once the recording/finalization foundation is trustworthy enough that note intelligence has solid ground.

Implication for later tickets: treat reliability, recovery, and visible trust as release-blocking. Treat note intelligence and speaker attribution as staged follow-on contracts unless a later ticket proves a small slice must ship with the foundation.
