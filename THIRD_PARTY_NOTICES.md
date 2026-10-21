# Third-party software

The application's own source code is MIT-licensed (see `LICENSE`). The built app
and the `.pkg` installer also **bundle two components under the GNU GPL v2**.
They run as separate programs (the app starts the filter as a child process and
exchanges data over pipes); they are not linked into the Swift code.

| Component | License | Source |
| --- | --- | --- |
| **splix** `rastertoqpdl` filter and `ml2160.ppd` (Samsung QPDL/SPL driver for CUPS) | GPL v2 | <https://github.com/valdikss/splix> at commit `c65904cddc49a06c4b2f5ccd5b82c31bd33d2872` |
| **JBIG-KIT** `libjbig85` (statically linked into `rastertoqpdl`) | GPL v2 | <https://www.cl.cam.ac.uk/~mgk25/jbigkit/> version 2.1 |

`scripts/build-splix.sh` downloads exactly these sources and rebuilds the filter,
so anyone can reproduce the binary that ships in the app.

The GPL v2 text is at <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>.
The binary distributed in releases is unmodified upstream code built with the
flags shown in `scripts/build-splix.sh`.

Samsung, ML-2160 and SyncThru are trademarks of their respective owners. This
project is independent and is not affiliated with or endorsed by Samsung or HP.
