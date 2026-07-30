# Third-party notices

## llama.cpp

RelayCode uses the official `llama.cpp` XCFramework to execute downloaded GGUF
language models directly on Apple devices without a network inference service.

- Project: <https://github.com/ggml-org/llama.cpp>
- Release: `b10182`
- Commit: `afeebe103bd99cda8f5dfaefcabadf890db7fda7`
- License: MIT

The complete license text is bundled as
`OnDeviceModel/llama-cpp-license.txt`.

## Qwen2.5-Coder-0.5B-Instruct-GGUF

RelayCode can download the Q4_0 GGUF artifact from Qwen's official repository
after an explicit user action. The model is not included in the app binary.

- Project: <https://huggingface.co/Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF>
- Revision: `ebb2015119c907b064c512bf053e945850b5875f`
- Artifact SHA-256:
  `9739055e046d62a937e5b7879012209ef40ebea8a1569a96028de491f3f091d5`
- License: Apache-2.0

The complete model license text is bundled as
`OnDeviceModel/qwen-model-license.txt`.

## mini-rv32ima

RelayCode's optional on-device Linux runtime uses the `mini-rv32ima`
interpreter by Charles Lohr, pinned to commit
`84858f58cb41899705e2ff2d6ee3b2d5c0795bfe`.

- Source: https://github.com/cnlohr/mini-rv32ima
- License: MIT

Copyright (c) 2022 CNLohr

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Linux and Buildroot guest image

The optional guest image is the unmodified
`linux-6.1.14-rv32nommu-cnl-1.zip` artifact from
`cnlohr/mini-rv32ima-images`, pinned to repository commit
`25fb23e7635c485c08de4437e91f15b8e1805770`.

- Image source and license: https://github.com/cnlohr/mini-rv32ima-images
- Linux 6.1.14 build configuration: https://github.com/cnlohr/mini-rv32ima/tree/c3900613b11ce886e9f01eadb0f6230d04983eb2/configs
- Linux source: https://kernel.org/
- Buildroot source: https://buildroot.org/
- BusyBox source: https://busybox.net/

The guest is a separate program interpreted by RelayCode. Its GPL license does
not replace RelayCode's Apache-2.0 license. Redistributors must preserve the
guest's license and corresponding-source availability. Before distributing an
App Store binary, archive the exact corresponding source used for the guest
alongside the release rather than relying only on moving upstream links.
