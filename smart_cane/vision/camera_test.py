#!/usr/bin/env python3

import time
import cv2
from picamera2 import Picamera2


# =========================================================
# Camera settings
# =========================================================

CAMERA_WIDTH = 640
CAMERA_HEIGHT = 480

DISPLAY_WIDTH = 640
DISPLAY_HEIGHT = 640


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
        round(original_w * scale)
    )

    resized_h = int(
        round(original_h * scale)
    )

    resized = cv2.resize(
        image,
        (resized_w, resized_h),
        interpolation=cv2.INTER_LINEAR
    )

    pad_w = target_w - resized_w
    pad_h = target_h - resized_h

    pad_left = pad_w // 2
    pad_right = pad_w - pad_left

    pad_top = pad_h // 2
    pad_bottom = pad_h - pad_top

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
    print("Press Q to quit.")

    try:

        while True:

            frame = picam2.capture_array()

            boxed = letterbox(
                frame,
                new_size=(
                    DISPLAY_WIDTH,
                    DISPLAY_HEIGHT
                )
            )

            draw_grid(
                boxed
            )

            cv2.imshow(
                "SmartCane Camera Test",
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
        print("Camera test stopped.")

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