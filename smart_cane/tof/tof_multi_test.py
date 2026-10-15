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

TOF_READ_INTERVAL_SEC = 0.10
TOF_PRINT_INTERVAL_SEC = 0.50


# =========================================================
# Global objects
# =========================================================

i2c = None
xshut_pins = []
sensors = []

last_values = [
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
]


# =========================================================
# Initialization
# =========================================================

def initialize_tof():

    global i2c
    global xshut_pins
    global sensors
    global last_values

    print()
    print("================================")
    print(" 8 ToF initialization")
    print("================================")

    i2c = busio.I2C(
        board.SCL,
        board.SDA
    )

    xshut_pins = []
    sensors = []

    last_values = [
        None
    ] * len(
        TOF_ADDRESSES
    )

    # -----------------------------------------
    # Disable all ToF sensors
    # -----------------------------------------

    print(
        "[ToF] Disabling all sensors..."
    )

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

    time.sleep(
        1.0
    )

    # -----------------------------------------
    # Enable one sensor at a time
    # -----------------------------------------

    for i, new_address in enumerate(
        TOF_ADDRESSES
    ):

        print(
            f"[ToF] Starting sensor {i + 1}..."
        )

        xshut_pins[i].value = True

        time.sleep(
            0.20
        )

        # Newly enabled VL53L1X appears at 0x29.
        sensor = (
            adafruit_vl53l1x.VL53L1X(
                i2c
            )
        )

        sensor.set_address(
            new_address
        )

        sensor.distance_mode = (
            TOF_DISTANCE_MODE
        )

        sensor.timing_budget = (
            TOF_TIMING_BUDGET_MS
        )

        sensor.start_ranging()

        sensors.append(
            sensor
        )

        print(
            f"[ToF] Sensor {i + 1}: "
            f"0x29 -> 0x{new_address:02X}"
        )

        time.sleep(
            0.05
        )

    print()
    print(
        "[ToF] All 8 sensors ready"
    )

    print(
        "[ToF] Addresses:",
        " ".join(
            f"0x{address:02X}"
            for address
            in TOF_ADDRESSES
        )
    )

    print(
        "[ToF] Default 0x29 is unused"
    )


# =========================================================
# Read sensors
# =========================================================

def read_tof_once():

    global last_values

    for i, sensor in enumerate(
        sensors
    ):

        try:

            if sensor.data_ready:

                distance = (
                    sensor.distance
                )

                sensor.clear_interrupt()

                if distance is None:

                    last_values[i] = None

                else:

                    last_values[i] = round(
                        float(
                            distance
                        ),
                        1
                    )

        except Exception as e:

            last_values[i] = None

            print(
                f"[ToF] Sensor {i + 1} "
                f"read error:",
                e
            )

    return last_values


# =========================================================
# Console output
# =========================================================

def print_tof_values():

    output = []

    for i, distance in enumerate(
        last_values
    ):

        address = (
            TOF_ADDRESSES[i]
        )

        if distance is None:

            output.append(
                f"ToF{i + 1}"
                f"(0x{address:02X}): ---"
            )

        else:

            output.append(
                f"ToF{i + 1}"
                f"(0x{address:02X}): "
                f"{distance:.1f} cm"
            )

    print(
        "[ToF]",
        " | ".join(
            output
        )
    )


# =========================================================
# Cleanup
# =========================================================

def cleanup_tof():

    global sensors
    global xshut_pins

    print()
    print(
        "[ToF] Cleaning up..."
    )

    for sensor in sensors:

        try:

            sensor.stop_ranging()

        except Exception:
            pass

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

    sensors = []
    xshut_pins = []

    print(
        "[ToF] Cleanup complete"
    )


# =========================================================
# Main
# =========================================================

def main():

    initialize_tof()

    print()
    print(
        "8 ToF sensor test started."
    )

    print(
        "Press Ctrl+C to stop."
    )

    last_read_time = 0.0
    last_print_time = 0.0

    try:

        while True:

            now = time.time()

            if (
                now
                - last_read_time
                >= TOF_READ_INTERVAL_SEC
            ):

                read_tof_once()

                last_read_time = (
                    now
                )

            if (
                now
                - last_print_time
                >= TOF_PRINT_INTERVAL_SEC
            ):

                print_tof_values()

                last_print_time = (
                    now
                )

            time.sleep(
                0.01
            )

    except KeyboardInterrupt:

        print()
        print(
            "Program stopped by user."
        )

    finally:

        cleanup_tof()


if __name__ == "__main__":
    main()