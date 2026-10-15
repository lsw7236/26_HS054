# Models

This directory contains model configuration and conversion tools for SmartCane.

## Current Model

YOLOv8 Nano

Model file:

yolov8n.pt

Expected path:

models/yolov8n.pt

## NCNN

For Raspberry Pi optimization, the YOLO model can be exported to NCNN format.

Run:

python models/export_ncnn.py

## Note

Model files such as `.pt`, `.onnx`, and `.tflite` are excluded from GitHub.
