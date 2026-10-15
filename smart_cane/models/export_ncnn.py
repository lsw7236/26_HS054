from ultralytics import YOLO


MODEL_PATH = "models/yolov8n.pt"


def main():

    print("Loading YOLO model...")

    model = YOLO(
        MODEL_PATH
    )

    print("Exporting model to NCNN...")

    model.export(
        format="ncnn",
        imgsz=640
    )

    print("NCNN export complete.")


if __name__ == "__main__":
    main()