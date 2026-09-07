# Continuous speech regression

`continuous-speech.wav` is locally generated speech (macOS `say`), converted to 16 kHz mono through LokalBot's `AudioPreviewTee` and stored as 16-bit PCM. It contains no meeting or personal audio.

Text: “During this meeting we need to review the release schedule and confirm who will handle the remaining work. The audio preview should continue displaying what the speaker says, even when the sentence is long and the volume remains fairly steady. After the discussion we will write down the decisions and assign each follow up action to the right person.”

The previous per-chunk 20th-percentile RMS gate rejected both processable chunks. This fixture guards against using a sustained speech level as a noise-floor estimate.
