# Greyscale (1-channel) YOLOX for the byai camera

The camera's ISP emits NV12.  A 3-channel model forces a colour-convert stage
in the pipeline, an interleaved-RGB build in the app, AND a 1.2 MB HWC->CHW
deinterleave inside the PAL on every inference.  A 1-channel model removes all
three: the ISP's Y plane IS the tensor.

Measured on cam3, 640x640, per inference:

    stage      3-channel   1-channel
    pack         1634 us      185 us
    run         74722 us    34477 us
    serial      76929 us    35164 us     -54%

`run` halves because the tensor is a third the size AND the PAL's deinterleave
disappears (one plane is already NCHW).  34.5 ms is essentially the C7x compute
itself (32-38 ms), so the ARM-side overhead is now nearly gone.

## How the model is made

The collapse is EXACT, not an approximation: with R=G=B=Y,
`sum_c conv(W[:,c], Y) == conv(sum_c W[:,c], Y)`.  The stem's preproc bias is 0
and scale is 1, so nothing else has to be folded.

    1. input [1,3,H,W] -> [1,1,H,W]; TIDL_preProc_Bias/Scale -> 1 channel
    2. Conv_0 weights [12,3,3,3] -> [12,1,3,3] by summing over axis 1
    3. clear graph.value_info and re-run shape inference
       (stale 3-channel shapes confuse TIDL's partitioner)
    4. recompile artifacts with TI's OWN recipe from the model's config.yaml

Verified numerically against the original fed grey-replicated RGB: max abs
difference 0.000359 (float rounding).

## Two traps, both cost hours

**Use TI's compile recipe, not defaults.**  Without
`object_detection:meta_arch_type: 6` and `meta_layers_names_list` (the model's
own .prototxt), TIDL cannot absorb the YOLOX head and the graph fragments into
5-6 subgraphs instead of 1 -- i.e. it bounces to the ARM mid-network.  Copy the
options out of the model's `config.yaml`.

**The tidl-tools version must match the TARGET runtime.**  The first 4 bytes of
`subgraph_0_tidl_net.bin` are a version DATE.  The board (vision-apps 11.0.0)
wants `0x20250429`; tidl-tools `11_00_08_00` emits `0x20250630`, and the
runtime rejects it at load with:

    ort: Create state function failed. Return value:-1

which looks exactly like the documented dirty-DSP state and survives a reboot.
Compare the stamps before blaming the hardware:

    xxd -l 4 -e -g4 artifacts/subgraph_0_tidl_net.bin

Use `https://software-dl.ti.com/jacinto7/esd/tidl-tools/11_00_00_00/` for this
board.

## What is NOT free

Colour is gone.  On the reference frame the detector still finds the aeroplane
(4 boxes @ 0.813 vs 3 @ 0.849 in RGB), but colour is a real cue for some COCO
classes and real-scene accuracy against RGB has NOT been measured.

One 230 KB memcpy remains, to corner-pad 640x360 into the 640x640 tensor.
Removing it needs the model input to match the ISP output exactly; 640x352 was
tried and YOLOX's head has grid constants baked for 640x640
(`Mul_333: Incompatible dimensions`), so that needs a re-export from the
training repo, not ONNX surgery.
