#!/usr/bin/env python3

import time
import board
import busio
import digitalio
import adafruit_vl53l1x


# =========================================================
# ToF settings
# =========================================================

TOF_ADDRESSES = [
    0x2A,
    0x2B,
    0x2C,
    0x2D,
    0x2E,
    0x2F,
    0x30,
    0x31,
]

TOF_XSHUT_PINS = [
    board.D17,
    board.D27,
    board.D22,
    board.D23,
    board.D24,
    board.D25,
    board.D5,
    board.D26,
]

TOF_DISTANCE_MODE = 2
TOF_TIMING_BUDGET_MS = 100


# =========================================================
# Main
# =========================================================

def main():

    print()
    print("================================")
    print(" 8 ToF address setup")
    print("================================")

    i2c = busio.I2C(
        board.SCL,
        board.SDA
    )

    xshut_pins = []
    sensors = []

    try:

        # -----------------------------------------
        # Disable all sensors first
        # -----------------------------------------

        print("[ToF] Disabling all sensors...")

        for pin_name in TOF_XSHUT_PINS:

            pin = digitalio.DigitalInOut(
                pin_name
            )

            pin.direction = (
                digitalio.Direction.OUTPUT
            )

            pin.value = False

            xshut_pins.append(
                pin
            )

        time.sleep(1.0)

        # -----------------------------------------
        # Enable sensors one by one
        # -----------------------------------------

        for i, new_address in enumerate(
            TOF_ADDRESSES
        ):

            print()
            print(
                f"[ToF] Starting sensor {i + 1}..."
            )

            # Enable only the current sensor.
            # It appears at default address 0x29.
            xshut_pins[i].value = True

            time.sleep(0.20)

            sensor = (
                adafruit_vl53l1x.VL53L1X(
                    i2c
                )
            )

            # Change default address 0x29
            # to the assigned address.
            sensor.set_address(
                new_address
            )

            sensor.distance_mode = (
                TOF_DISTANCE_MODE
            )

            sensor.timing_budget = (
                TOF_TIMING_BUDGET_MS
            )

            sensors.append(
                sensor
            )

            print(
                f"[ToF] Sensor {i + 1}: "
                f"0x29 -> 0x{new_address:02X}"
            )

            time.sleep(0.05)

        print()
        print("================================")
        print(" ToF address setup complete")
        print("================================")

        print(
            "Addresses:",
            " ".join(
                f"0x{address:02X}"
                for address
                in TOF_ADDRESSES
            )
        )

        print(
            "Default address 0x29 is unused."
        )

        print()
        print(
            "Keep this program running "
            "if you want to test the assigned addresses."
        )

        print(
            "Press Ctrl+C to stop."
        )

        while True:
            time.sleep(1)

    except KeyboardInterrupt:

        print()
        print(
            "Program stopped by user."
        )

    finally:

        # -----------------------------------------
        # Shut down all sensors
        # -----------------------------------------

        for pin in xshut_pins:

            try:
                pin.value = False
            except Exception:
                pass

        for pin in xshut_pins:

            try:
                pin.deinit()
            except Exception:
                pass

        print(
            "All ToF sensors disabled."
        )


if __name__ == "__main__":
    main()