import time
import board
import busio
from adafruit_pca9685 import PCA9685


# =========================================================
# PCA9685 settings
# =========================================================

PCA9685_FREQUENCY = 1000

MOTOR_CHANNELS = [
    0,  # TOP
    1,  # LEFT
    2,  # BOTTOM
    3,  # RIGHT
]

MOTOR_STRENGTH_PERCENT = 30

TEST_DURATION_SEC = 1.0
WAIT_DURATION_SEC = 0.5


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


def all_motors_off(
    pca
):

    for channel in MOTOR_CHANNELS:

        motor_off(
            pca,
            channel
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

    all_motors_off(
        pca
    )

    print(
        "PCA9685 ready"
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
        f"Strength: "
        f"{MOTOR_STRENGTH_PERCENT}%"
    )

    print()

    try:

        for channel in MOTOR_CHANNELS:

            print(
                f"CH{channel} -> ON"
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
                f"CH{channel} -> OFF"
            )

            time.sleep(
                WAIT_DURATION_SEC
            )

        print()
        print(
            "PCA9685 test complete."
        )

    except KeyboardInterrupt:

        print()
        print(
            "Test interrupted."
        )

    finally:

        all_motors_off(
            pca
        )

        pca.deinit()

        print(
            "All motors OFF."
        )


if __name__ == "__main__":
    main()