# Third-Party Notices

First-party code is licensed under the MIT License in [LICENSE](LICENSE). The components below retain their own licenses.

## MicroTeX-derived layout rules

- **Paths:** `vendor/ztex/src/layout/layout.zig`; `vendor/ztex/src/layout/metrics.zig`
- **License:** MIT
- **Copyright holder:** Copyright (c) 2020 Nano Michael
- **Upstream:** [NanoMichael/MicroTeX](https://github.com/NanoMichael/MicroTeX) ([license](https://raw.githubusercontent.com/NanoMichael/MicroTeX/master/LICENSE))

The following MIT notice applies to the MicroTeX-derived material:

```text
The MIT License (MIT)

Copyright (c) 2020 Nano Michael

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
```

## ZigZag

- **Paths:** `vendor/skript/third_party/zigzag/`; `vendor/skript/build.zig.zon`
- **License:** MIT (the vendored copy of the license is at `vendor/skript/third_party/zigzag/LICENSE`)
- **Copyright holder:** Copyright (c) 2026 Matthew Meszaros
- **Upstream:** [meszmate/zigzag](https://github.com/meszmate/zigzag), pinned at commit `226dd3f` (version 0.1.2)

## Latin Modern Math and Latin Modern Roman fonts

- **Paths:** `vendor/ztex/src/fonts/lmmath.zig`; `vendor/ztex/src/fonts/lmmath/part0.zig` through `part4.zig`; `vendor/ztex/src/fonts/lmroman_regular.zig`; `vendor/ztex/src/fonts/lmroman_italic.zig`; `src/lambda_fixture.zig` (the extracted U+03BB outline)
- **License:** GUST Font License v1.0, legally equivalent to the LaTeX Project Public License (LPPL) version 1.3c or later. The GUST clause below requests, but does not legally require, renaming font names and files in derived works. Naming details and the exception for the embedded font data are recorded in [MANIFEST-notui-fonts.txt](MANIFEST-notui-fonts.txt).
- **Copyright holders:** Latin Modern Math: B. Jackowski, P. Strzelczyk, and P. Pianowski, on behalf of TeX Users Groups. Latin Modern Roman: B. Jackowski and J. M. Nowacki, on behalf of TeX Users Groups.
- **Upstream:** [Latin Modern Math](https://www.gust.org.pl/projects/e-foundry/lm-math); [Latin Modern](https://www.gust.org.pl/projects/e-foundry/latin-modern); [GUST Font License](https://www.gust.org.pl/projects/e-foundry/licenses/GUST-FONT-LICENSE.txt); [LPPL](https://www.latex-project.org/lppl.txt)

The following is the GUST Font License v1.0 text. The LPPL text is available at the linked upstream URL.

```text
% This is version 1.0, dated 22 June 2009, of the GUST Font License.
% (GUST is the Polish TeX Users Group, https://www.gust.org.pl)
%
% For the most recent version of this license see
% https://www.gust.org.pl/fonts/licenses/GUST-FONT-LICENSE.txt
% or
% https://tug.org/fonts/licenses/GUST-FONT-LICENSE.txt
%
% This work may be distributed and/or modified under the conditions
% of the LaTeX Project Public License, either version 1.3c of this
% license or (at your option) any later version.
%
% Please also observe the following clause:
% 1) it is requested, but not legally required, that derived works be
%    distributed only after changing the names of the fonts comprising
%    this work and given in an accompanying "manifest", and that the
%    files comprising the Work, as listed in the manifest, also be given
%    new names. Any exceptions to this request are also given in the
%    manifest.
%
%    We recommend the manifest be given in a separate file named
%    MANIFEST-<fontid>.txt, where <fontid> is some unique identification
%    of the font family. If a separate "readme" file accompanies the Work,
%    we recommend a name of the form README-<fontid>.txt.
%
% The latest version of the LaTeX Project Public License is in
% https://www.latex-project.org/lppl.txt and version 1.3c or later
% is part of all distributions of LaTeX version 2006/05/20 or later.
```
