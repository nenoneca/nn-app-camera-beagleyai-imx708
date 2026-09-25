#!/bin/bash
mkdir -p /run/nn-inferd
cd /opt/nn/inferd
exec python3 nn_inferd.py --socket /run/nn-inferd/sock \
  --tidl-model /opt/model_zoo/ONR-OD-8220-yolox-s-lite-mmdet-coco-640x640 \
  --tidl-parallel 1
