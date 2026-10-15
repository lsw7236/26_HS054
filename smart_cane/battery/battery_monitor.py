#!/usr/bin/env python3

import time
import struct
from pathlib import Path
from subprocess import check_output, CalledProcessError

import smbus2
from gpiozero import Button


# =========================================================
# X120x settings
# =========================================================

X120X_ADDRESS = 0x36

# PLD pin from X120x
PLD_PIN = 6

STATUS_INTERVAL_SEC = 5


# =========================================================
# Global objects
# =========================================================

x120x_bus = None
pld_button = None


# =========================================================
# Utility
# =========================================================

def safe_round(value, digits):
    if value is None:
        return None

    return round(value, digits)


# =========================================================
# X120x initialization
# =========================================================

def initialize_x120x():
    global x120x_bus
    global pld_button

    print("[X120x] Initializing...")

    x120x_bus = smbus2.SMBus(1)

    pld_button = Button(
        PLD_PIN
    )

    print("[X120x] Status reader ready")


# =========================================================
# Battery voltage / capacity
# =========================================================

def read_voltage_and_capacity():

    if x120x_bus is None:
        return None, None

    voltage_read = x120x_bus.read_word_data(
        X120X_ADDRESS,
        2
    )

    capacity_read = x120x_bus.read_word_data(
        X120X_ADDRESS,
        4
    )

    voltage_swapped = struct.unpack(
        "<H",
        struct.pack(
            ">H",
            voltage_read
        )
    )[0]

    voltage = (
        voltage_swapped
        * 1.25
        / 1000
        / 16
    )

    capacity_swapped = struct.unpack(
        "<H",
        struct.pack(
            ">H",
            capacity_read
        )
    )[0]

    capacity = (
        capacity_swapped
        / 256
    )

    return voltage, capacity


# =========================================================
# External power state
# =========================================================

def get_pld_state():

    if pld_button is None:
        return None

    return (
        0
        if pld_button.is_pressed
        else 1
    )


# =========================================================
# Raspberry Pi hardware metrics
# =========================================================

def read_hardware_metric(
    command_args,
    strip_chars
):
    try:

        output = check_output(
            command_args
        ).decode(
            "utf-8"
        )

        metric_str = (
            output
            .split("=")[1]
            .strip()
            .rstrip(strip_chars)
        )

        return float(
            metric_str
        )

    except (
        CalledProcessError,
        ValueError,
        IndexError,
        FileNotFoundError
    ):
        return None


def read_cpu_volts():

    return read_hardware_metric(
        [
            "vcgencmd",
            "pmic_read_adc",
            "VDD_CORE_V"
        ],
        "V"
    )


def read_cpu_amps():

    return read_hardware_metric(
        [
            "vcgencmd",
            "pmic_read_adc",
            "VDD_CORE_A"
        ],
        "A"
    )


def read_cpu_temp():

    return read_hardware_metric(
        [
            "vcgencmd",
            "measure_temp"
        ],
        "'C"
    )


def read_input_voltage():

    return read_hardware_metric(
        [
            "vcgencmd",
            "pmic_read_adc",
            "EXT5V_V"
        ],
        "V"
    )


# =========================================================
# Cooling fan
# =========================================================

def get_fan_rpm():

    try:

        sys_devices_path = Path(
            "/sys/devices/platform/cooling_fan"
        )

        fan_input_files = list(
            sys_devices_path.rglob(
                "fan1_input"
            )
        )

        if not fan_input_files:
            return None

        with open(
            fan_input_files[0],
            "r"
        ) as file:

            return int(
                file.read().strip()
            )

    except Exception:
        return None


# =========================================================
# Power consumption
# =========================================================

def power_consumption_watts():

    try:

        output = check_output(
            [
                "vcgencmd",
                "pmic_read_adc"
            ]
        ).decode(
            "utf-8"
        )

        amperages = {}
        voltages = {}

        for line in output.splitlines():

            cleaned_line = line.strip()

            if not cleaned_line:
                continue

            parts = cleaned_line.split()

            if len(parts) < 2:
                continue

            label = parts[0]
            value = parts[-1]

            try:

                val = float(
                    value
                    .split("=")[1][:-1]
                )

            except (
                ValueError,
                IndexError
            ):
                continue

            short_label = label[:-2]

            if label.endswith("A"):
                amperages[short_label] = val
            else:
                voltages[short_label] = val

        return sum(
            amperages[key]
            * voltages[key]
            for key in amperages
            if key in voltages
        )

    except Exception:
        return None


