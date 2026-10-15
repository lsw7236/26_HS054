import time
import board
import busio
from adafruit_pca9685 import PCA9685


# =========================================================
# PCA9685 settings
# =========================================================

PCA9685_FREQUENCY = 1000

MOTOR_TOP = 0
MOTOR_LEFT = 1
MOTOR_BOTTOM = 2
MOTOR_RIGHT = 3

MOTOR_STRENGTH_PERCENT = 30
MOTOR_UPDATE_INTERVAL = 0.25


# =========================================================
# Direction mapping
# =========================================================

DIRECTION_TO_CHANNELS = {
    "TOP": [
        MOTOR_TOP
    ],

    "LEFT": [
        MOTOR_LEFT
    ],

    "BOTTOM": [
        MOTOR_BOTTOM
    ],

    "RIGHT": [
        MOTOR_RIGHT
    ],

    "TOP+LEFT": [
        MOTOR_TOP,
        MOTOR_LEFT
    ],

    "TOP+RIGHT": [
        MOTOR_TOP,
        MOTOR_RIGHT
    ],

    "BOTTOM+LEFT": [
        MOTOR_BOTTOM,
        MOTOR_LEFT
    ],

    "BOTTOM+RIGHT": [
        MOTOR_BOTTOM,
        MOTOR_RIGHT
    ],

    # Target is aligned near the center.
    # All four motors vibrate together.
    "CENTER": [
        MOTOR_TOP,
        MOTOR_LEFT,
        MOTOR_BOTTOM,
        MOTOR_RIGHT
    ],
}


# =========================================================
# Global objects
# =========================================================

pca = None
motor_i2c = None

last_motor_direction = None
last_motor_update_time = 0.0


# =========================================================
# Motor utility
# =========================================================

def motor_strength_to_duty(percent):

    percent = max(
        0,
        min(
            100,
            percent
        )
    )

    return int(
        65535
        * (
            percent / 100.0
        )
    )


# =========================================================
# Initialization
# =========================================================

def initialize_motor():

    global pca
    global motor_i2c

    print(
        "[MOTOR] Initializing PCA9685..."
    )

    motor_i2c = busio.I2C(
        board.SCL,
        board.SDA
    )

    pca = PCA9685(
        motor_i2c
    )

    pca.frequency = (
        PCA9685_FREQUENCY
    )

    motor_stop_all()

    print(
        "[MOTOR] PCA9685 ready"
    )

    print(
        "[MOTOR] Channels: "
        "TOP=0 LEFT=1 BOTTOM=2 RIGHT=3"
    )

    print(
        f"[MOTOR] Strength: "
        f"{MOTOR_STRENGTH_PERCENT}%"
    )


# =========================================================
# Stop motors
# =========================================================

def motor_stop_all():

    global last_motor_direction

    if pca is None:
        return

    for channel in [
        MOTOR_TOP,
        MOTOR_LEFT,
        MOTOR_BOTTOM,
        MOTOR_RIGHT
    ]:

        pca.channels[
            channel
        ].duty_cycle = 0

    last_motor_direction = None


# =========================================================
# Direction control
# =========================================================

def motor_set_direction(
    direction,
    strength_percent=MOTOR_STRENGTH_PERCENT
):

    global last_motor_direction
    global last_motor_update_time

    if pca is None:
        return

    now = time.time()

    if (
        direction
        == last_motor_direction
        and now
        - last_motor_update_time
        < MOTOR_UPDATE_INTERVAL
    ):

        return

    motor_stop_all()

    channels = (
        DIRECTION_TO_CHANNELS.get(
            direction,
            []
        )
    )

    duty = motor_strength_to_duty(
        strength_percent
    )

    for channel in channels:

        pca.channels[
            channel
        ].duty_cycle = duty

    last_motor_direction = (
        direction
    )

    last_motor_update_time = (
        now
    )

    print(
        "[MOTOR]",
        direction,
        "->",
        channels
    )


# =========================================================
# Cleanup
# =========================================================

def cleanup_motor():

    global pca
    global motor_i2c

    if pca is not None:

        try:

            motor_stop_all()

            pca.deinit()

        except Exception:
            pass

    pca = None
    motor_i2c = None


# =========================================================
# Standalone test
# =========================================================

def main():

    initialize_motor()

    test_directions = [
        "TOP",
        "TOP+RIGHT",
        "RIGHT",
        "BOTTOM+RIGHT",
        "BOTTOM",
        "BOTTOM+LEFT",
        "LEFT",
        "TOP+LEFT",
        "CENTER"
    ]

    print()
    print(
        "Direction motor test started."
    )

    try:

        for direction in test_directions:

            print()
            print(
                "Testing:",
                direction
            )

            motor_set_direction(
                direction
            )

            time.sleep(
                1.0
            )

            motor_stop_all()

            time.sleep(
                0.5
            )

    except KeyboardInterrupt:

        print()
        print(
            "Motor test interrupted."
        )

    finally:

        cleanup_motor()

        print(
            "Motor test complete."
        )


if __name__ == "__main__":
    main()