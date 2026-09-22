# Iteration 29: isolated Android call-audio allocation investigation

The native HFP attempt recorded in iteration 28 reached Answer and requested Mac audio, then returned `kIOReturnUnsupported`. A separate Android prototype now supports explicit mode-3 construction while preserving the original PSTN path and verified shell bootstrap. It creates and releases endpoints only; it does not capture, inject, transmit or play audio, and is not integrated into Plink.

Offline compilation and all **65 helper tests** passed: 43 original plus 22 independent mode-3 cases. The required product regression gate also passed **582 tests** on unchanged production source. These are separate results; neither establishes working call audio.

No live allocation was attempted. Source review found factory failures can leave resources inaccessible to the caller, and release requests asynchronous policy removal. The reviewed server registration path also has a failure before Binder-death cleanup is established. Its policy dump lacks sufficient process ownership to prove complete probe cleanup. Live testing remains blocked on that limitation and Pixel availability; no permission, call, audio-route or phone-setting changes were made.

The source review is pinned to [AOSP AudioService](https://android.googlesource.com/platform/frameworks/base/+/1cdfff555f4a21f71ccc978290e2e212e2f8b168/services/core/java/com/android/server/audio/AudioService.java), with factory behavior documented in the local source-contract artifact. The exact tested source is archived; its temporary extraction and compiled outputs were removed. Iteration 28 remains the latest production change and has not yet been installed on the physical devices.