# =========================================================
# Status data
# =========================================================

def get_status_data():

    voltage, capacity = (
        read_voltage_and_capacity()
    )

    cpu_volts = read_cpu_volts()
    cpu_amps = read_cpu_amps()
    cpu_temp = read_cpu_temp()

    input_voltage = read_input_voltage()

    fan_rpm = get_fan_rpm()

    pwr_use = power_consumption_watts()

    pld_state = get_pld_state()


    # =====================================================
    # Charging state
    # =====================================================
    #
    # pld_state == 1
    # External AC power is connected.
    #
    # The X120x code does not directly measure
    # battery charging current.
    #
    # "charging" here means:
    # external power connected + battery below 90%.
    #

    if (
        capacity is None
        or pld_state is None
    ):

        charge_status = "unknown"

    elif capacity >= 90:

        charge_status = "disabled"

    elif pld_state == 1:

        charge_status = "charging"

    else:

        charge_status = "not_charging"


    # =====================================================
    # Power status
    # =====================================================

    if pld_state is None:

        power_status = "UNKNOWN"

    elif pld_state == 1:

        power_status = "AC_OK"

    else:

        power_status = "UPS_BACKUP"


    # =====================================================
    # Battery warning
    # =====================================================

    warning = ""

    if (
        pld_state == 0
        and capacity is not None
    ):

        if capacity <= 15:

            warning = (
                "CRITICAL_SHUTDOWN_LEVEL"
            )

        elif capacity <= 24:

            warning = "CRITICAL"

        elif capacity <= 50:

            warning = "LOW"

        else:

            warning = "UPS_BACKUP"


    return {

        "battery": safe_round(
            capacity,
            1
        ),

        "charging": charge_status,

        "battery_voltage": safe_round(
            voltage,
            3
        ),

        "input_voltage": safe_round(
            input_voltage,
            3
        ),

        "cpu_voltage": safe_round(
            cpu_volts,
            3
        ),

        "cpu_current": safe_round(
            cpu_amps,
            3
        ),

        "cpu_temp": safe_round(
            cpu_temp,
            1
        ),

        "power_watts": safe_round(
            pwr_use,
            3
        ),

        "fan_rpm": fan_rpm,

        "power_status": power_status,

        "warning": warning,
    }


# =========================================================
# Console output
# =========================================================

def print_status():

    status = get_status_data()

    print("")
    print("================================")
    print(" X120x / Raspberry Pi Status")
    print("================================")

    print(
        "Battery:",
        status["battery"],
        "%"
    )

    print(
        "Battery Voltage:",
        status["battery_voltage"],
        "V"
    )

    print(
        "Charging:",
        status["charging"]
    )

    print(
        "Power Status:",
        status["power_status"]
    )

    print(
        "Input Voltage:",
        status["input_voltage"],
        "V"
    )

    print(
        "CPU Voltage:",
        status["cpu_voltage"],
        "V"
    )

    print(
        "CPU Current:",
        status["cpu_current"],
        "A"
    )

    print(
        "CPU Temperature:",
        status["cpu_temp"],
        "C"
    )

    print(
        "Power Consumption:",
        status["power_watts"],
        "W"
    )

    print(
        "Fan RPM:",
        status["fan_rpm"]
    )

    if status["warning"]:

        print(
            "WARNING:",
            status["warning"]
        )

    print("================================")


# =========================================================
# Cleanup
# =========================================================

def cleanup():

    global x120x_bus

    if x120x_bus is not None:

        try:
            x120x_bus.close()

        except Exception:
            pass

    x120x_bus = None


# =========================================================
# Main
# =========================================================

def main():

    initialize_x120x()

    print("")
    print("Battery monitor started.")
    print("Press Ctrl+C to stop.")

    try:

        while True:

            print_status()

            time.sleep(
                STATUS_INTERVAL_SEC
            )

    except KeyboardInterrupt:

        print("")
        print("Battery monitor stopped.")

    finally:

        cleanup()


if __name__ == "__main__":
    main()