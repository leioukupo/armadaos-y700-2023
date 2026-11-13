# Audio Topology

Source files for Armada's Qualcomm AudioReach topology blobs.

Only the generated topology blobs under the following directories are copied
into the firmware image; the `.m4` sources remain in this directory.

```text
system_files/usr/lib/firmware/qcom/sm8750/
system_files/usr/lib/firmware/qcom/sm8650/
```

The TB710FU topology is derived from audioreach-topology (BSD-3-Clause,
Linaro). Its notice is `sm8650/LICENSE`, and the same file is installed next
to the blob as `qcom/sm8650/LICENSE.audioreach-topology`.

To regenerate a topology using [audioreach-topology](https://git.codelinaro.org/linaro/qcomlt/audioreach-topology):

```sh
m4 -I <audioreach-topology> sm8750/SM8750-AYN.m4 > SM8750-AYN.conf
alsatplg -c SM8750-AYN.conf -o SM8750-AYN-tplg.bin
```

Run the commands from this directory: `sm8650/Lenovo-TB710FU.m4` also includes
the local `sm8650/` TDM templates (audioreach-topology has none for TDM).

```sh
m4 -I . -I <audioreach-topology> sm8650/Lenovo-TB710FU.m4 > Lenovo-TB710FU.conf
alsatplg -c Lenovo-TB710FU.conf -o Lenovo-TB710FU-tplg.bin
```

The TB320FC (SM8475) topology is `sm8475/Lenovo-Y700.m4`: two MultiMedia1
stream subgraphs plus one I2S device subgraph on `PRIMARY_MI2S_RX`, which is
what the two CS35L45 amplifiers hang off. Generate and install it as

```sh
m4 -I <audioreach-topology> sm8475/Lenovo-Y700.m4 > Lenovo-Y700.conf
alsatplg -c Lenovo-Y700.conf -o Lenovo-Y700-tplg.bin
```

The blob lands in `system_files/usr/lib/firmware/qcom/sm8475/`, because the
machine driver sets `card->driver_name = "sm8475"` and AudioReach loads
`qcom/<driver_name>/<card_name>-tplg.bin` - here `Lenovo-Y700-tplg.bin`. It was
generated with audioreach-topology `993a17dcb672357998a463a73f120064d6c74f4f`
and alsa-topology-utils 1.2.16; the speaker enable/volume sequence that the
blob alone does not cover lives in `system_files/usr/share/alsa/ucm2/Lenovo/Y700/`.

The TB710FU blob was generated with audioreach-topology
`1d4c4e337df6bad4d52c4f7b3e15fff3f485be62` and alsa-topology-utils 1.2.16.

Replace the corresponding `-tplg.bin` in `system_files` after regeneration.
