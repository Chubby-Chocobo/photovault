# RAW header fixtures

The first 64 KiB of public sample files from [raw.pixls.us](https://raw.pixls.us/), whose contributors release them into the public domain (CC0). Each prefix holds the TIFF directories with the camera make and model.

| File | Source on raw.pixls.us |
|---|---|
| `sony-ilce-7rm5.ARW` | Sony / ILCE-7RM5, `7RM5-LosslessCompressedLarge.ARW` |
| `nikon-z9-lossless.NEF` | Nikon / Z 9, `Nikon - NIKON Z 9 - 14bit compressed (Lossless).NEF` |
| `nikon-coolpix-p7800.NRW` | Nikon / Coolpix P7800, `DSCN2039.NRW` |
| `pentax-k-r.PEF` | PENTAX / PENTAX K-r, `IMGP4424.PEF` |
| `samsung-nx1.SRW` | Samsung / NX1, `2016-07-23-142101_sam_9364.srw` |

These formats lose their camera when ImageIO guesses the type itself (it reads them as plain TIFF or not at all), so they guard the UTI hint in `HeaderClassifier` and `ImageIOMetadataReader`.
