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
# Recovery settings
# =========================================================

TOF_MAX_CONSECUTIVE_ERRORS = 5

TOF_RECOVERY_COOLDOWN_SEC = 2.0

TOF_RECOVERY_SETTLE_SEC = 1.0


# =========================================================
# Global state
# =========================================================

tof_i2c = None

tof_xshut = []

tof_sensors = []

tof_last_values = [
    None
] * 8

tof_error_counts = [
    0
] * 8

tof_recovery_requested = False

tof_recovering = False

tof_last_recovery_time = 0.0


# =========================================================
# Cleanup
# =========================================================

def cleanup_tof():

    global tof_xshut
    global tof_sensors

    for sensor in tof_sensors:

        try:
            sensor.stop_ranging()

        except Exception:
            pass

    for pin in tof_xshut:

        try:
            pin.value = False

        except Exception:
            pass

    for pin in tof_xshut:

        try:
            pin.deinit()

        except Exception:
            pass

    tof_sensors = []
    tof_xshut = []


# =========================================================
# Initialization
# =========================================================

def initialize_tof():

    global tof_i2c
    global tof_xshut
    global tof_sensors

    global tof_last_values
    global tof_error_counts

    global tof_recovery_requested

    cleanup_tof()

    print()
    print("================================")
    print(" 8 ToF initialization")
    print("================================")

    if tof_i2c is None:

        tof_i2c = busio.I2C(
            board.SCL,
            board.SDA
        )

    tof_xshut = []

    # -----------------------------------------
    # Shut down all sensors
    # -----------------------------------------

    for pin_name in TOF_XSHUT_PINS:

        pin = digitalio.DigitalInOut(
            pin_name
        )

        pin.direction = (
            digitalio.Direction.OUTPUT
        )

        pin.value = False

        tof_xshut.append(
            pin
        )

    time.sleep(
        1.0
    )

    tof_sensors = []

    tof_last_values = [
        None
    ] * len(
        TOF_ADDRESSES
    )

    tof_error_counts = [
        0
    ] * len(
        TOF_ADDRESSES
    )

    tof_recovery_requested = False

    # -----------------------------------------
    # Enable sensors one by one
    # -----------------------------------------

    for i, new_address in enumerate(
        TOF_ADDRESSES
    ):

        print(
            f"[ToF] Starting sensor {i + 1}..."
        )

        tof_xshut[
            i
        ].value = True

        time.sleep(
            0.20
        )

        sensor = (
            adafruit_vl53l1x.VL53L1X(
                tof_i2c
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

        tof_sensors.append(
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

    global tof_last_values
    global tof_error_counts
    global tof_recovery_requested

    if not tof_sensors:
        return tof_last_values

    for i, sensor in enumerate(
        tof_sensors
    ):

        try:

            if sensor.data_ready:

                distance = (
                    sensor.distance
                )

                sensor.clear_interrupt()

                tof_last_values[i] = (
                    None
                    if distance is None
                    else round(
                        float(
                            distance
                        ),
                        1
                    )
                )

                # Successful communication
                # resets the error counter.
                tof_error_counts[i] = 0

        except OSError as e:

            tof_last_values[i] = None

            tof_error_counts[i] += 1

            print(
                f"[ToF] Sensor {i + 1} "
                f"I2C error "
                f"({tof_error_counts[i]}/"
                f"{TOF_MAX_CONSECUTIVE_ERRORS}):",
                e
            )

            if (
                tof_error_counts[i]
                >= TOF_MAX_CONSECUTIVE_ERRORS
            ):

                tof_recovery_requested = True

        except Exception as e:

            tof_last_values[i] = None

            tof_error_counts[i] += 1

            print(
                f"[ToF] Sensor {i + 1} "
                f"read error "
                f"({tof_error_counts[i]}/"
                f"{TOF_MAX_CONSECUTIVE_ERRORS}):",
                e
            )

            if (
                tof_error_counts[i]
                >= TOF_MAX_CONSECUTIVE_ERRORS
            ):

                tof_recovery_requested = True

    return tof_last_values


# =========================================================
# Automatic recovery
# =========================================================

def recover_tof_if_needed():

    global tof_recovery_requested
    global tof_recovering
    global tof_last_recovery_time

    if not tof_recovery_requested:
        return False

    if tof_recovering:
        return False

    now = time.time()

    if (
        now
        - tof_last_recovery_time
        < TOF_RECOVERY_COOLDOWN_SEC
    ):

        return False

    tof_recovering = True

    print()
    print("================================")
    print(" ToF automatic recovery")
    print("================================")

    print(
        "[ToF] Repeated I2C errors detected."
    )

    print(
        "[ToF] Rebuilding all 8 ToF addresses..."
    )

    try:

        time.sleep(
            TOF_RECOVERY_SETTLE_SEC
        )

        initialize_tof()

        tof_last_recovery_time = (
            time.time()
        )

        print(
            "[ToF] Automatic recovery complete"
        )

        print(
            "================================"
        )

        print()

        return True

    except Exception as e:

        tof_last_recovery_time = (
            time.time()
        )

        # Keep recovery request enabled
        # so another retry can occur
        # after the cooldown period.
        tof_recovery_requested = True

        print(
            "[ToF] Automatic recovery failed:",
            e
        )

        return False

    finally:

        tof_recovering = False


# =========================================================
# Console output
# =========================================================

def print_tof_values():

    values = []

    for i, distance in enumerate(
        tof_last_values
    ):

        if distance is None:

            values.append(
                f"ToF{i + 1}: ---"
            )

        else:

            values.append(
                f"ToF{i + 1}: "
                f"{distance:.1f} cm"
            )

    print(
        "[ToF]",
        " | ".join(
            values
        )
    )


# =========================================================
# Main
# =========================================================

def main():

    global tof_last_recovery_time

    initialize_tof()

    print()
    print(
        "8 ToF recovery test started."
    )

    print(
        "Press Ctrl+C to stop."
    )

    last_read_time = 0.0
    last_print_time = 0.0

    try:

        while True:

            now = time.time()

            # ---------------------------------
            # Sensor read
            # ---------------------------------

            if (
                now
                - last_read_time
                >= TOF_READ_INTERVAL_SEC
            ):

                read_tof_once()

                last_read_time = now

            # ---------------------------------
            # Automatic recovery
            # ---------------------------------

            recovered = (
                recover_tof_if_needed()
            )

            if recovered:

                now = time.time()

                last_read_time = now
                last_print_time = now

            # ---------------------------------
            # Console output
            # ---------------------------------

            if (
                now
                - last_print_time
                >= TOF_PRINT_INTERVAL_SEC
            ):

                print_tof_values()

                last_print_time = now

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

        print(
            "[ToF] Cleanup complete"
        )


if __name__ == "__main__":
    main()