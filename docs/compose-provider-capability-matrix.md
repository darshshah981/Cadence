# Compose provider capability matrix

Status: development evidence, not a release or model-quality certification. This matrix records Cadence's dispatch contract and the evidence available on September 30, 2026. Recheck it after a provider model, prompt, operating system, or capability-profile change.

| Provider choice | Compiled input Cadence may dispatch | Current task gates | Local readiness and recovery | Quality evidence |
| --- | --- | --- | --- | --- |
| Apple Intelligence | Text only; at most 12 KiB of compiled UTF-8 text | Direct draft, local draft refinement, selected-text rewrite | Requires macOS 26+, an eligible Mac, Apple Intelligence enabled, and a ready model. Cadence gives separate recovery for unsupported device, disabled setting, model download, other unavailability, and unsupported OS. | U2 and U3 on-device corpora contain exposed failures and repairs. Short everyday drafting is useful, but meaning-preservation and instruction quality are **not certified**. |
| DeepSeek, OpenAI Direct, OpenRouter, Advanced | Text only; at most 64 KiB of compiled UTF-8 text | Direct draft only under the pinned default profile | Selected and consented cloud configuration requires current credential/receipt checks. A local failure does not switch to cloud. | Compatibility and policy tests do not certify writing quality. Provider/model-specific quality remains **not evaluated** in the capability profile. |

The byte ceilings are conservative Cadence limits, not claims about any model's token context window. Every default profile declares its provider context capacity unknown and quality status not evaluated. The capability policy rejects unsupported modality, unsupported task, and oversized compiled requests before provider dispatch. Provider-safe input is text-only; a screenshot cannot enter these adapters through this contract. A selected-text rewrite is local-only under the current default profile. No profile automatically routes to a different provider.

Verification map:

- Fresh-install on-device selection and cloud-choice preservation: `ScribeMigrationTests` and `ScribeProviderControllerV2Tests.selectingOnDeviceNeedsNoKeyAndRetainsSavedCloudConfiguration`.
- Local availability at readiness, action acquisition, and dispatch: `ScribeProviderControllerV2Tests.localAvailabilityIsRecheckedBeforeReadinessAcquisitionAndDispatch`. The six platform-state classifications and distinct user recovery messages: `OnDeviceScribeGenerationTests.availabilityStatesGiveDistinctRecoveryAndOnlyReadyHasNoError`.
- Provider identity, removal, and consent revocation before dispatch: `ScribeProviderControllerV2Tests.dispatchAuthorizationRequiresExactCurrentIdentityAndAuthoritativeConsent` and `ScribeCoordinatorTests.v2ControllerRevocationBetweenSnapshotAndDispatchMakesZeroTransportRequests`.
- Text-only/task/budget contracts: `ScribeProviderCapabilityPolicyTests`, plus `ScribeCoordinatorTests.oversizedRequestRetainsSpeechAndNeverDispatchesOrFlashesGenerating` and `ScribeCoordinatorTests.actionCapabilityOverrideBlocksBeforeProviderDispatch`.
- The production on-device evaluation runner records the OS version/build, request and generator hashes, model execution counts, sampling, and timing in each run manifest. The September 30 meaning runs used macOS 26.6.2 (25G83). Their repaired corpora are exposed development evidence, not fresh independent passes.

Still required for U4 certification: a current provider/model-specific writing-quality matrix; independent on-device meaning and instruction reserves after the latest repairs; a live readiness transition check on an actual download/enablement change; and reconciliation into the primary checkout followed by an installed-app check. Nothing in this document grants consent for cloud egress or declares a paid provider preferable for a complex-looking request.
