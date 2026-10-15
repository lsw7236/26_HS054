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

TEST_DURATION_SEC = 1.0
WAIT_DURATION_SEC = 0.5


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

    "CENTER": [
        MOTOR_TOP,
        MOTOR_LEFT,
        MOTOR_BOTTOM,
        MOTOR_RIGHT
    ],
}


# =========================================================
# Utility
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
# Motor control
# =========================================================

def motor_on(
    pca,
    channel,
    strength_percent=MOTOR_STRENGTH_PERCENT
):

    duty = motor_strength_to_duty(
        strength_percent
    )

    pca.channels[
        channel
    ].duty_cycle = duty


def motor_off(
    pca,
    channel
):

    pca.channels[
        channel
    ].duty_cycle = 0


def motor_stop_all(
    pca
):

    for channel in [
        MOTOR_TOP,
        MOTOR_LEFT,
        MOTOR_BOTTOM,
        MOTOR_RIGHT
    ]:

        motor_off(
            pca,
            channel
        )


def activate_direction(
    pca,
    direction
):

    motor_stop_all(
        pca
    )

    channels = (
        DIRECTION_TO_CHANNELS.get(
            direction,
            []
        )
    )

    for channel in channels:

        motor_on(
            pca,
            channel
        )

    print(
        f"{direction} -> {channels}"
    )


# =========================================================
# Individual channel test
# =========================================================

def test_individual_motors(
    pca
):

    motors = [
        (
            "TOP",
            MOTOR_TOP
        ),
        (
            "LEFT",
            MOTOR_LEFT
        ),
        (
            "BOTTOM",
            MOTOR_BOTTOM
        ),
        (
            "RIGHT",
            MOTOR_RIGHT
        ),
    ]

    print()
    print(
        "================================"
    )
    print(
        " Individual motor test"
    )
    print(
        "================================"
    )

    for name, channel in motors:

        print(
            f"{name} "
            f"(CH{channel}) -> ON"
        )

        motor_on(
            pca,
            channel
        )

        time.sleep(
            TEST_DURATION_SEC
        )

        motor_off(
            pca,
            channel
        )

        print(
            f"{name} "
            f"(CH{channel}) -> OFF"
        )

        time.sleep(
            WAIT_DURATION_SEC
        )


# =========================================================
# 3x3 direction test
# =========================================================

def test_direction_patterns(
    pca
):

    test_directions = [
        "TOP+LEFT",
        "TOP",
        "TOP+RIGHT",

        "LEFT",
        "CENTER",
        "RIGHT",

        "BOTTOM+LEFT",
        "BOTTOM",
        "BOTTOM+RIGHT",
    ]

    print()
    print(
        "================================"
    )
    print(
        " 3x3 direction test"
    )
    print(
        "================================"
    )

    for direction in test_directions:

        print()
        print(
            "Testing:",
            direction
        )

        activate_direction(
            pca,
            direction
        )

        time.sleep(
            TEST_DURATION_SEC
        )

        motor_stop_all(
            pca
        )

        time.sleep(
            WAIT_DURATION_SEC
        )


# =========================================================
# Main
# =========================================================

def main():

    print(
        "Initializing PCA9685..."
    )

    i2c = busio.I2C(
        board.SCL,
        board.SDA
    )

    pca = PCA9685(
        i2c
    )

    pca.frequency = (
        PCA9685_FREQUENCY
    )

    motor_stop_all(
        pca
    )

    print(
        "PCA9685 ready"
    )

    print(
        "Channels:"
    )

    print(
        "CH0 = TOP"
    )

    print(
        "CH1 = LEFT"
    )

    print(
        "CH2 = BOTTOM"
    )

    print(
        "CH3 = RIGHT"
    )

    print(
        f"Motor strength: "
        f"{MOTOR_STRENGTH_PERCENT}%"
    )

    try:

        test_individual_motors(
            pca
        )

        test_direction_patterns(
            pca
        )

        print()
        print(
            "All motor tests complete."
        )

    except KeyboardInterrupt:

        print()
        print(
            "Motor test interrupted."
        )

    finally:

        motor_stop_all(
            pca
        )

        pca.deinit()

        print(
            "All motors OFF."
        )


if __name__ == "__main__":
    main()