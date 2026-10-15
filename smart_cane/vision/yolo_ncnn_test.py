#!/usr/bin/env python3

import time
import cv2

from picamera2 import Picamera2
from ultralytics import YOLO

from models.model_config import (
    YOLO_MODEL_PATH,
    CONFIDENCE_THRESHOLD,
    INPUT_WIDTH,
    INPUT_HEIGHT,
    MODEL_TASK,
)


# =========================================================
# Camera settings
# =========================================================

CAMERA_WIDTH = 640
CAMERA_HEIGHT = 480

MODEL_WIDTH = INPUT_WIDTH
MODEL_HEIGHT = INPUT_HEIGHT


# =========================================================
# Letterbox
# =========================================================

def letterbox(
    image,
    new_size=(640, 640),
    color=(114, 114, 114)
):
    original_h, original_w = image.shape[:2]

    target_w, target_h = new_size

    scale = min(
        target_w / original_w,
        target_h / original_h
    )

    resized_w = int(
        round(
            original_w * scale
        )
    )

    resized_h = int(
        round(
            original_h * scale
        )
    )

    resized = cv2.resize(
        image,
        (
            resized_w,
            resized_h
        ),
        interpolation=cv2.INTER_LINEAR
    )

    pad_w = (
        target_w
        - resized_w
    )

    pad_h = (
        target_h
        - resized_h
    )

    pad_left = (
        pad_w // 2
    )

    pad_right = (
        pad_w
        - pad_left
    )

    pad_top = (
        pad_h // 2
    )

    pad_bottom = (
        pad_h
        - pad_top
    )

    return cv2.copyMakeBorder(
        resized,
        pad_top,
        pad_bottom,
        pad_left,
        pad_right,
        cv2.BORDER_CONSTANT,
        value=color
    )


# =========================================================
# Draw 3x3 grid
# =========================================================

def draw_grid(image):

    h, w = image.shape[:2]

    x1 = w // 3
    x2 = (w * 2) // 3

    y1 = h // 3
    y2 = (h * 2) // 3

    cv2.line(
        image,
        (x1, 0),
        (x1, h),
        (255, 255, 255),
        2
    )

    cv2.line(
        image,
        (x2, 0),
        (x2, h),
        (255, 255, 255),
        2
    )

    cv2.line(
        image,
        (0, y1),
        (w, y1),
        (255, 255, 255),
        2
    )

    cv2.line(
        image,
        (0, y2),
        (w, y2),
        (255, 255, 255),
        2
    )


# =========================================================
# Main
# =========================================================

def main():

    print("Loading YOLO model...")

    model = YOLO(
        YOLO_MODEL_PATH,
        task=MODEL_TASK
    )

    print(
        "YOLO model loaded:",
        YOLO_MODEL_PATH
    )

    print("Starting camera...")

    picam2 = Picamera2()

    camera_config = (
        picam2.create_preview_configuration(
            main={
                "size": (
                    CAMERA_WIDTH,
                    CAMERA_HEIGHT
                ),
                "format": "RGB888"
            }
        )
    )

    picam2.configure(
        camera_config
    )

    picam2.start()

    time.sleep(1)

    print("Camera ready")
    print(
        "Confidence threshold:",
        CONFIDENCE_THRESHOLD
    )
    print("Press Q to quit.")

    try:

        while True:

            frame = picam2.capture_array()

            boxed = letterbox(
                frame,
                new_size=(
                    MODEL_WIDTH,
                    MODEL_HEIGHT
                )
            )

            results = model(
                boxed,
                imgsz=MODEL_WIDTH,
                conf=CONFIDENCE_THRESHOLD,
                verbose=False
            )

            draw_grid(
                boxed
            )

            for result in results:

                for box in result.boxes:

                    cls_id = int(
                        box.cls[0]
                    )

                    class_name = (
                        model.names[
                            cls_id
                        ]
                    )

                    confidence = float(
                        box.conf[0]
                    )

                    x1, y1, x2, y2 = (
                        box.xyxy[
                            0
                        ].tolist()
                    )

                    x1 = int(x1)
                    y1 = int(y1)
                    x2 = int(x2)
                    y2 = int(y2)

                    # Detection box
                    cv2.rectangle(
                        boxed,
                        (x1, y1),
                        (x2, y2),
                        (0, 0, 255),
                        3
                    )

                    # Object center
                    center_x = int(
                        (x1 + x2) / 2
                    )

                    center_y = int(
                        (y1 + y2) / 2
                    )

                    cv2.circle(
                        boxed,
                        (
                            center_x,
                            center_y
                        ),
                        7,
                        (0, 255, 255),
                        -1
                    )

                    label = (
                        f"{class_name} "
                        f"{confidence:.2f}"
                    )

                    cv2.putText(
                        boxed,
                        label,
                        (
                            x1,
                            max(
                                30,
                                y1 - 10
                            )
                        ),
                        cv2.FONT_HERSHEY_SIMPLEX,
                        0.75,
                        (0, 0, 255),
                        2
                    )

                    print(
                        "Detected:",
                        class_name,
                        "| Confidence:",
                        round(
                            confidence,
                            2
                        ),
                        "| Center:",
                        (
                            center_x,
                            center_y
                        )
                    )

            cv2.imshow(
                "SmartCane YOLO Test",
                boxed
            )

            key = (
                cv2.waitKey(1)
                & 0xFF
            )

            if key == ord("q"):
                break

    except KeyboardInterrupt:

        print()
        print("YOLO test stopped.")

    finally:

        try:
            picam2.stop()

        except Exception:
            pass

        cv2.destroyAllWindows()

        print(
            "Camera cleanup complete."
        )


if __name__ == "__main__":
    main()